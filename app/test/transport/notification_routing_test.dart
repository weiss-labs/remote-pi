import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'notification fanout reuses authenticated socket and preserves chat route and source',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      final auth = Completer<void>();
      final frames = <Map<String, dynamic>>[];
      var connections = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        connections++;
        socketReady.complete(socket);
        socket.listen((data) {
          final frame = jsonDecode(data as String) as Map<String, dynamic>;
          if (frame['type'] == 'hello') {
            socket.add(
              jsonEncode({
                'type': 'challenge',
                'nonce': base64Encode(List.filled(32, 7)),
              }),
            );
          } else if (frame['type'] == 'auth') {
            auth.complete();
          } else {
            frames.add(frame);
          }
        });
      });
      final transport = await WsTransport.connect(
        relayUrl: 'http://127.0.0.1:${server.port}',
        peerPubkey: 'YQ==',
        ed25519Key: await Ed25519().newKeyPairFromSeed(List.filled(32, 1)),
      );
      await auth.future;
      final socket = await socketReady.future;
      transport.setActiveRoom('chat-a');
      await transport.send(
        Uint8List.fromList(utf8.encode('{"type":"ping","id":"before"}')),
      );
      await transport.sendNotificationTo(
        NotifyUnregister(id: 'notification', deviceId: 'device'),
        peer: 'Yg==',
        room: 'live-b',
      );
      await transport.send(
        Uint8List.fromList(utf8.encode('{"type":"ping","id":"after"}')),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (frames.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(connections, 1);
      expect(frames.map((f) => f['peer']), ['YQ==', 'Yg==', 'YQ==']);
      expect(frames.map((f) => f['room']), ['chat-a', 'live-b', 'chat-a']);
      await expectLater(
        transport.sendNotificationTo(
          Ping(id: 'not-allowed'),
          peer: 'Yg==',
          room: 'live-b',
        ),
        throwsA(isA<WsTransportError>()),
      );
      final reply = transport.notificationReplies.first;
      socket.add(
        jsonEncode({
          'peer': 'Yg==',
          'room': 'live-b',
          'ct': base64Encode(
            utf8.encode(
              jsonEncode({
                'type': 'notification_registration',
                'in_reply_to': 'notification',
                'ok': true,
              }),
            ),
          ),
        }),
      );
      final envelope = await reply.timeout(const Duration(seconds: 3));
      expect(envelope.peer, 'Yg==');
      expect(envelope.room, 'live-b');
      // A second Mac may have the SAME deterministic room ID. Its ACK stays
      // routed with provenance, but its ordinary history/chunks cannot enter chat.
      final sameRoomAck = transport.notificationReplies.first;
      socket.add(
        jsonEncode({
          'peer': 'Yg==',
          'room': 'chat-a',
          'ct': base64Encode(
            utf8.encode(
              jsonEncode({
                'type': 'notification_registration',
                'in_reply_to': 'other-mac-same-room',
                'ok': true,
              }),
            ),
          ),
        }),
      );
      final sameRoomEnvelope = await sameRoomAck.timeout(
        const Duration(seconds: 3),
      );
      expect(sameRoomEnvelope.peer, 'Yg==');
      expect(sameRoomEnvelope.room, 'chat-a');
      // Registration ACK never enters normal chat receive. Neither do foreign
      // ordinary frames, even with the same room or a legacy omitted room.
      final chat = transport.receive();
      socket.add(
        jsonEncode({
          'peer': 'Yg==',
          'room': 'chat-a',
          'ct': base64Encode(
            utf8.encode(
              '{"type":"agent_chunk","in_reply_to":"foreign","delta":"wrong Mac"}',
            ),
          ),
        }),
      );
      socket.add(
        jsonEncode({
          'peer': 'Yg==',
          'ct': base64Encode(
            utf8.encode('{"type":"session_history","messages":[]}'),
          ),
        }),
      );
      socket.add(
        jsonEncode({
          'peer': 'YQ==',
          'room': 'chat-a',
          'ct': base64Encode(
            utf8.encode('{"type":"pong","in_reply_to":"after"}'),
          ),
        }),
      );
      expect(
        utf8.decode(await chat.timeout(const Duration(seconds: 3))),
        contains('pong'),
      );
      await transport.close();
      await socket.close();
      await server.close(force: true);
    },
  );
}
