import 'dart:async';
import 'dart:convert';

import 'package:app/data/credentials/credential_crypto.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart' show toStandardB64;
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// One live private credential request for the active (peer, room). Only a
/// request signed by the exact paired Mac key for the exact room is shown.
/// Every async step (signature verification, encryption, sending) is bound to
/// the source it started with: the logical chat (expected Mac key + room), the
/// ConnectionManager's ACTUAL routing (active peer + routed room, which can
/// move while the channel object stays the same) and the channel object, plus
/// an epoch that close/clear/cancel/dispose/replacement bump. A request that
/// was closed, a chat that was left, or routing that moved while an await was
/// in flight can never be resurrected or answered over the wrong route.
/// The plaintext exists only inside [submit] for the duration of encryption
/// and is zeroed afterwards; nothing here is persisted, logged or printed.
class CredentialRequestController extends ChangeNotifier {
  final Future<SimpleKeyPair> Function() _ownerKey;
  final IChannel? Function() _channel;
  final String Function() _expectedMacKey;
  final String Function() _expectedRoom;
  final String Function() _routedPeer;
  final String Function() _routedRoom;
  final DateTime Function() _now;
  final Future<bool> Function(List<int>, CredentialRequest) _verify;
  final Duration ackTimeout;

  CredentialRequest? _pending;
  String? _error;
  bool _submitting = false;
  bool _disposed = false;
  int _epoch = 0;
  int _querySeq = 0;
  String? _queryId;
  String? _verifying;
  Timer? _expiry;
  Timer? _ack;
  StreamSubscription<ServerMessage>? _sub;
  StreamSubscription<void>? _resume;
  final List<StreamSubscription<Object?>> _invalidators = [];
  _Source? _pendingSource;

  CredentialRequestController({
    required Stream<ServerMessage> frames,
    required IChannel? Function() channel,
    required Future<SimpleKeyPair> Function() ownerKey,
    required String Function() expectedMacKey,
    required String Function() expectedRoom,

    /// Actual routing from the ConnectionManager (activePeer.remoteEpk and
    /// activeRoomId). Defaults to the logical chat for callers without one.
    String Function()? routedPeer,
    String Function()? routedRoom,

    /// Status/rooms streams: every event re-validates the pending request's
    /// captured source and drops it when selection or routing moved.
    List<Stream<Object?>> invalidateOn = const [],
    Stream<void>? resumeSignal,
    DateTime Function()? now,
    this.ackTimeout = const Duration(seconds: 25),
    // Test seam only: gate the (otherwise fast) signature verification.
    Future<bool> Function(List<int>, CredentialRequest)? verify,
  }) : _channel = channel,
       _verify = verify ?? verifyCredentialRequest,
       _ownerKey = ownerKey,
       _expectedMacKey = expectedMacKey,
       _expectedRoom = expectedRoom,
       _routedPeer = routedPeer ?? expectedMacKey,
       _routedRoom = routedRoom ?? expectedRoom,
       _now = now ?? DateTime.now {
    _sub = frames.listen(_onFrame);
    _resume = resumeSignal?.listen((_) => query());
    for (final stream in invalidateOn) {
      _invalidators.add(stream.listen((_) => _revalidate()));
    }
  }

  CredentialRequest? get pending => _pending;
  String? get error => _error;
  bool get submitting => _submitting;

  // ── Source binding ─────────────────────────────────────────────────────
  _Source _source() => _Source(
    mac: _expectedMacKey(),
    room: _expectedRoom(),
    routedPeer: _routedPeer(),
    routedRoom: _routedRoom(),
    channel: _channel(),
  );
  static String _std(String key) {
    try {
      return toStandardB64(key);
    } on FormatException {
      return key;
    }
  }

  /// Actual routing must target the logical chat the request belongs to.
  static bool _routed(_Source s) =>
      s.channel != null &&
      s.routedRoom == s.room &&
      s.routedPeer.isNotEmpty &&
      _std(s.routedPeer) == _std(s.mac);
  bool _sameSource(_Source s) => !_disposed && _routed(s) && s == _source();

