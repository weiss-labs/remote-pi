import 'dart:async';
import 'package:app/data/notifications/native_notifications.dart';
import 'package:app/data/notifications/notification_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const a = PeerRecord(
  remoteEpk: 'YQ==',
  sessionName: 'Mac A',
  relayUrl: 'https://example.invalid',
  pairedAt: '2026',
  roomId: 'closed-selected',
);
const b = PeerRecord(
  remoteEpk: 'Yg==',
  sessionName: 'Mac B',
  relayUrl: 'https://example.invalid',
  pairedAt: '2026',
  roomId: 'live-b',
);
const c = PeerRecord(
  remoteEpk: 'Yw==',
  sessionName: 'Offline Mac',
  relayUrl: 'https://example.invalid',
  pairedAt: '2026',
  roomId: 'closed-c',
);

class Storage extends PairingStorage {
  List<PeerRecord> peers = [a, b, c];
  @override
  Future<List<PeerRecord>> listPeers() async => peers;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

class Platform extends NotificationPlatform {
  String token = 'aa' * 32;
  @override
  Future<Map<String, dynamic>> status() async => {
    'permission': 'authorized',
    'token': token,
    'environment': 'production',
  };
  @override
  Future<Map<String, dynamic>> requestPermission() => status();
  @override
  Future<List<dynamic>> takeTaps() async => [];
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> visibleTarget(String? peer, String? room) async {}
  @override
  void listen(void Function(String, dynamic) listener) {}
}

class Channel implements IChannel, IControlLink, INotificationRoutes {
  final messages = StreamController<ServerMessage>.broadcast();
  final controls = StreamController<ControlInbound>.broadcast();
  final replies = StreamController<RoutedNotificationReply>.broadcast(
    sync: true,
  );
  final sent = <(String, String, ClientMessage)>[];
  bool autoAck = true;
  String? rejectedRoom;
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => controls.stream;
  @override
  Stream<RoutedNotificationReply> get notificationReplies => replies.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage message) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> sendNotificationTo(
    ClientMessage message, {
    required String peer,
    required String room,
  }) async {
    sent.add((peer, room, message));
    if (autoAck) ack(peer, room, message);
  }

