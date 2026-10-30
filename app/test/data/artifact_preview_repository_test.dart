import 'dart:convert';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/repositories/artifact_preview_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/artifact_preview.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'pane_commands_repository_test.dart' show Channel, Storage, peer, flush;

// Production channels implement notification fanout, but it is notify-only.
// Artifact lifecycle messages must stay on the captured active channel.
class ProductionLikeChannel extends Channel implements INotificationRoutes {
  @override
  Stream<RoutedNotificationReply> get notificationReplies =>
      const Stream.empty();
  @override
  Future<void> sendNotificationTo(
    ClientMessage message, {
    required String peer,
    required String room,
  }) async {
    if (message is! NotifyRegister && message is! NotifyUnregister) {
      throw Exception('Only notification registration may use fanout');
    }
    await send(message);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('test-artifact-preview');
  late Channel channel;
  late ConnectionManager connection;
  late ArtifactPreviewRepository repository;
  late List<MethodCall> nativeCalls;
  final bytes = utf8.encode('%PDF-1.4\nsynthetic test only');
  late String hash;
  setUp(() async {
    hash = (await Sha256().hash(
      bytes,
    )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    channel = ProductionLikeChannel();
    connection = ConnectionManager(
      factory: (_, _) async => channel,
      storage: Storage(),
    );
    await connection.connectTo(peer);
    repository = ArtifactPreviewRepository(
      connection,
      native: native,
      timeout: const Duration(milliseconds: 100),
    );
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          nativeCalls.add(call);
          return null;
        });
  });
  tearDown(() async {
    repository.dispose();
    await flush();
    connection.dispose();
    await channel.incoming.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });
  ArtifactRequest lastRequest() =>
      channel.sent.whereType<ArtifactRequest>().last;
  void opened({Map<String, Object?> changes = const {}}) =>
      channel.incoming.add(
        ArtifactReply({
          'type': 'artifact_opened',
          'in_reply_to': lastRequest().id,
          'transfer_id': 'handle',
          'size': bytes.length,
          'mime': 'application/pdf',
          'sha256': hash,
          ...changes,
        }),
      );
  void chunk({Map<String, Object?> changes = const {}}) => channel.incoming.add(
    ArtifactReply({
      'type': 'artifact_chunk',
      'in_reply_to': lastRequest().id,
      'transfer_id': 'handle',
      'offset': 0,
      'data': base64Encode(bytes),
      'eof': true,
      ...changes,
    }),
  );
  Future<void> open() =>
      repository.open('file:///tmp/synthetic.pdf', progress: (_) {});

  test(
    'correlated bounded PDF transfer verifies hash before native bytes, closes handle',
    () async {
      final future = open();
      expect(lastRequest().toJson()['url'], 'file:///tmp/synthetic.pdf');
      opened(changes: {'in_reply_to': 'foreign-request'});
      await flush();
      expect(channel.sent.whereType<ArtifactRequest>().length, 1);
      opened();
      await flush();
      expect(lastRequest().offset, 0);
      chunk();
      await future;
      final call = nativeCalls.singleWhere((c) => c.method == 'preview');
      expect((call.arguments as Map)['bytes'], bytes);
      expect(
        (call.arguments as Map).keys,
        unorderedEquals(['bytes', 'extension']),
      );
      expect(lastRequest().type, 'artifact_close');
    },
  );
  for (final changes in <Map<String, Object?>>[
    {'size': 20 * 1024 * 1024 + 1},
    {'size': -1},
    {'mime': 'text/html'},
    {'sha256': 'invalid'},
  ]) {
    test(
      'rejects unsafe metadata $changes before allocating or previewing',
      () async {
        final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
        opened(changes: changes);
        await failed;
        expect(nativeCalls.where((c) => c.method == 'preview'), isEmpty);
      },
    );
  }
  for (final changes in <Map<String, Object?>>[
    {'offset': 1},
    {'transfer_id': 'foreign'},
    {'data': 'not-base64'},
    {'eof': false},
    {'data': base64Encode(List.filled(192 * 1024 + 1, 1))},
    {'data': base64Encode(utf8.encode('XPDF-1.4\nsynthetic test only'))},
  ]) {
    test(
      'rejects malformed, foreign, oversized or corrupt chunk ${changes.keys}',
      () async {
        final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
        opened();
        await flush();
        chunk(changes: changes);
        await failed;
        expect(nativeCalls.where((c) => c.method == 'preview'), isEmpty);
        expect(lastRequest().type, 'artifact_close');
      },
    );
  }
  test('tool-result image URLs reach the Mac; web URLs never do', () async {
    final future = repository.open(
      'pi-tool-image:call%7C1/1',
      progress: (_) {},
    );
    expect(lastRequest().toJson()['url'], 'pi-tool-image:call%7C1/1');
    opened();
    await flush();
    chunk();
    await future;
    expect(nativeCalls.where((c) => c.method == 'preview'), hasLength(1));
    final sent = channel.sent.whereType<ArtifactRequest>().length;
    await expectLater(
      repository.open('https://example.com/x.png', progress: (_) {}),
      throwsA(isA<ArtifactFailure>()),
    );
    expect(channel.sent.whereType<ArtifactRequest>().length, sent);
  });
  test('two sequential chunks preserve offsets and full-file hash', () async {
    final large = List<int>.generate(192 * 1024 + 9, (i) => i % 251);
    final digest = (await Sha256().hash(
      large,
    )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final future = open();
    opened(changes: {'size': large.length, 'sha256': digest});
    await flush();
    chunk(
      changes: {
        'data': base64Encode(large.sublist(0, 192 * 1024)),
        'eof': false,
      },
    );
    await flush();
    expect(lastRequest().offset, 192 * 1024);
    chunk(
      changes: {
        'offset': 192 * 1024,
        'data': base64Encode(large.sublist(192 * 1024)),
      },
    );
    await future;
    expect(
      (nativeCalls.singleWhere((c) => c.method == 'preview').arguments
          as Map)['bytes'],
      large,
    );
  });

  test(
    'switch away and back cancels original operation; late bytes cannot open',
    () async {
      final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
      opened();
      await flush();
      final id = lastRequest().id;
      connection.switchRoom('other');
      await flush();
      connection.switchRoom('room-a');
      chunk(changes: {'in_reply_to': id});
      await failed;
      expect(nativeCalls.where((c) => c.method == 'preview'), isEmpty);
    },
  );
  test(
    'explicit cancellation closes transfer and ignores late reply',
    () async {
      final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
      opened();
      await flush();
      await repository.cancel();
      await failed;
      expect(lastRequest().type, 'artifact_close');
      expect(nativeCalls.where((c) => c.method == 'preview'), isEmpty);
    },
  );
  test(
    'backend rejection and timeouts are honest failures, never browser fallback',
    () async {
      final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
      channel.incoming.add(
        ArtifactReply({
          'type': 'artifact_error',
          'in_reply_to': lastRequest().id,
          'code': 'not_linked',
        }),
      );
      await failed;
      await expectLater(open(), throwsA(isA<ArtifactFailure>()));
      expect(nativeCalls.where((c) => c.method == 'preview'), isEmpty);
    },
  );
  test(
    'second concurrent open rejected without extra network request',
    () async {
      final failed = expectLater(open(), throwsA(isA<ArtifactFailure>()));
      await expectLater(open(), throwsA(isA<ArtifactFailure>()));
      expect(channel.sent.whereType<ArtifactRequest>().length, 1);
      await repository.cancel();
      await failed;
    },
  );
}
