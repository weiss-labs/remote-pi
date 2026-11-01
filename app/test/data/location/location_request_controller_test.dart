import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/credentials/credential_crypto.dart'
    show deriveCredentialKey;
import 'package:app/data/location/location_crypto.dart';
import 'package:app/data/location/location_request_controller.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/ws_transport.dart' show requiresSourceRoom;
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeChannel implements IChannel {
  final List<ClientMessage> sent = [];
  final _ctrl = StreamController<ServerMessage>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  Future<void> close() => _ctrl.close();
}

void main() {
  final vectors =
      jsonDecode(File('test/data/location/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final reqJson = vectors['request'] as Map<String, dynamic>;
  final now = DateTime.fromMillisecondsSinceEpoch(1790000000000 - 10000);
  LocationRequest request({Map<String, dynamic> over = const {}}) =>
      LocationRequest.fromJson({
        ...reqJson,
        'sig': vectors['request_sig'],
        ...over,
      });

  late StreamController<LocationRequest> frames;
  late FakeChannel channel;
  late IChannel? channelNow;
  late String mac, room, routedRoom;
  late bool enabled, foreground;
  late String permission;
  late Map<String, Object?> fix;
  late int fixCalls;
  Completer<void>? fixGate;
  Completer<void>? ownerGate;
  late LocationRequestController c;
  late List<void> shared;
  late SimpleKeyPair owner;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  /// Decrypts a reply the way the Mac does (its ephemeral is the vector seed).
  Future<Map<String, dynamic>> open(LocationResponse r) async {
    final macE = await X25519().newKeyPairFromSeed(
      base64Decode(vectors['mac_x25519_seed'] as String),
    );
    final key = await deriveCredentialKey(
      phoneEphemeral: macE,
      macEpk: base64Decode(r.phoneEpk),
      macEpkB64: reqJson['mac_epk'] as String,
      phoneEpkB64: r.phoneEpk,
      requestId: r.requestId,
      salt: locationHkdfSalt,
      infoPrefix: locationHkdfInfoPrefix,
    );
    final ct = base64Decode(r.ciphertext);
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        ct.sublist(0, ct.length - 16),
        nonce: base64Decode(r.nonce),
        mac: Mac(ct.sublist(ct.length - 16)),
      ),
      secretKey: key,
      aad: canonicalLocationRequestBytes(request()),
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  /// A second request properly signed by the vector Mac key.
  Future<LocationRequest> signed(String id) async {
    final unsigned = request(over: {'id': id, 'sig': ''});
    final macKp = await Ed25519().newKeyPairFromSeed(
      base64Decode(vectors['mac_seed'] as String),
    );
    final sig = await Ed25519().sign(
      canonicalLocationRequestBytes(unsigned),
      keyPair: macKp,
    );
    return request(over: {'id': id, 'sig': base64Encode(sig.bytes)});
  }

  LocationRequestController make() => LocationRequestController(
    frames: frames.stream,
    channel: () => channelNow,
    ownerKey: () async {
      if (ownerGate != null) await ownerGate!.future;
      return owner;
    },
    expectedMacKey: () => mac,
    expectedRoom: () => room,
    routedRoom: () => routedRoom,
    enabled: () => enabled,
    foreground: () => foreground,
    permission: () async => permission,
    fix: () async {
      fixCalls++;
      if (fixGate != null) await fixGate!.future;
      return fix;
    },
    now: () => now,
  );

  setUp(() async {
    LocationRequestController.resetHandled();
    frames = StreamController<LocationRequest>.broadcast();
    channel = FakeChannel();
    channelNow = channel;
    mac = reqJson['mac_key'] as String;
    room = 'room-abc';
    routedRoom = room;
    enabled = true;
    foreground = true;
    permission = 'authorized';
    fix = {
      'lat': 40.6205,
      'lng': -73.9811,
      'accuracy_m': 12.0,
      'captured_at': now.millisecondsSinceEpoch - 2000,
    };
    fixCalls = 0;
    fixGate = null;
    ownerGate = null;
    shared = [];
    owner = await Ed25519().newKeyPairFromSeed(
      base64Decode(vectors['phone_seed'] as String),
    );
    c = make();
    c.shared.listen(shared.add);
  });
  tearDown(() => c.dispose());

  test('location frames require a source room like credentials', () {
    expect(requiresSourceRoom('location_request'), isTrue);
    expect(requiresSourceRoom('location_result'), isTrue);
  });

  test(
    'answers a verified request with one encrypted fix and says so',
    () async {
      frames.add(request());
      await settle();
      expect(channel.sent, hasLength(1));
      final r = channel.sent.single as LocationResponse;
      expect(r.requestId, reqJson['id']);
      expect(jsonEncode(r.toJson()), isNot(contains('40.62')));
      expect(await open(r), {
        'lat': 40.6205,
        'lng': -73.9811,
        'accuracy_m': 12.0,
        'captured_at': now.millisecondsSinceEpoch - 2000,
      });
      expect(shared, hasLength(1));
      // A replay of the same request (session_sync) is not answered twice.
      frames.add(request());
      await settle();
      expect(channel.sent, hasLength(1));
      expect(fixCalls, 1);
    },
  );

  for (final (name, setup, code) in [
    ('setting off', () => enabled = false, 'off'),
    ('app in background', () => foreground = false, 'background'),
    ('permission denied', () => permission = 'denied', 'denied'),
    ('permission never asked', () => permission = 'notDetermined', 'denied'),
    ('no fix', () => fix = {'error': 'unavailable'}, 'unavailable'),
    ('odd native error', () => fix = {'error': 'weird'}, 'unavailable'),
    ('malformed fix', () => fix = {'lat': 'x'}, 'unavailable'),
  ]) {
    test('$name → encrypted "$code" error, no fix, no notice', () async {
      setup();
      frames.add(request());
      await settle();
      final r = channel.sent.single as LocationResponse;
      expect(await open(r), {'error': code});
      expect(shared, isEmpty);
      if (code == 'off' || code == 'background' || code == 'denied') {
        expect(fixCalls, 0);
      }
    });
  }

  test(
    'a replayed request is never answered twice, even after another request or a new controller',
    () async {
      frames.add(request());
      await settle();
      final b = await signed('01999999-aaaa-7bbb-8ccc-eeeeeeeeeeee');
      frames.add(b);
      await settle();
      expect(channel.sent, hasLength(2));
      frames.add(request()); // replay A after B
      await settle();
      expect(channel.sent, hasLength(2));
      c.dispose();
      c = make(); // chat reopened
      frames.add(request());
      frames.add(b);
      await settle();
      expect(channel.sent, hasLength(2));
      expect(fixCalls, 2);
    },
  );

  for (final (name, change, code) in [
    ('sharing turned off', () => enabled = false, 'off'),
    ('app backgrounded', () => foreground = false, 'background'),
    ('permission revoked', () => permission = 'denied', 'denied'),
  ]) {
    test(
      '$name while the fix is pending → "$code", coordinates never sent',
      () async {
        fixGate = Completer<void>();
        frames.add(request());
        await settle();
        change();
        fixGate!.complete();
        await settle();
        expect(await open(channel.sent.single as LocationResponse), {
          'error': code,
        });
        expect(shared, isEmpty);
      },
    );
  }

  for (final (name, change, code) in [
    ('sharing turned off', () => enabled = false, 'off'),
    ('app backgrounded', () => foreground = false, 'background'),
  ]) {
    test('$name during encryption → "$code" instead of the fix', () async {
      ownerGate = Completer<void>();
      frames.add(request());
      await settle();
      change();
      ownerGate!.complete();
      await settle();
      expect(await open(channel.sent.single as LocationResponse), {
        'error': code,
      });
      expect(shared, isEmpty);
    });
  }

  test(
    'never answers a request not signed by the paired Mac for this room',
    () async {
      frames.add(request(over: {'room': 'other'}));
      frames.add(request(over: {'purpose': 'tampered'}));
      frames.add(request(over: {'expires_at': now.millisecondsSinceEpoch - 1}));
      frames.add(request(over: {'mac_key': vectors['response']['phone_key']}));
      await settle();
      expect(channel.sent, isEmpty);
      routedRoom = 'other-room';
      frames.add(request());
      await settle();
      expect(channel.sent, isEmpty);
      expect(fixCalls, 0);
    },
  );

  test(
    'drops the answer when routing moves while the fix is in flight',
    () async {
      fixGate = Completer<void>();
      frames.add(request());
      await settle();
      expect(fixCalls, 1);
      channelNow = FakeChannel(); // reconnect replaced the channel
      fixGate!.complete();
      await settle();
      expect(channel.sent, isEmpty);
      expect((channelNow as FakeChannel).sent, isEmpty);
      expect(shared, isEmpty);
    },
  );

  test('nothing is sent after dispose', () async {
    fixGate = Completer<void>();
    frames.add(request());
    await settle();
    c.dispose();
    fixGate!.complete();
    await settle();
    expect(channel.sent, isEmpty);
  });
}