  void ack(String peer, String room, ClientMessage message) => replies.add(
    RoutedNotificationReply(
      peer: peer,
      room: room,
      reply: NotificationRegistration(
        inReplyTo: message.toJson()['id'] as String,
        ok: room != rejectedRoom,
        error: room == rejectedRoom ? 'unsupported_type' : null,
      ),
    ),
  );
  void live(PeerRecord peer, String room) => controls.add(
    RoomsSnapshot(
      peer: peer.remoteEpk,
      rooms: [RoomInfo(roomId: room, startedAt: 1)],
    ),
  );
}

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Storage storage;
  late Platform platform;
  late Channel channel;
  late ConnectionManager conn;
  late NotificationService service;
  Future<void> setup({
    Duration renewal = const Duration(hours: 12),
    Duration retry = const Duration(seconds: 30),
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    storage = Storage();
    platform = Platform();
    channel = Channel();
    conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: storage,
      emitDebounce: Duration.zero,
    );
    await conn.connectTo(a);
    channel.live(a, 'live-a');
    channel.live(b, 'live-b');
    await until(() => conn.isRoomLive(b.remoteEpk, 'live-b'));
    service = NotificationService(
      platform: platform,
      store: const FlutterSecureStorage(),
      connection: conn,
      pairing: storage,
      supported: true,
      ownerKey: () => Ed25519().newKeyPairFromSeed(List.filled(32, 1)),
      renewalInterval: renewal,
      retryDelay: retry,
    );
    await service.start();
    await until(() => channel.sent.length >= 2);
  }

  tearDown(() async {
    service.dispose();
    conn.dispose();
    await channel.messages.close();
    await channel.controls.close();
    await channel.replies.close();
  });
  test(
    'private registrations keep v1, opting in uses v2, opting out returns v1',
    () async {
      await setup();
      await service.update(service.preferences.copyWith(enabled: true));
      await until(
        () => channel.sent.where((s) => s.$3 is NotifyRegister).length >= 2,
      );
      for (final s in channel.sent.where((s) => s.$3 is NotifyRegister)) {
        expect(s.$3.toJson().containsKey('show_question_preview'), false);
      }
      channel.sent.clear();
      await service.update(
        service.preferences.copyWith(
          showPaneName: true,
          showQuestionPreview: true,
        ),
      );
      await until(() => channel.sent.length >= 2);
      for (final s in channel.sent) {
        expect(s.$3.toJson()['show_question_preview'], true);
      }
      channel.sent.clear();
      await service.update(
        service.preferences.copyWith(showQuestionPreview: false),
      );
      await until(() => channel.sent.length >= 2);
      for (final s in channel.sent) {
        expect(s.$3.toJson().containsKey('show_question_preview'), false);
      }
    },
  );
  test(
    'unsupported pane falls through to another live room without changing chat',
    () async {
      await setup(retry: const Duration(milliseconds: 20));
      channel.rejectedRoom = 'live-a';
      channel.controls.add(
        RoomsSnapshot(
          peer: a.remoteEpk,
          rooms: [
            const RoomInfo(roomId: 'live-a', startedAt: 1),
            const RoomInfo(roomId: 'live-z', startedAt: 1),
          ],
        ),
      );
      await until(() => conn.roomsFor(a.remoteEpk).length == 2);
      await service.update(service.preferences.copyWith(enabled: true));
      await until(
        () => channel.sent.any(
          (s) =>
              s.$1 == a.remoteEpk && s.$2 == 'live-z' && s.$3 is NotifyRegister,
        ),
      );
      expect(conn.activeRoomId, 'closed-selected');
    },
  );

  test(
    'prefs token rotation and disable reach every live paired Mac without changing active chat',
    () async {
      await setup();
      await service.update(service.preferences.copyWith(enabled: true));
      await until(
        () => channel.sent.where((s) => s.$3 is NotifyRegister).length >= 2,
      );
      final first = channel.sent.where((s) => s.$3 is NotifyRegister).toList();
      expect(first.map((s) => s.$1).toSet(), {a.remoteEpk, b.remoteEpk});
      expect(first.first.$2, 'live-a');
      expect(conn.activePeer?.remoteEpk, a.remoteEpk);
      expect(conn.activeRoomId, 'closed-selected');
      expect(identical(conn.channel, channel), true);
      expect(
        service.peerSyncStates[c.remoteEpk],
        contains('pending, no live pane'),
      );
      final before = channel.sent.length;
      await service.update(
        service.preferences.copyWith(categories: {'input_needed'}),
      );
      await until(() => channel.sent.length >= before + 2);
      for (final s in channel.sent.skip(before)) {
        expect((s.$3 as NotifyRegister).categories, ['input_needed']);
      }
      platform.token = 'bb' * 32;
      await service.refresh();
      expect((channel.sent.last.$3 as NotifyRegister).token, platform.token);
      final offBefore = channel.sent.length;
      await service.update(service.preferences.copyWith(enabled: false));
      await until(() => channel.sent.length >= offBefore + 2);
      expect(
        channel.sent.skip(offBefore).every((s) => s.$3 is NotifyUnregister),
        true,
      );
      channel.live(c, 'now-live-c');
      await until(() => channel.sent.any((s) => s.$1 == c.remoteEpk));
      expect(channel.sent.last.$3, isA<NotifyUnregister>());
      expect(service.status, contains('Off on all 3'));
      expect(conn.activeRoomId, 'closed-selected');
    },
  );
  test(
    'ACK must match Mac room and id; forged sibling reply never confirms settings',
    () async {
      await setup();
      channel.autoAck = false;
      final updating = service.update(
        service.preferences.copyWith(enabled: true),
      );
      await until(() => channel.sent.last.$3 is NotifyRegister);
      final pending = channel.sent.last;
      channel.ack(b.remoteEpk, pending.$2, pending.$3);
      channel.ack(pending.$1, 'wrong-room', pending.$3);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.peerSyncStates[a.remoteEpk], contains('saving'));
      channel.autoAck = true;
      channel.ack(pending.$1, pending.$2, pending.$3);
      await updating;
      expect(service.peerSyncStates[a.remoteEpk], contains('ready'));
    },
  );
  test('29-day bounded grants renew while app remains open', () async {
    await setup(renewal: const Duration(milliseconds: 100));
    await service.update(service.preferences.copyWith(enabled: true));
    await until(() => channel.sent.any((s) => s.$3 is NotifyRegister));
    final first =
        channel.sent.firstWhere((s) => s.$3 is NotifyRegister).$3
            as NotifyRegister;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(first.expiresAt, greaterThanOrEqualTo(now + 29 * 86400 - 2));
    expect(first.expiresAt, lessThanOrEqualTo(now + 30 * 86400));
    await until(
      () =>
          channel.sent
              .where((s) => s.$1 == a.remoteEpk && s.$3 is NotifyRegister)
              .length >=
          2,
    );
    final latest =
        channel.sent
                .lastWhere((s) => s.$1 == a.remoteEpk && s.$3 is NotifyRegister)
                .$3
            as NotifyRegister;
    expect(latest.expiresAt, greaterThan(first.expiresAt));
  });
  test('revoked Mac is removed from fanout before subsequent update', () async {
    await setup();
    storage.peers = [a];
    final before = channel.sent.length;
    await service.update(service.preferences.copyWith(enabled: true));
    await until(() => channel.sent.length > before);
    expect(channel.sent.skip(before).map((s) => s.$1).toSet(), {a.remoteEpk});
    expect(service.peerSyncStates.containsKey(b.remoteEpk), false);
  });
}
