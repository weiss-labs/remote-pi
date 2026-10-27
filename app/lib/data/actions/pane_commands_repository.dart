import 'dart:async';
import 'package:app/domain/contracts/pane_commands.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';

class _PendingCommand {
  final Completer<ServerMessage> completer;
  final Timer timer;
  final String? name;
  _PendingCommand(this.completer, this.timer, this.name);
}

/// All requests are bound to the active paired channel AND its current room.
class PaneCommandsRepository extends PaneCommands {
  final ConnectionManager connection;
  final Duration timeout;
  late final StreamSubscription<ConnectionStatus> _statusSub;
  late final StreamSubscription<Map<String, List<RoomInfo>>> _roomsSub;
  StreamSubscription<ServerMessage>? _messagesSub;
  final _changes = StreamController<void>.broadcast();
  final Map<String, _PendingCommand> _pending = {};
  final Map<String, PaneCommand> _catalogue = {};
  IChannel? _channel;
  String _context = '';
  int _sequence = 0;
  int _listGeneration = 0;
  bool _disposed = false;
  PaneCommandsRepository(
    this.connection, {
    this.timeout = const Duration(seconds: 15),
  }) {
    _statusSub = connection.statusStream.listen((_) => _bind());
    _roomsSub = connection.roomsStream.listen((_) => _bind());
    _bind();
  }
  @override
  Stream<void> get contextChanges => _changes.stream;
  void _bind() {
    if (_disposed) return;
    final channel = connection.channel;
    final context =
        '${connection.activePeer?.remoteEpk ?? ''}|${connection.activeRoomId}';
    if (identical(channel, _channel) && context == _context) return;
    _messagesSub?.cancel();
    _channel = channel;
    _context = context;
    _catalogue.clear();
    _listGeneration++;
    _failPending(
      'The pane connection changed. Refresh commands and try again.',
    );
    _messagesSub = channel?.serverMessages.listen(_onMessage);
    _changes.add(null);
  }

  void _onMessage(ServerMessage message) {
    _bind();
    final id = switch (message) {
      CommandsList(:final inReplyTo) => inReplyTo,
      CommandResult(:final inReplyTo) => inReplyTo,
      ErrorMessage(:final inReplyTo) => inReplyTo,
      _ => null,
    };
    final request = _pending[id];
    if (request == null) return;
    if (message is CommandsList && request.name != null) return;
    if (message is CommandResult) {
      final expectedName = request.name ?? '';
      if (expectedName != message.name ||
          (request.name == null && message.accepted)) {
        return;
      }
    }
    _pending.remove(id);
    request.timer.cancel();
    if (message is ErrorMessage) {
      request.completer.completeError(
        const PaneCommandFailure(
          'This pane does not support commands. Update its extension and retry.',
        ),
      );
    } else {
      request.completer.complete(message);
    }
  }

  void _failPending(String message) {
    final requests = _pending.values.toList();
    _pending.clear();
    for (final request in requests) {
      request.timer.cancel();
      request.completer.completeError(PaneCommandFailure(message));
    }
  }

  Future<ServerMessage> _request(
    ClientMessage Function(String) build, {
    String? name,
  }) async {
    _bind();
    final channel = _channel;
    if (_disposed || channel == null || connection.activePeer == null) {
      throw const PaneCommandFailure(
        'Connect to the paired pane to use commands.',
      );
    }
    final id =
        'command-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final completer = Completer<ServerMessage>();
    final timer = Timer(timeout, () {
      final pending = _pending.remove(id);
      pending?.completer.completeError(
        PaneCommandFailure(
          name == null
              ? 'No command list received. Refresh or update the desktop extension.'
              : 'No confirmation from the pane. Check its state before retrying; the command may have been accepted.',
        ),
      );
    });
    _pending[id] = _PendingCommand(completer, timer, name);
    // Attach error handling before asynchronous send so connection changes
    // cannot produce unhandled errors while a socket write is pending.
    final response = completer.future;
    unawaited(_send(channel, build(id), id));
    return response;
  }

  Future<void> _send(IChannel channel, ClientMessage message, String id) async {
    try {
      await channel.send(message);
    } on Exception {
      _sendFailed(id);
    } on StateError {
      _sendFailed(id);
    }
  }

  void _sendFailed(String id) {
    final pending = _pending.remove(id);
    pending?.timer.cancel();
    pending?.completer.completeError(
      const PaneCommandFailure(
        'Could not reach the pane. Check its connection.',
      ),
    );
  }

  @override
  Future<List<PaneCommand>> list() async {
    _bind();
    final context = _context;
    final generation = ++_listGeneration;
    _catalogue.clear();
    final response = await _request((id) => ListCommands(id: id));
    // _request binds synchronously; the pending request is failed on changes.
    if (response is! CommandsList) {
      throw PaneCommandFailure(
        response is CommandResult
            ? response.message ??
                  response.code ??
                  'The pane rejected command discovery.'
            : 'Invalid command list reply.',
      );
    }
    if (generation != _listGeneration ||
        (context.isNotEmpty && context != _context)) {
      throw const PaneCommandFailure('Pane changed. Refresh commands.');
    }
    final result = response.commands
        .map(
          (command) => PaneCommand(
            name: command.name,
            description: command.description,
            executable: response.dispatchSupported && command.available,
            disabledReason: !response.dispatchSupported
                ? 'Update this pane to a command-capable Pi version.'
                : command.reason,
            source: command.source,
            busyPolicy: command.busyPolicy,
          ),
        )
        .toList();
    _catalogue
      ..clear()
      ..addEntries(result.map((command) => MapEntry(command.name, command)));
    if (!response.dispatchSupported && result.isEmpty) {
      throw const PaneCommandFailure(
        'This pane cannot dispatch commands. Update its Pi version and extension.',
      );
    }
    return result;
  }

  @override
  Future<void> execute(String name, String arguments) async {
    _bind();
    final command = _catalogue[name];
    if (command == null || !command.executable) {
      throw PaneCommandFailure(
        command?.disabledReason ??
            'Refresh and choose a command advertised by this pane.',
      );
    }
    if (arguments.length > 8192 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(arguments)) {
      throw const PaneCommandFailure(
        'Use single-line command arguments, up to 8192 characters.',
      );
    }
    final response = await _request(
      (id) => CommandExecute(id: id, name: name, args: arguments),
      name: name,
    );
    if (response is! CommandResult || !response.accepted) {
      throw PaneCommandFailure(
        response is CommandResult
            ? response.message ??
                  response.code ??
                  'The pane rejected this command.'
            : 'Invalid command reply.',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statusSub.cancel();
    _roomsSub.cancel();
    _messagesSub?.cancel();
    _failPending('Command view closed.');
    _changes.close();
    super.dispose();
  }
}
