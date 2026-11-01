import 'dart:async';
import 'dart:convert';

import 'package:app/data/location/location_crypto.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart' show toStandardB64;
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Answers a Mac-signed `location_request` for the active (peer, room) with
/// ONE encrypted fix, or an encrypted error (`off`, `denied`, `background`,
/// `unavailable`). Only a request signed by the exact paired Mac key for the
/// exact room and live routing is answered, over the channel captured before
/// any await; a request whose source moved meanwhile is dropped. Nothing is
/// stored or logged. [shared] fires after a fix was actually sent so the UI
/// can say so.
class LocationRequestController {
  final IChannel? Function() _channel;
  final Future<SimpleKeyPair> Function() _ownerKey;
  final String Function() _expectedMacKey, _expectedRoom;
  final String Function() _routedPeer, _routedRoom;
  final bool Function() _enabled, _foreground;
  final Future<String> Function() _permission;
  final Future<Map<String, Object?>> Function() _fix;
  final DateTime Function() _now;
  final Future<bool> Function(List<int>, LocationRequest) _verify;
  final Duration fixTimeout;
  final _shared = StreamController<void>.broadcast();
  StreamSubscription<LocationRequest>? _sub;
  bool _busy = false, _disposed = false;

  /// Verified request ids already answered → their expiry. App-wide (static)
  /// so a recreated chat controller cannot answer a replayed request again.
  static final Map<String, int> _handled = {};
  @visibleForTesting
  static void resetHandled() => _handled.clear();

  LocationRequestController({
    required Stream<LocationRequest> frames,
    required IChannel? Function() channel,
    required Future<SimpleKeyPair> Function() ownerKey,
    required String Function() expectedMacKey,
    required String Function() expectedRoom,
    String Function()? routedPeer,
    String Function()? routedRoom,
    required bool Function() enabled,
    required bool Function() foreground,
    required Future<String> Function() permission,
    required Future<Map<String, Object?>> Function() fix,
    DateTime Function()? now,
    Future<bool> Function(List<int>, LocationRequest)? verify,
    this.fixTimeout = const Duration(seconds: 12),
  }) : _channel = channel,
       _ownerKey = ownerKey,
       _expectedMacKey = expectedMacKey,
       _expectedRoom = expectedRoom,
       _routedPeer = routedPeer ?? expectedMacKey,
       _routedRoom = routedRoom ?? expectedRoom,
       _enabled = enabled,
       _foreground = foreground,
       _permission = permission,
       _fix = fix,
       _now = now ?? DateTime.now,
       _verify = verify ?? verifyLocationRequest {
    _sub = frames.listen(_onRequest);
  }

  Stream<void> get shared => _shared.stream;

  static String _std(String key) {
    try {
      return toStandardB64(key);
    } on FormatException {
      return key;
    }
  }

  List<Object?> _source() => [
    _expectedMacKey(),
    _expectedRoom(),
    _routedPeer(),
    _routedRoom(),
    _channel(),
  ];
  bool _same(List<Object?> s) {
    final now = _source();
    return !_disposed &&
        identical(s[4], now[4]) &&
        listEquals(s.sublist(0, 4), now.sublist(0, 4));
  }

  Future<void> _onRequest(LocationRequest r) async {
    // One at a time; any replay of an answered request is ignored.
    final nowMs = _now().millisecondsSinceEpoch;
    _handled.removeWhere((_, expiry) => expiry <= nowMs);
    final key = '${r.macKey}|${r.room}|${r.session}|${r.id}';
    if (_busy || _disposed || _handled.containsKey(key)) return;
    final source = _source();
    final mac = source[0] as String, room = source[1] as String;
    final routedPeer = source[2] as String, routedRoom = source[3] as String;
    if (source[4] == null ||
        mac.isEmpty ||
        r.room != room ||
        routedRoom != room ||
        routedPeer.isEmpty ||
        _std(routedPeer) != _std(mac)) {
      return;
    }
    final Uint8List macKey;
    try {
      macKey = base64Decode(toStandardB64(mac));
      if (!listEquals(macKey, base64Decode(r.macKey))) return;
    } on FormatException {
      return;
    }
    if (r.expiresAt <= _now().millisecondsSinceEpoch) return;
    _busy = true;
    try {
      if (!await _verify(macKey, r) || !_same(source)) return;
      // Never evict a live marker: at capacity (64 unexpired, i.e. a flood
      // inside one 20 s window) new requests go unanswered instead.
      if (_handled.containsKey(key) || _handled.length >= 64) return;
      _handled[key] = r.expiresAt;
      var payload = await _payload();
      // Sharing turned off, app backgrounded or permission revoked while the
      // fix was being acquired: never send those coordinates.
      if (!payload.containsKey('error')) {
        if (!_enabled()) {
          payload = const {'error': 'off'};
        } else if (!_foreground()) {
          payload = const {'error': 'background'};
        } else if (await _permission() != 'authorized') {
          payload = const {'error': 'denied'};
        }
      }
      if (!_same(source) || r.expiresAt <= _now().millisecondsSinceEpoch) {
        return;
      }
      var frame = await _encrypt(r, payload);
      if (!_same(source)) return;
      // Last synchronous check right before coordinates leave: sharing turned
      // off or app backgrounded during key/encryption awaits → error instead.
      if (!payload.containsKey('error') && (!_enabled() || !_foreground())) {
        payload = {'error': _enabled() ? 'background' : 'off'};
        frame = await _encrypt(r, payload);
        if (!_same(source)) return;
      }
      await (source[4] as IChannel).send(frame);
      if (!payload.containsKey('error') && !_disposed) _shared.add(null);
    } catch (_) {
      /* Nothing sent; the Mac times out and falls back to home, labeled. */
    } finally {
      _busy = false;
    }
  }

  Future<LocationResponse> _encrypt(
    LocationRequest r,
    Map<String, Object?> payload,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    try {
      return await encryptLocationResponse(
        request: r,
        payload: bytes,
        ownerKey: await _ownerKey(),
        messageId: 'loc_${_now().microsecondsSinceEpoch}',
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<Map<String, Object?>> _payload() async {
    if (!_enabled()) return const {'error': 'off'};
    if (!_foreground()) return const {'error': 'background'};
    if (await _permission() != 'authorized') return const {'error': 'denied'};
    final Map<String, Object?> fix;
    try {
      fix = await _fix().timeout(fixTimeout);
    } on TimeoutException {
      return const {'error': 'unavailable'};
    }
    final error = fix['error'];
    if (error != null) {
      return {
        'error': const {'denied', 'background'}.contains(error)
            ? error
            : 'unavailable',
      };
    }
    final lat = fix['lat'], lng = fix['lng'], acc = fix['accuracy_m'];
    final at = fix['captured_at'];
    if (lat is! num || lng is! num || acc is! num || at is! num) {
      return const {'error': 'unavailable'};
    }
    return {
      'lat': lat.toDouble(),
      'lng': lng.toDouble(),
      'accuracy_m': acc.toDouble(),
      'captured_at': at.toInt(),
    };
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _shared.close();
  }
}
