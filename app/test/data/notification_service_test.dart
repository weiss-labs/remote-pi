import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:app/data/notifications/notification_grant.dart';
import 'package:app/data/notifications/native_notifications.dart';
import 'package:app/data/notifications/notification_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/entities/notification_preferences.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'cGVlcg==',
  sessionName: 'Mac',
  relayUrl: 'https://example.invalid',
  pairedAt: '2026-01-01',
  roomId: 'room-a',
);

class Storage extends PairingStorage {
  List<PeerRecord> peers = [peer];
  @override
  Future<List<PeerRecord>> listPeers() async => peers;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => [];
}

class Platform extends NotificationPlatform {
  int prompts = 0;
  String token = 'aa', permission = 'authorized';
  void Function(String, dynamic)? listener;
  List<dynamic> pending = [];
  String? visiblePeer, visibleRoom;
  @override
  Future<Map<String, dynamic>> status() async => {
    'token': token,
    'permission': permission,
    'environment': 'production',
  };
  @override
  Future<Map<String, dynamic>> requestPermission() async {
    prompts++;
    return status();
  }

  @override
  Future<List<dynamic>> takeTaps() async => pending;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> visibleTarget(String? peer, String? room) async {
    visiblePeer = peer;
    visibleRoom = room;
  }

  @override
  void listen(void Function(String, dynamic) value) {
    listener = value;
  }
}

class Channel implements IChannel {
  final messages = StreamController<ServerMessage>.broadcast(sync: true);
  final sent = <ClientMessage>[];
  bool ack = true;
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Future<void> send(ClientMessage message) async {
    if (message is NotifyRegister || message is NotifyUnregister) {
      sent.add(message);
      if (ack) {
        messages.add(
          NotificationRegistration(
            inReplyTo: message.toJson()['id'] as String,
            ok: true,
          ),
        );
      }
    }
  }