  /// Selection, reconnect or routing moved: a pending request bound to the
  /// previous source is dropped (never answered over the new route).
  void _revalidate() {
    final s = _pendingSource;
    if (_pending == null || s == null || _sameSource(s)) return;
    _epoch++;
    _clearPending();
    notifyListeners();
  }

  Future<void> _onFrame(ServerMessage msg) async {
    switch (msg) {
      case CredentialRequest():
        await _offer(msg);
      case CredentialClosed(:final id, :final reason, :final inReplyTo):
        // An authoritative "none" for OUR query clears stale UI (a fulfilled
        // or cancelled request whose close/ACK was lost); any closed id that
        // matches the open request also clears it. Both bump the epoch so an
        // in-flight verification of that request cannot bring it back.
        final ours = _queryId != null && inReplyTo == _queryId;
        if ((reason == 'none' && ours) ||
            (_pending != null && _pending!.id == id) ||
            (_verifying != null && _verifying == id)) {
          if (ours) _queryId = null;
          _epoch++;
          _clearPending();
          notifyListeners();
        }
      case CredentialResult(:final id, :final ok, :final error):
        if (_pending?.id != id) return;
        _ack?.cancel();
        _submitting = false;
        _error = ok ? null : _describe(error);
        notifyListeners();
      default:
        break;
    }
  }

  Future<void> _offer(CredentialRequest r) async {
    // An exact replay of the open request (session_sync / query answer) is a
    // no-op: it must not invalidate an in-flight submit.
    if (_pending != null && _pending!.id == r.id && _pending!.sig == r.sig) {
      return;
    }
    final epoch = _epoch;
    final source = _source();
    _verifying = r.id;
    if (source.mac.isEmpty || r.room != source.room || !_routed(source)) {
      return;
    }
    final Uint8List macKey;
    try {
      macKey = base64Decode(toStandardB64(source.mac));
      if (!listEquals(macKey, base64Decode(r.macKey))) return;
    } on FormatException {
      return;
    }
    if (r.expiresAt <= _now().millisecondsSinceEpoch) return;
    final valid = await _verify(macKey, r);
    if (_verifying == r.id) _verifying = null;
    if (!valid) return;
    // A newer frame, a close, a clear, a context switch or dispose superseded
    // this verification while it was in flight.
    if (epoch != _epoch || !_sameSource(source)) return;
    if (_pending?.id == r.id) return;
    // Replacing a different open request invalidates its in-flight work.
    _epoch++;
    _clearPending();
    _pending = r;
    _pendingSource = source;
    _expiry = Timer(
      Duration(milliseconds: r.expiresAt - _now().millisecondsSinceEpoch),
      () {
        _epoch++;
        _clearPending();
        notifyListeners();
      },
    );
    notifyListeners();
  }

  /// Actively recovers the pending state from the Mac (cold open, reconnect,
  /// app resume). The reply is either the replayed signed request or an
  /// authoritative `none` correlated by this query id.
  Future<void> query() async {
    final ch = _channel();
    if (ch == null || _disposed) return;
    final id = 'credq_${_now().microsecondsSinceEpoch}_${++_querySeq}';
    _queryId = id;
    try {
      await ch.send(CredentialQuery(id: id));
    } catch (_) {
      if (_queryId == id) _queryId = null;
    }
  }

