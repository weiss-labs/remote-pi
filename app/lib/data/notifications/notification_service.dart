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

class NotificationService extends Notifications {
  final NotificationPlatform platform;
  final FlutterSecureStorage store;
  final ConnectionManager connection;
  final PairingStorage pairing;
  final Future<SimpleKeyPair> Function() ownerKey;
  final Duration replyTimeout, retryDelay;
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
  StreamSubscription<ConnectionStatus>? _connectionSub;
  StreamSubscription<ServerMessage>? _replySub;
  Timer? _retry;
  IChannel? _channel;
  bool _started = false, _disposed = false, _busy = false, _dirty = false;
  bool _ready = false;
  Completer<NotificationRegistration>? _pending;
  String? _pendingId;
  int _counter = 0;
  int _lastGrantExpiry = 0;
  @override
  NotificationPreferences get preferences => _preferences;
  @override
  String get permission => _permission;
  @override
  String get status => supported ? _status : 'Available on iOS';
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
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _preferences = NotificationPreferences.fromJson(decoded);
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
    _bind();
    // status never requests authorization. Only the explicit UI action does.
    await refresh();
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
    _pending?.complete(
      const NotificationRegistration(
        inReplyTo: '',
        ok: false,
        error: 'connection_changed',
      ),
    );
    _pending = null;
    _replySub = channel?.serverMessages.listen((message) {
      if (message is NotificationRegistration &&
          message.inReplyTo == _pendingId) {
        _pending?.complete(message);
        _pending = null;
      }
    });
    unawaited(_register());
  }

  @override
  Future<void> refresh() async {
    if (!supported || _disposed || !_ready) return;
    try {
      final value = await platform.status();
      _permission = value['permission'] as String? ?? 'notDetermined';
      _token = value['token'] as String? ?? '';
      _environment = value['environment'] as String? ?? '';
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
    await store.write(
      key: 'notifications.preferences',
      value: jsonEncode(value.toJson()),
    );
    _emit();
    await _register();
  }

  Future<void> _register() async {
    if (_disposed || !supported || !_ready || _permission == 'unknown') return;
    if (_busy) {
      _dirty = true;
      return;
    }
    _retry?.cancel();
    final enabled =
        _preferences.enabled &&
        (_permission == 'authorized' || _permission == 'provisional');
    if (enabled &&
        (_token.isEmpty || !{'production', 'sandbox'}.contains(_environment))) {
      _status = !_preferences.enabled
          ? 'Off'
          : _permission == 'denied'
          ? 'Permission denied. Open iOS Settings.'
          : 'Waiting for iOS push token';
      _emit();
      return;
    }
    final channel = _channel;
    final peer = connection.activePeer;
    if (channel == null || peer == null) {
      _status = 'Waiting for paired connection';
      _emit();
      return;
    }
    _busy = true;
    try {
      final peers = await pairing.listPeers();
      if (!peers.any(
            (p) => toStandardB64(p.remoteEpk) == toStandardB64(peer.remoteEpk),
          ) ||
          !identical(channel, _channel)) {
        return;
      }
      _status = 'Saving notification settings…';
      _emit();
      final id =
          'notify-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
      final ClientMessage message;
      if (enabled) {
        _lastGrantExpiry = max(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7 * 86400,
          _lastGrantExpiry + 1,
        );
        await store.write(
          key: 'notifications.grant_expiry',
          value: '$_lastGrantExpiry',
        );
        message = await signNotificationGrant(
          toStandardB64(peer.remoteEpk),
          await ownerKey(),
          NotifyRegister(
            id: id,
            deviceId: _deviceId,
            token: _token,
            environment: _environment,
            categories: _preferences.categories.toList(),
            showPaneName: _preferences.showPaneName,
            expiresAt: _lastGrantExpiry,
            signature: '',
          ),
        );
      } else {
        message = NotifyUnregister(id: id, deviceId: _deviceId);
      }
      if (_disposed ||
          !identical(channel, _channel) ||
          !(await pairing.listPeers()).any(
            (p) => toStandardB64(p.remoteEpk) == toStandardB64(peer.remoteEpk),
          )) {
        return;
      }
      final pending = Completer<NotificationRegistration>();
      _pending = pending;
      _pendingId = id;
      // Attach the waiter before send, including synchronous fake channels.
      await channel.send(message);
      final reply = await pending.future.timeout(replyTimeout);
      _status = reply.ok
          ? (enabled ? 'Ready for this paired Mac' : 'Off for this paired Mac')
          : {'apns_disabled', 'apns_unconfigured'}.contains(reply.error)
          ? 'Push service is not configured yet'
          : 'Registration declined. Retry after reconnecting.';
      if (!reply.ok) _scheduleRetry();
    } on TimeoutException {
      _status = 'No confirmation yet. Retrying…';
      _scheduleRetry();
    } on Exception {
      _status = 'Connection unavailable. Retrying…';
      _scheduleRetry();
    } finally {
      _pending = null;
      _pendingId = null;
      _busy = false;
      _emit();
      if (_dirty) {
        _dirty = false;
        unawaited(_register());
      }
    }
  }

  void _scheduleRetry() {
    if (!_disposed) _retry = Timer(retryDelay, () => unawaited(_register()));
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
    _retry?.cancel();
    _connectionSub?.cancel();
    _replySub?.cancel();
    _changes.close();
    _taps.close();
    super.dispose();
  }
}
