import 'dart:async';
import 'package:app/domain/contracts/pane_commands.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import '../states/commands_state.dart';
export '../states/commands_state.dart';
export 'package:app/domain/contracts/pane_commands.dart' show PaneCommand;

class CommandsViewModel extends ViewModel<CommandsState> {
  final PaneCommands _commands;
  late final StreamSubscription<void> _contextSub;
  List<PaneCommand> _catalogue = const [];
  String _query = '';
  int _generation = 0;
  bool _disposed = false;
  CommandsViewModel(this._commands) : super(const CommandsIdle()) {
    _contextSub = _commands.contextChanges.listen((_) {
      _generation++;
      _catalogue = const [];
      emit(const CommandsIdle());
      if (_query.trimLeft().startsWith('/')) unawaited(refresh());
    });
  }
  void queryChanged(String query) {
    final wasCommand = _query.trimLeft().startsWith('/');
    _query = query;
    if (query.trimLeft().startsWith('/') &&
        (!wasCommand || state is CommandsIdle)) {
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    if (_disposed || state is CommandsRunning) return;
    final generation = ++_generation;
    _catalogue = const [];
    emit(const CommandsLoading());
    try {
      final commands = await _commands.list();
      if (_disposed || generation != _generation) return;
      _catalogue = List.unmodifiable(commands);
      emit(CommandsReady(_catalogue));
    } on PaneCommandFailure catch (error) {
      if (!_disposed && generation == _generation) {
        emit(CommandsUnavailable(error.message));
      }
    }
  }

  List<PaneCommand> matches(String query) {
    final value = query.trimLeft();
    if (!value.startsWith('/')) return const [];
    final prefix = value.substring(1).trimRight().toLowerCase();
    return _catalogue.where((command) {
      final name = command.name.toLowerCase();
      return name.startsWith(prefix) || prefix.startsWith('$name ');
    }).toList();
  }

  Future<bool> run(String input) async {
    if (_disposed || state is! CommandsReady) {
      return false;
    }
    final text = input.trim();
    if (!text.startsWith('/')) return false;
    final commandText = text.substring(1);
    // The live SDK permits multiword names. Match the longest advertised name
    // before separating single-line arguments, never invent a command token.
    final candidates =
        _catalogue
            .where(
              (item) =>
                  commandText == item.name ||
                  commandText.startsWith('${item.name} '),
            )
            .toList()
          ..sort((a, b) => b.name.length.compareTo(a.name.length));
    final command = candidates.firstOrNull;
    if (command == null || !command.executable) {
      emit(
        CommandsReady(
          _catalogue,
          error:
              command?.disabledReason ??
              'Choose a command available on this pane.',
        ),
      );
      return false;
    }
    final name = command.name;
    final arguments = commandText.substring(name.length).trim();
    final generation = ++_generation;
    emit(CommandsRunning(name));
    try {
      await _commands.execute(name, arguments);
      if (_disposed || generation != _generation) return false;
      emit(CommandsReady(_catalogue));
      return true;
    } on PaneCommandFailure catch (error) {
      if (!_disposed && generation == _generation) {
        emit(CommandsReady(_catalogue, error: error.message));
      }
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _contextSub.cancel();
    super.dispose();
  }
}