  @override
  Future<void> close() async {}
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<SimpleKeyPair> ownerKey() =>
      Ed25519().newKeyPairFromSeed(List.filled(32, 1));
  late Storage storage;
  late Platform platform;
  late Channel channel;
  late ConnectionManager connection;
  late NotificationService service;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = Storage();
    platform = Platform();
    channel = Channel();
    connection = ConnectionManager(
      factory: (_, _) async => channel,
      storage: storage,
    );
    service = NotificationService(
      platform: platform,
      store: const FlutterSecureStorage(),
      connection: connection,
      pairing: storage,
      supported: true,
      ownerKey: ownerKey,
      replyTimeout: const Duration(seconds: 2),
      retryDelay: const Duration(milliseconds: 30),
    );
  });
  tearDown(() async {
    service.dispose();
    connection.dispose();
    await channel.messages.close();
  });

  test(
    'startup never prompts; defaults are generic and three categories only',
    () async {
      platform.permission = 'notDetermined';
      platform.token = '';
      await service.start();
      expect(platform.prompts, 0);
      expect(service.preferences.enabled, false);
      expect(service.preferences.showPaneName, false);
      expect(service.preferences.categories, {
        'input_needed',
        'task_finished',
        'task_failed',
      });
      await service.requestPermission();
      expect(platform.prompts, 1);
    },
  );
  test('preferences, permission and stable device id persist', () async {
    await service.start();
    await service.update(
      const NotificationPreferences(
        enabled: true,
        categories: {'input_needed', 'review_ready'},
        showPaneName: true,
      ),
    );
    const store = FlutterSecureStorage();
    final device = await store.read(key: 'notifications.device_id');
    expect(device, isNotEmpty);
    expect(await store.read(key: 'notifications.permission'), 'authorized');
    service.dispose();
    service = NotificationService(
      platform: platform,
      store: store,
      connection: connection,
      pairing: storage,
      supported: true,
      ownerKey: ownerKey,
    );
    await service.start();
    expect(await store.read(key: 'notifications.device_id'), device);
    expect(service.preferences.categories, {'input_needed', 'review_ready'});
    expect(service.preferences.enabled, true);
    expect(service.preferences.showPaneName, true);
  });
  test('registration waits for correlated ACK, not socket write', () async {
    channel.ack = false;
    await service.start();
    await connection.connectTo(peer);
    await settle();
    expect(channel.sent, isNotEmpty);
    expect(service.status, contains('Saving'));
    channel.messages.add(
      const NotificationRegistration(inReplyTo: 'wrong-id', ok: true),
    );
    await settle();
    expect(service.status, contains('Saving'));
    channel.messages.add(
      NotificationRegistration(
        inReplyTo: channel.sent.last.toJson()['id'] as String,
        ok: true,
      ),
    );
    await settle();
    expect(service.status, 'Off for this paired Mac');
  });
  test(
    'timeout retries; reconnect and token rotation register again',
    () async {
      await service.start();
      await service.update(service.preferences.copyWith(enabled: true));
      channel.ack = false;
      await connection.connectTo(peer);
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (channel.sent.length < 2 && DateTime.now().isBefore(deadline)) {
        await settle();
      }
      expect(channel.sent.length, greaterThanOrEqualTo(2));
      channel.ack = true;
      channel.messages.add(
        NotificationRegistration(
          inReplyTo: channel.sent.last.toJson()['id'] as String,
          ok: true,
        ),
      );
      await settle();
      platform.token = 'bb';
      platform.listener!('tokenChanged', null);
      await settle();
      expect((channel.sent.last as NotifyRegister).token, 'bb');
      final count = channel.sent.length;
      await connection.disconnect();
      await settle();
      await connection.connectTo(peer);
      await settle();
      expect(channel.sent.length, greaterThan(count));
    },
  );
  test(
    'unpaired target is refused and validated taps deduplicate across launches',
    () async {
      await service.start();
      expect(
        await service.acceptTap(
          const NotificationTarget('ZXZpbA==', 'room-a', 'event1'),
        ),
        false,
      );
      const target = NotificationTarget('cGVlcg==', 'room-a', 'event1');
      expect(await service.acceptTap(target), true);
      expect(await service.acceptTap(target), false);
      service.dispose();
      service = NotificationService(
        platform: platform,
        store: const FlutterSecureStorage(),
        connection: connection,
        pairing: storage,
        supported: true,
        ownerKey: ownerKey,
      );
      await service.start();
      expect(await service.acceptTap(target), false);
      storage.peers = [];
      expect(
        await service.acceptTap(
          const NotificationTarget('cGVlcg==', 'room-a', 'event2'),
        ),
        false,
      );
    },
  );
  test(
    'cold and warm taps share strict parser; arbitrary routes are ignored',
    () async {
      final payload = {
        'v': 1,
        'peer': peer.remoteEpk,
        'room': 'room-a',
        'event_id': 'id',
        'kind': 'input_needed',
        'route': '/malicious',
      };
      platform.pending = [payload];
      final taps = <NotificationTarget>[];
      service.taps.listen(taps.add);
      await service.start();
      await settle();
      expect(taps.single.room, 'room-a');
      platform.listener!('tap', {...payload, 'event_id': 'warm'});
      await settle();
      expect(taps.last.eventId, 'warm');
      expect(NotificationTarget.parse({'route': '/chat'}), null);
      expect(NotificationTarget.parse({...payload, 'v': 2}), null);
      expect(NotificationTarget.parse({...payload, 'kind': 'arbitrary'}), null);
    },
  );
  test(
    'disabled preferences unregister explicitly; signed grant contains no content',
    () async {
      await service.start();
      await connection.connectTo(peer);
      await settle();
      expect(channel.sent.last, isA<NotifyUnregister>());
      await service.update(service.preferences.copyWith(enabled: true));
      final message = channel.sent.last as NotifyRegister;
      final json = message.toJson();
      final key = await ownerKey();
      final publicKey = await key.extractPublicKey();
      expect(
        await Ed25519().verify(
          notificationGrantBytes(
            peer.remoteEpk,
            base64Encode(publicKey.bytes),
            message,
          ),
          signature: Signature(
            base64Decode(message.signature),
            publicKey: publicKey,
          ),
        ),
        true,
      );
      expect(
        utf8.decode(notificationGrantBytes('peer', 'phone', message)),
        'remote-pi-notify-device-v1\n${jsonEncode(['peer', 'phone', message.deviceId, message.token, message.environment, message.categories, message.showPaneName, message.expiresAt])}',
      );
      expect(json.keys.toSet(), {
        'type',
        'id',
        'device_id',
        'token',
        'environment',
        'categories',
        'show_pane_name',
        'expires_at',
        'signature',
      });
      await service.update(service.preferences.copyWith(enabled: false));
      expect(channel.sent.last, isA<NotifyUnregister>());
      await service.update(service.preferences.copyWith(enabled: true));
      expect(
        (channel.sent.last as NotifyRegister).expiresAt,
        greaterThan(message.expiresAt),
      );
      expect(jsonEncode(json), isNot(contains('sessionName')));
    },
  );
  test('unpaired connection never receives a registration', () async {
    await service.start();
    storage.peers = [];
    await connection.connectTo(peer);
    await settle();
    expect(channel.sent, isEmpty);
  });
}