  /// Encrypts [secret] for the pending request and ships the ciphertext over
  /// the channel captured BEFORE the crypto awaits. The caller's buffer is
  /// zeroed before this returns, success or not. No automatic resend: a lost
  /// ACK surfaces after [ackTimeout] and the user may cancel.
  Future<void> submit(Uint8List secret) async {
    final r = _pending;
    final epoch = _epoch;
    final source = _source();
    try {
      if (r == null || _submitting) return;
      if (secret.isEmpty) {
        _error = 'Nothing to send.';
        notifyListeners();
        return;
      }
      if (secret.length > maxSecretBytes) {
        _error = 'Too large (max 16 KiB).';
        notifyListeners();
        return;
      }
      if (!_sameSource(source)) {
        _error = 'Not connected — check the link to Pi and retry.';
        notifyListeners();
        return;
      }
      _submitting = true;
      _error = null;
      notifyListeners();
      final CredentialResponse frame;
      try {
        frame = await encryptCredentialResponse(
          request: r,
          secret: secret,
          ownerKey: await _ownerKey(),
          messageId: 'cred_${_now().microsecondsSinceEpoch}',
        );
      } catch (_) {
        if (_pending == r) {
          _submitting = false;
          _error = 'Could not encrypt for this request.';
          notifyListeners();
        }
        return;
      }
      if (_disposed) return;
      if (_pending != r || epoch != _epoch) {
        // Replaced/closed meanwhile; never leave the same request stranded.
        if (_pending == r) {
          _submitting = false;
          notifyListeners();
        }
        return;
      }
      if (!_sameSource(source)) {
        _submitting = false;
        _error = 'The connection changed — check the link to Pi and retry.';
        notifyListeners();
        return;
      }
      var sent = false;
      try {
        await source.channel!.send(frame);
        sent = true;
      } catch (_) {
        sent = false;
      }
      if (_pending != r) return;
      if (epoch != _epoch) {
        _submitting = false;
        notifyListeners();
        return;
      }
      if (!sent) {
        _submitting = false;
        _error = 'Not connected — check the link to Pi and retry.';
        notifyListeners();
        return;
      }
      _ack?.cancel();
      _ack = Timer(ackTimeout, () {
        if (_pending != r || !_submitting) return;
        _submitting = false;
        _error =
            'No confirmation from the Mac. It may still have received the '
            'value; cancel and ask the pane to request again if it is still '
            'blocked.';
        notifyListeners();
      });
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  /// Allowed at any time, including while a submit is unconfirmed.
  Future<void> cancel() async {
    final r = _pending;
    if (r == null) return;
    final ch = _channel();
    _epoch++;
    _clearPending();
    notifyListeners();
    if (ch == null) return;
    try {
      await ch.send(
        CredentialCancel(
          id: 'cred_${_now().microsecondsSinceEpoch}',
          requestId: r.id,
        ),
      );
    } catch (_) {
      /* Nothing to recover; the Mac expires it. */
    }
  }

  /// Context switch (other session/tree): drop without answering and
  /// invalidate every in-flight verification/encryption.
  void clear() {
    _epoch++;
    _queryId = null;
    if (_pending == null && !_submitting) return;
    _clearPending();
    notifyListeners();
  }

  void _clearPending() {
    _pendingSource = null;
    _expiry?.cancel();
    _expiry = null;
    _ack?.cancel();
    _ack = null;
    _pending = null;
    _error = null;
    _submitting = false;
  }

  static String _describe(String? code) => switch (code) {
    'expired' => 'The request expired on the Mac. Ask the pane again.',
    'no_pending' => 'This request is no longer open on the Mac.',
    'not_paired' || 'wrong_phone' => 'This phone is not the paired owner.',
    'too_large' => 'Too large (max 16 KiB).',
    'busy' => 'Already being processed.',
    _ => 'The Mac did not accept it. Ask the pane to request again.',
  };

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _sub?.cancel();
    _resume?.cancel();
    for (final i in _invalidators) {
      i.cancel();
    }
    _expiry?.cancel();
    _ack?.cancel();
    super.dispose();
  }
}

/// Where a request/submit started. Equality is by value for the strings and
/// by identity for the channel object.
@immutable
class _Source {
  final String mac, room, routedPeer, routedRoom;
  final IChannel? channel;
  const _Source({
    required this.mac,
    required this.room,
    required this.routedPeer,
    required this.routedRoom,
    required this.channel,
  });
  @override
  bool operator ==(Object other) =>
      other is _Source &&
      other.mac == mac &&
      other.room == room &&
      other.routedPeer == routedPeer &&
      other.routedRoom == routedRoom &&
      identical(other.channel, channel);
  @override
  int get hashCode => Object.hash(mac, room, routedPeer, routedRoom);
}
