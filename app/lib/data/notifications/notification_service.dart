import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'notification_grant.dart';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:app/domain/contracts/notifications.dart';
import 'package:app/data/notifications/native_notifications.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

class _PendingRegistration {
  final String peer, room;
  final Completer<NotificationRegistration> result;
  _PendingRegistration(this.peer, this.room, this.result);
}

class NotificationService extends Notifications {
  final NotificationPlatform platform;
  final FlutterSecureStorage store;
  final ConnectionManager connection;
  final PairingStorage pairing;
  final Future<SimpleKeyPair> Function() ownerKey;
  final Duration replyTimeout, retryDelay, renewalInterval;
  @override
  final bool supported;
  NotificationService({
    required this.platform,
    required this.store,
    required this.connection,
    required this.pairing,
    required this.supported,
    required this.ownerKey,
    this.replyTimeout = const Duration(seconds: 20),
    this.retryDelay = const Duration(seconds: 30),
    this.renewalInterval = const Duration(hours: 12),
  });
  NotificationPreferences _preferences = const NotificationPreferences();
  String _permission = 'unknown',
      _status = 'Off',
      _deviceId = '',
      _token = '',
      _environment = '';
  final _changes = StreamController<void>.broadcast();
  final _taps = StreamController<NotificationTarget>.broadcast();
  final Set<String> _seen = {};
  final Map<String, _PendingRegistration> _pending = {};
  final Map<String, String> _synced = {};
  final Map<String, int> _roomAttempts = {};
  final Map<String, String> _macStates = {};
  StreamSubscription<ConnectionStatus>? _connectionSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<dynamic>? _replySub;
  Timer? _retry, _renewal;
  IChannel? _channel;
  bool _started = false,
      _disposed = false,
      _busy = false,
      _dirty = false,
      _ready = false;
  int _counter = 0, _revision = 0, _lastGrantExpiry = 0;
  @override
  NotificationPreferences get preferences => _preferences;
  @override
  String get permission => _permission;
  @override
  String get status => supported ? _status : 'Available on iOS';
  @override
  Map<String, String> get peerSyncStates => Map.unmodifiable(_macStates);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<NotificationTarget> get taps => _taps.stream;
  void _emit() {
    if (!_disposed) _changes.add(null);
  }

