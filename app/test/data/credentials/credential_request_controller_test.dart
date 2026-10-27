import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/credentials/credential_crypto.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/data/credentials/credential_request_controller.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/ws_transport.dart' show requiresSourceRoom;
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeChannel implements IChannel {
  final List<ClientMessage> sent = [];
  bool fail = false;
  Completer<void>? gate;
  // Stays open: a completed stream reads as a disconnect to ConnectionManager.
  final _ctrl = StreamController<ServerMessage>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {
    if (gate != null) await gate!.future;
    if (fail) throw StateError('offline');
    sent.add(msg);
  }

  @override
  Future<void> close() => _ctrl.close();
}

void main() {
  final vectors =
      jsonDecode(File('test/data/credentials/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  const requestId = '01999999-aaaa-7bbb-8ccc-dddddddddddd';
  Map<String, dynamic> requestJson({Map<String, dynamic> over = const {}}) => {
    'type': 'credential_request',
    ...vectors['request'] as Map<String, dynamic>,
    'sig': vectors['request_sig'],
    ...over,
  };
  final macKey =
      (vectors['request'] as Map<String, dynamic>)['mac_key'] as String;
  final now = DateTime.fromMillisecondsSinceEpoch(1790000000000 - 60000);

  late StreamController<ServerMessage> frames;
  late StreamController<void> resumed;
  late FakeChannel channel;
  late IChannel? Function() channelOf;
  late String mac;
  late String room;
  late CredentialRequestController c;
  late SimpleKeyPair owner;
  Completer<void>? verifyGate;
  Completer<void>? ownerGate;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  CredentialRequestController make({
    Duration ack = const Duration(seconds: 25),
  }) => CredentialRequestController(
    frames: frames.stream,
    channel: () => channelOf(),
    ownerKey: () async {
      if (ownerGate != null) await ownerGate!.future;
      return owner;
    },
    expectedMacKey: () => mac,
    expectedRoom: () => room,
    resumeSignal: resumed.stream,
    now: () => now,
    ackTimeout: ack,
    verify: (key, r) async {
      if (verifyGate != null) await verifyGate!.future;
      return verifyCredentialRequest(key, r);
    },
  );

  setUp(() async {
    frames = StreamController<ServerMessage>.broadcast();
    resumed = StreamController<void>.broadcast();
    channel = FakeChannel();
    channelOf = () => channel;
    mac = macKey;
    room = 'room-abc';
    owner = await Ed25519().newKeyPairFromSeed(
      base64Decode(vectors['phone_seed'] as String),
    );
    c = make();
  });
  tearDown(() => c.dispose());

  test(
    'shows only a request signed by the paired Mac for the active room',
    () async {
      frames.add(ServerMessage.fromJson(requestJson(over: {'room': 'other'})));
      frames.add(
        ServerMessage.fromJson(requestJson(over: {'label': 'tampered'})),
      );
      frames.add(
        ServerMessage.fromJson(
          requestJson(over: {'expires_at': now.millisecondsSinceEpoch - 1}),
        ),
      );
      frames.add(
        ServerMessage.fromJson(
          requestJson(over: {'mac_key': vectors['response']['phone_key']}),
        ),
      );
      await settle();
      expect(c.pending, isNull);
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      expect(c.pending?.id, requestId);
    },
  );

  test(
    'submit encrypts, zeroes the buffer, never puts plaintext on the wire, and sends over the captured channel',
    () async {
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      final secret = Uint8List.fromList(
        utf8.encode('synthetic-secret-value\nline two'),
      );
      await c.submit(secret);
      expect(secret.every((b) => b == 0), isTrue);
      expect(c.submitting, isTrue);
      expect(channel.sent, hasLength(1));
      final wire = jsonEncode(channel.sent.single.toJson());
      expect(wire, contains('"type":"credential_response"'));
      expect(wire, isNot(contains('synthetic-secret')));
      frames.add(
        const CredentialResult(
          inReplyTo: 'x',
          id: requestId,
          ok: false,
          error: 'bad_signature',
        ),
      );
      await settle();
      expect(c.submitting, isFalse);
      expect(c.error, contains('did not accept'));
      expect(c.pending, isNotNull);
      frames.add(
        const CredentialResult(inReplyTo: 'x', id: requestId, ok: true),
      );
      frames.add(const CredentialClosed(id: requestId, reason: 'fulfilled'));
      await settle();
      expect(c.pending, isNull);
      expect(c.error, isNull);
    },
  );

  test(
    'a closed or cleared request is not resurrected by an in-flight verification',
    () async {
      // close during verify
      frames.add(ServerMessage.fromJson(requestJson()));
      frames.add(const CredentialClosed(id: requestId, reason: 'cancelled'));
      await settle();
      expect(c.pending, isNull);
      // navigate away during verify
      verifyGate = Completer<void>();
      frames.add(ServerMessage.fromJson(requestJson()));
      await Future<void>.delayed(Duration.zero); // verification now in flight
      c.clear();
      verifyGate!.complete();
      await settle();
      expect(c.pending, isNull);
      // source changed during verify (user switched chat; Mac key differs)
      verifyGate = Completer<void>();
      frames.add(ServerMessage.fromJson(requestJson()));
      await Future<void>.delayed(Duration.zero);
      mac = 'other';
      verifyGate!.complete();
      await settle();
      expect(c.pending, isNull);
      mac = macKey;
      // channel replaced during verify (reconnect)
      verifyGate = Completer<void>();
      frames.add(ServerMessage.fromJson(requestJson()));
      await Future<void>.delayed(Duration.zero);
      channel = FakeChannel();
      verifyGate!.complete();
      await settle();
      expect(c.pending, isNull);
      verifyGate = null;
      // and a clean one still shows
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      expect(c.pending, isNotNull);
    },
  );

  test(
    'submit is bound to the channel/source captured before encryption',
    () async {
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      final old = channel;
      final future = c.submit(Uint8List.fromList([1, 2, 3]));
      channel = FakeChannel(); // reconnect while encrypting
      await future;
      expect(old.sent, isEmpty);
      expect(channel.sent, isEmpty);
      expect(c.submitting, isFalse);
      expect(c.error, contains('connection changed'));
      // away/back during encryption: cleared, nothing sent
      final f2 = c.submit(Uint8List.fromList([1, 2, 3]));
      c.clear();
      await f2;
      expect(channel.sent, isEmpty);
      expect(c.pending, isNull);
    },
  );

  test(
    'cold open: query recovers a pending request; already completed: authoritative none clears stale UI',
    () async {
      await c.query();
      expect(channel.sent.single, isA<CredentialQuery>());
      final qid = (channel.sent.single as CredentialQuery).id;
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      expect(c.pending, isNotNull);
      // Lost fulfilled/ACK: on resume the query answer is "none" for OUR id.
      channel.sent.clear();
      resumed.add(null);
      await settle();
      final qid2 = (channel.sent.single as CredentialQuery).id;
      expect(qid2, isNot(qid));
      frames.add(
        CredentialClosed(id: '', reason: 'none', inReplyTo: 'stale-query'),
      );
      await settle();
      expect(
        c.pending,
        isNotNull,
        reason: 'a none for another query is ignored',
      );
      frames.add(CredentialClosed(id: '', reason: 'none', inReplyTo: qid2));
      await settle();
      expect(c.pending, isNull);
    },
  );

  test(
    'lost ACK: bounded unconfirmed state, then cancel escapes without resending',
    () async {
      c.dispose();
      c = make(ack: const Duration(milliseconds: 60));
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      await c.submit(Uint8List.fromList([9, 9, 9]));
      expect(c.submitting, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.submitting, isFalse);
      expect(c.error, contains('No confirmation'));
      expect(channel.sent.whereType<CredentialResponse>(), hasLength(1));
      await c.cancel();
      expect(c.pending, isNull);
      expect(channel.sent.last, isA<CredentialCancel>());
      expect(channel.sent.whereType<CredentialResponse>(), hasLength(1));
    },
  );

  test('cancel is allowed while a submit is unconfirmed', () async {
    frames.add(ServerMessage.fromJson(requestJson()));
    await settle();
    await c.submit(Uint8List.fromList([1]));
    expect(c.submitting, isTrue);
    await c.cancel();
    expect(c.pending, isNull);
    expect(c.submitting, isFalse);
    expect(channel.sent.last, isA<CredentialCancel>());
  });

  test(
    'empty and oversized values are refused locally; offline send surfaces a retryable error',
    () async {
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      await c.submit(Uint8List(0));
      expect(c.error, 'Nothing to send.');
      await c.submit(Uint8List(16 * 1024 + 1));
      expect(c.error, contains('Too large'));
      expect(channel.sent, isEmpty);
      channel.fail = true;
      await c.submit(Uint8List.fromList([1, 2, 3]));
      expect(c.error, contains('Not connected'));
      expect(c.submitting, isFalse);
    },
  );

  test(
    'credential control frames require a source room at the transport boundary',
    () {
      expect(requiresSourceRoom('credential_request'), isTrue);
      expect(requiresSourceRoom('credential_closed'), isTrue);
      expect(requiresSourceRoom('credential_result'), isTrue);
      expect(requiresSourceRoom('artifact_chunk'), isTrue);
      expect(requiresSourceRoom('agent_chunk'), isFalse);
    },
  );

  test(
    'an exact replay of the open request during submit is a no-op; close or a new request releases submitting',
    () async {
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      // Replay (session_sync / query answer) lands while ownerKey is awaited.
      ownerGate = Completer<void>();
      final f1 = c.submit(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      expect(c.pending?.id, requestId);
      ownerGate!.complete();
      await f1;
      expect(
        c.submitting,
        isTrue,
        reason: 'submit proceeded and is awaiting ACK',
      );
      expect(channel.sent.whereType<CredentialResponse>(), hasLength(1));
      // Closed while encrypting → nothing sent, submitting released.
      frames.add(const CredentialClosed(id: requestId, reason: 'cancelled'));
      await settle();
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      channel.sent.clear();
      ownerGate = Completer<void>();
      final f2 = c.submit(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      frames.add(const CredentialClosed(id: requestId, reason: 'cancelled'));
      await settle();
      ownerGate!.complete();
      await f2;
      expect(c.pending, isNull);
      expect(c.submitting, isFalse);
      expect(channel.sent, isEmpty);
      // A different request replaces the open one mid-submit → old submit dropped.
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      ownerGate = Completer<void>();
      final f3 = c.submit(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      final macSeed = base64Decode(vectors['mac_seed'] as String);
      final other = await _signedRequest(
        macSeed,
        requestJson(over: {'id': 'req-other'}),
      );
      frames.add(ServerMessage.fromJson(other));
      await settle();
      ownerGate!.complete();
      await f3;
      expect(c.pending?.id, 'req-other');
      expect(c.submitting, isFalse);
      expect(channel.sent, isEmpty);
      ownerGate = null;
    },
  );

  group('actual ConnectionManager routing', () {
    late ConnectionManager conn;
    late FakeChannel live;
    late CredentialRequestController rc;
    const peer = PeerRecord(
      remoteEpk: 'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=',
      sessionName: 'mac',
      relayUrl: 'wss://relay.test',
      pairedAt: '2026-01-01T00:00:00Z',
      roomId: 'room-abc',
    );
    setUp(() async {
      conn = ConnectionManager(
        factory: (_, _) async => FakeChannel(),
        storage: _NoStorage(),
        emitDebounce: Duration.zero,
      );
      live = FakeChannel();
      conn.adopt(live, peer);
      conn.switchRoom('room-abc');
      rc = CredentialRequestController(
        frames: frames.stream,
        channel: () => conn.channel,
        ownerKey: () async {
          if (ownerGate != null) await ownerGate!.future;
          return owner;
        },
        expectedMacKey: () => macKey,
        expectedRoom: () => 'room-abc',
        routedPeer: () => conn.activePeer?.remoteEpk ?? '',
        routedRoom: () => conn.activeRoomId,
        invalidateOn: [conn.statusStream, conn.roomsStream],
        now: () => now,
      );
    });
    tearDown(() async {
      rc.dispose();
      conn.dispose();
    });

    test(
      'a routed room switch on the SAME channel drops the pending request',
      () async {
        frames.add(ServerMessage.fromJson(requestJson()));
        await settle();
        expect(rc.pending, isNotNull);
        expect(identical(conn.channel, live), isTrue);
        conn.switchRoom('room-other'); // PlainPeerChannel reused, routing moved
        await settle();
        expect(identical(conn.channel, live), isTrue);
        expect(rc.pending, isNull);
        // Routing points elsewhere: a request for our chat is not shown either.
        frames.add(ServerMessage.fromJson(requestJson()));
        await settle();
        expect(rc.pending, isNull);
        conn.switchRoom('room-abc'); // back
        frames.add(ServerMessage.fromJson(requestJson()));
        await settle();
        expect(rc.pending, isNotNull);
      },
    );

    test(
      'a routing move during encryption prevents the send over the new route',
      () async {
        frames.add(ServerMessage.fromJson(requestJson()));
        await settle();
        ownerGate = Completer<void>();
        final f = rc.submit(Uint8List.fromList([1, 2, 3]));
        await Future<void>.delayed(Duration.zero);
        conn.switchRoom('room-other');
        await settle();
        ownerGate!.complete();
        await f;
        expect(live.sent.whereType<CredentialResponse>(), isEmpty);
        expect(rc.submitting, isFalse);
        expect(rc.pending, isNull);
        ownerGate = null;
      },
    );

    test('disconnect clears the pending request', () async {
      frames.add(ServerMessage.fromJson(requestJson()));
      await settle();
      expect(rc.pending, isNotNull);
      await conn.disconnect();
      await settle();
      expect(rc.pending, isNull);
    });
  });
}

class _NoStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
  @override
  Future<PeerRecord?> loadPeer(String epk) async => null;
}

Future<Map<String, dynamic>> _signedRequest(
  List<int> macSeed,
  Map<String, dynamic> json,
) async {
  final r = CredentialRequest.fromJson({...json, 'sig': ''});
  final key = await Ed25519().newKeyPairFromSeed(macSeed);
  final sig = await Ed25519().sign(canonicalRequestBytes(r), keyPair: key);
  return {...json, 'sig': base64Encode(sig.bytes)};
}
