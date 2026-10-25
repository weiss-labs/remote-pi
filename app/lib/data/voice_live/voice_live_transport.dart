import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

/// Plan 71 — talks to the pane's Pi Voice bridge over the relay. Requests are
/// correlated by id; replies come back as `voice_opened` / `voice_error` /
/// `voice_rpc_result` on the active pane's channel.
abstract class VoiceRpcTransport {
  Future<VoiceOpenResult> open();
  Future<VoiceRpcReply> rpc(
    String path, [
    Map<String, dynamic> body = const {},
  ]);
  Future<void> close();
}

class VoiceOpenResult {
  const VoiceOpenResult({required this.label, required this.ratePerMinute});
  final String label;
  final double ratePerMinute;
}

class VoiceRpcReply {
  const VoiceRpcReply(this.status, this.body);
  final int status;
  final Object? body;

  bool get ok => status >= 200 && status < 300;
  Map<String, dynamic> get map =>
      body is Map<String, dynamic> ? body as Map<String, dynamic> : const {};
  String get error =>
      (map['error'] as String?) ?? 'Pi Voice request failed ($status)';
}

class VoiceFailure implements Exception {
  const VoiceFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class RelayVoiceTransport implements VoiceRpcTransport {
  RelayVoiceTransport(
    this._conn, {
    Duration timeout = const Duration(seconds: 30),
  }) : _timeout = timeout;

  final ConnectionManager _conn;
  final Duration _timeout;
  final Map<String, Completer<ServerMessage>> _pending = {};
  StreamSubscription<ServerMessage>? _sub;
  IChannel? _subscribed;

  IChannel _channel() {
    final s = _conn.status;
    if (s is! StatusOnline) {
      throw const VoiceFailure('offline', 'Not connected to the Mac.');
    }
    if (!identical(_subscribed, s.channel)) {
      _sub?.cancel();
      _subscribed = s.channel;
      _sub = s.channel.serverMessages.listen(
        _onMessage,
        onError: (Object _, StackTrace _) {},
      );
    }
    return s.channel;
  }

  void _onMessage(ServerMessage m) {
    final id = switch (m) {
      VoiceOpened(:final inReplyTo) => inReplyTo,
      VoiceError(:final inReplyTo) => inReplyTo,
      VoiceRpcResult(:final inReplyTo) => inReplyTo,
      _ => null,
    };
    if (id == null) return;
    final c = _pending.remove(id);
    if (c != null && !c.isCompleted) c.complete(m);
  }

  Future<ServerMessage> _send(ClientMessage Function(String id) build) async {
    final ch = _channel();
    final id = 'voice_${uuid7()}';
    final c = Completer<ServerMessage>();
    _pending[id] = c;
    try {
      await ch.send(build(id));
      return await c.future.timeout(_timeout);
    } on TimeoutException {
      throw const VoiceFailure('timeout', 'The Mac did not answer in time.');
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<VoiceOpenResult> open() async {
    final m = await _send((id) => VoiceOpen(id: id));
    return switch (m) {
      VoiceOpened(:final label, :final ratePerMinute) => VoiceOpenResult(
        label: label,
        ratePerMinute: ratePerMinute,
      ),
      VoiceError(:final code, :final message) => throw VoiceFailure(
        code,
        message,
      ),
      _ => throw const VoiceFailure(
        'unavailable',
        'Unexpected reply from the Mac.',
      ),
    };
  }

  @override
  Future<VoiceRpcReply> rpc(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    final m = await _send((id) => VoiceRpc(id: id, path: path, body: body));
    if (m is VoiceRpcResult) return VoiceRpcReply(m.status, m.body);
    throw const VoiceFailure('unavailable', 'Unexpected reply from the Mac.');
  }

  @override
  Future<void> close() async {
    try {
      await _send((id) => VoiceClose(id: id));
    } catch (_) {
      // Best effort: the Mac's heartbeat watchdog ends the session anyway.
    } finally {
      await _sub?.cancel();
      _sub = null;
      _subscribed = null;
    }
  }
}