  @override
  Future<void> start() async {
    if (_started || !supported) return;
    _started = true;
    _deviceId = await store.read(key: 'notifications.device_id') ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await store.write(key: 'notifications.device_id', value: _deviceId);
    }
    _lastGrantExpiry =
        int.tryParse(
          await store.read(key: 'notifications.grant_expiry') ?? '',
        ) ??
        0;
    final raw = await store.read(key: 'notifications.preferences');
    if (raw != null) {
      try {
        final value = jsonDecode(raw);
        if (value is Map<String, dynamic>) {
          _preferences = NotificationPreferences.fromJson(value);
        }
      } on FormatException {
        _status = 'Preferences reset';
      }
    }
    _seen.addAll(
      (await store.read(key: 'notifications.seen') ?? '')
          .split('\n')
          .where((s) => s.isNotEmpty),
    );
    platform.listen((method, value) {
      if (_disposed) return;
      if (method == 'tap') {
        final target = NotificationTarget.parse(value);
        if (target != null) _taps.add(target);
      }
      if (method == 'tokenChanged') unawaited(refresh());
      if (method == 'registrationFailed') {
        _status =
            'iOS push registration failed. Check signing and connectivity.';
        _emit();
      }
    });
    _ready = true;
    _connectionSub = connection.statusStream.listen((_) => _bind());
    _roomsSub = connection.roomsStream.listen((_) => unawaited(_register()));
    _renewal = Timer.periodic(renewalInterval, (_) {
      _synced.clear();
      _revision++;
      unawaited(_register());
    });
    _bind();
    // Cold taps must not wait for network registration ACKs.
    unawaited(refresh());
    for (final value in await platform.takeTaps()) {
      final target = NotificationTarget.parse(value);
      if (target != null) _taps.add(target);
    }
  }

  void _bind() {
    final channel = connection.channel;
    if (identical(channel, _channel)) return;
    _replySub?.cancel();
    _channel = channel;
    _synced.clear();
    _revision++;
    for (final pending in _pending.values) {
      if (!pending.result.isCompleted) {
        pending.result.complete(
          const NotificationRegistration(
            inReplyTo: '',
            ok: false,
            error: 'connection_changed',
          ),
        );
      }
    }
    _pending.clear();
    if (channel is INotificationRoutes) {
      _replySub = (channel as INotificationRoutes).notificationReplies.listen((
        envelope,
      ) {
        final pending = _pending[envelope.reply.inReplyTo];
        if (pending == null ||
            pending.peer != toStandardB64(envelope.peer) ||
            pending.room != envelope.room) {
          return;
        }
        _pending.remove(envelope.reply.inReplyTo);
        if (!pending.result.isCompleted) {
          pending.result.complete(envelope.reply);
        }
      });
    } else {
      // Compatibility for simple in-memory channels. Production uses source-bound routes.
      _replySub = channel?.serverMessages.listen((message) {
        if (message is! NotificationRegistration) return;
        final pending = _pending[message.inReplyTo];
        if (pending == null ||
            pending.peer !=
                toStandardB64(connection.activePeer?.remoteEpk ?? '') ||
            pending.room != connection.activeRoomId) {
          return;
        }
        _pending.remove(message.inReplyTo);
        if (!pending.result.isCompleted) pending.result.complete(message);
      });
    }
    unawaited(_register());
  }

  @override
  Future<void> refresh() async {
    if (!supported || _disposed || !_ready) return;
    try {
      final value = await platform.status();
      final permission = value['permission'] as String? ?? 'notDetermined';
      final token = value['token'] as String? ?? '';
      final environment = value['environment'] as String? ?? '';
      if (permission != _permission ||
          token != _token ||
          environment != _environment) {
        _revision++;
      }
      _permission = permission;
      _token = token;
      _environment = environment;
      await store.write(key: 'notifications.permission', value: _permission);
      await _register();
    } on PlatformException {
      _status = 'iOS notifications unavailable';
      _emit();
    }
  }

  @override
  Future<void> requestPermission() async {
    if (!supported) return;
    try {
      await platform.requestPermission();
      await refresh();
    } on PlatformException {
      _status = 'Could not request permission';
      _emit();
    }
  }

  @override
  Future<void> update(NotificationPreferences value) async {
    _preferences = value;
    _revision++;
    await store.write(
      key: 'notifications.preferences',
      value: jsonEncode(value.toJson()),
    );
    _emit();
    await _register();
  }

  String? _liveRoom(PeerRecord peer, IChannel channel) {
    final rooms = connection
        .roomsFor(peer.remoteEpk)
        .where((r) => connection.isRoomLive(peer.remoteEpk, r.roomId))
        .toList();
    if (rooms.isNotEmpty) {
      rooms.sort((a, b) {
        if (a.roomId == connection.activeRoomId) return -1;
        if (b.roomId == connection.activeRoomId) return 1;
        return a.roomId.compareTo(b.roomId);
      });
      final attempt = _roomAttempts[toStandardB64(peer.remoteEpk)] ?? 0;
      return rooms[attempt % rooms.length].roomId;
    }
    // Legacy fake channels cannot advertise rooms. Never guess on production routing.
    if (channel is! INotificationRoutes &&
        toStandardB64(connection.activePeer?.remoteEpk ?? '') ==
            toStandardB64(peer.remoteEpk)) {
      return connection.activeRoomId;
    }
    return null;
  }

  Future<ClientMessage> _message(String peer, bool enabled) async {
    final id = 'notify-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    if (!enabled) return NotifyUnregister(id: id, deviceId: _deviceId);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiry = max(now + 29 * 86400, _lastGrantExpiry + 1);
    if (expiry > now + 30 * 86400) {
      throw const FormatException('Grant expiry exceeds allowed clock window');
    }
    _lastGrantExpiry = expiry;
    await store.write(key: 'notifications.grant_expiry', value: '$expiry');
    return signNotificationGrant(
      peer,
      await ownerKey(),
      NotifyRegister(
        id: id,
        deviceId: _deviceId,
        token: _token,
        environment: _environment,
        categories: _preferences.categories.toList(),
        showPaneName: _preferences.showPaneName,
        showQuestionPreview:
            _preferences.showPaneName && _preferences.showQuestionPreview
            ? true
            : null,
        expiresAt: expiry,
        signature: '',
      ),
    );
  }

  Future<NotificationRegistration> _send(
    IChannel channel,
    String peer,
    String room,
    ClientMessage message,
  ) async {
    final id = message.toJson()['id'] as String;
    final result = Completer<NotificationRegistration>();
    _pending[id] = _PendingRegistration(peer, room, result);
    try {
      if (channel is INotificationRoutes) {
        await (channel as INotificationRoutes).sendNotificationTo(
          message,
          peer: peer,
          room: room,
        );
      } else {
        await channel.send(message);
      }
      return await result.future.timeout(replyTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _register() async {
    if (_disposed || !supported || !_ready || _permission == 'unknown') return;
    if (_busy) {
      _dirty = true;
      return;
    }
    _retry?.cancel();
    _busy = true;
    final revision = _revision;
    final enabled =
        _preferences.enabled &&
        {'authorized', 'provisional'}.contains(_permission);
    final fingerprint = jsonEncode([
      enabled,
      _token,
      _environment,
      _preferences.toJson(),
    ]);
    var needsRetry = false;
    try {
      final peers = await pairing.listPeers();
      final keys = peers.map((p) => toStandardB64(p.remoteEpk)).toSet();
      _macStates.removeWhere((key, _) => !keys.contains(key));
      _synced.removeWhere((key, _) => !keys.contains(key));
      _roomAttempts.removeWhere((key, _) => !keys.contains(key));
      for (final peer in peers) {
        if (_disposed || revision != _revision) {
          _dirty = true;
          break;
        }
        final key = toStandardB64(peer.remoteEpk);
        final label = peer.nickname ?? peer.sessionName;
        if (_synced[key] == fingerprint) continue;
        final channel = _channel;
        final room = channel == null ? null : _liveRoom(peer, channel);
        if (channel == null || room == null) {
          _macStates[key] = '$label: pending, no live pane';
          needsRetry = true;
          continue;
        }
        if (enabled &&
            (_token.isEmpty ||
                !{'production', 'sandbox'}.contains(_environment))) {
          _macStates[key] = '$label: waiting for iOS push token';
          needsRetry = true;
          continue;
        }
        _macStates[key] = '$label: saving…';
        _status = 'Saving notification settings…';
        _emit();
        try {
          final message = await _message(key, enabled);
          if (_disposed ||
              revision != _revision ||
              !identical(channel, _channel)) {
            _dirty = true;
            break;
          }
          if (!(await pairing.listPeers()).any(
            (p) => toStandardB64(p.remoteEpk) == key,
          )) {
            continue;
          }
          if (_liveRoom(peer, channel) != room) {
            needsRetry = true;
            _macStates[key] = '$label: pending, pane changed';
            continue;
          }
          final reply = await _send(channel, key, room, message);
          if (reply.ok) {
            _synced[key] = fingerprint;
            _macStates[key] = '$label: ${enabled ? 'ready' : 'off'}';
          } else {
            needsRetry = true;
            if (!{'apns_disabled', 'apns_unconfigured'}.contains(reply.error)) {
              _roomAttempts[key] = (_roomAttempts[key] ?? 0) + 1;
            }
            _macStates[key] =
                '$label: ${{'apns_disabled', 'apns_unconfigured'}.contains(reply.error) ? 'push service not configured' : 'pending, registration declined'}';
          }
        } on TimeoutException {
          needsRetry = true;
          _roomAttempts[key] = (_roomAttempts[key] ?? 0) + 1;
          _macStates[key] =
              '$label: pending, no confirmation; trying another live pane';
        } on Exception {
          needsRetry = true;
          _macStates[key] = '$label: pending, connection unavailable';
        } on StateError {
          needsRetry = true;
          _macStates[key] = '$label: pending, connection unavailable';
        }
        _emit();
      }
      final remaining = keys.where((key) => _synced[key] != fingerprint).length;
      if (keys.isEmpty) {
        _status = enabled ? 'Pair a Mac to receive notifications' : 'Off';
      } else if (remaining == 0) {
        _status = keys.length == 1
            ? (enabled
                  ? 'Ready for this paired Mac'
                  : 'Off for this paired Mac')
            : '${enabled ? 'Ready' : 'Off'} on all ${keys.length} paired Macs';
      } else if (_macStates.values.any(
        (value) => value.contains('push service not configured'),
      )) {
        _status = 'Push service is not configured yet';
      } else {
        _status =
            'Pending on $remaining paired ${remaining == 1 ? 'Mac' : 'Macs'}. Offline Macs keep their previous settings until confirmed.';
      }
    } on Exception {
      needsRetry = true;
      _status = 'Notification settings pending. Retrying…';
    } finally {
      _busy = false;
      _emit();
      if (_dirty) {
        _dirty = false;
        unawaited(_register());
      } else if (needsRetry && !_disposed) {
        _retry = Timer(retryDelay, () => unawaited(_register()));
      }
    }
  }

  @override
  Future<bool> acceptTap(NotificationTarget target) async {
    final key = '${toStandardB64(target.peer)}|${target.eventId}';
    if (_seen.contains(key)) return false;
    final peers = await pairing.listPeers();
    if (!peers.any(
      (p) => toStandardB64(p.remoteEpk) == toStandardB64(target.peer),
    )) {
      return false;
    }
    // Recheck after the asynchronous pairing read for simultaneous deliveries.
    if (_seen.contains(key)) return false;
    // Record only validated taps. Never accept a route or an action from payload.
    _seen.add(key);
    while (_seen.length > 128) {
      _seen.remove(_seen.first);
    }
    await store.write(key: 'notifications.seen', value: _seen.join('\n'));
    return true;
  }

  @override
  Future<bool> isKnownRoom(NotificationTarget target) async {
    if (target.room.isEmpty) return false;
    final peers = await pairing.listPeers();
    final peer = peers
        .where((p) => toStandardB64(p.remoteEpk) == toStandardB64(target.peer))
        .firstOrNull;
    if (peer == null) return false;
    // The paired QR room and relay-announced/cached rooms are authoritative.
    if (peer.roomId == target.room ||
        connection
            .roomsFor(peer.remoteEpk)
            .any((room) => room.roomId == target.room)) {
      return true;
    }
    // Read storage directly: a cold tap can arrive before ConnectionManager
    // finishes its asynchronous room-cache hydration.
    final rooms = await pairing.loadRooms(peer.remoteEpk);
    return rooms.any((room) => room.roomId == target.room);
  }

  @override
  Future<void> visibleTarget(String? peer, String? room) async {
    if (supported) {
      await platform.visibleTarget(
        peer == null ? null : toStandardB64(peer),
        room,
      );
    }
  }

  @override
  Future<void> openSettings() => platform.openSettings();
  @override
  void dispose() {
    _disposed = true;
    for (final pending in _pending.values) {
      if (!pending.result.isCompleted) {
        pending.result.complete(
          const NotificationRegistration(
            inReplyTo: '',
            ok: false,
            error: 'disposed',
          ),
        );
      }
    }
    _pending.clear();
    _retry?.cancel();
    _connectionSub?.cancel();
    _roomsSub?.cancel();
    _renewal?.cancel();
    _replySub?.cancel();
    _changes.close();
    _taps.close();
    super.dispose();
  }
}
