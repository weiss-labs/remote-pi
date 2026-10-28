// Plan/74 — phone → Mac attachment upload: sequential chunks, offsets, the
// pre-computed hash, size cap, cancel and stale-room protection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/repositories/file_transfer_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'artifact_preview_repository_test.dart' show ProductionLikeChannel;
import 'pane_commands_repository_test.dart' show Storage, peer, flush;

void main() {
  late ProductionLikeChannel channel;
  late ConnectionManager connection;
  late FileTransferRepository repository;
  final bytes = List<int>.generate(1000, (i) => i % 251);
  late String hash;
  final file = PendingFile(
    path: '/private/clip.mov',
    name: 'clip.mov',
    mime: 'video/quicktime',
    size: bytes.length,
    durationMs: 4200,
  );
  final progress = <double>[];

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
    progress.clear();
    repository = FileTransferRepository(
      connection,
      timeout: const Duration(milliseconds: 100),
      readFile: (path, chunk) => Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += chunk)
          bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
      ]),
    );
  });
  tearDown(() async {
    repository.dispose();
    await flush();
    connection.dispose();
    await channel.incoming.close();
  });
  FileRequest lastRequest() => channel.sent.whereType<FileRequest>().last;
  // Real file I/O takes more than one microtask.
  Future<void> settle(String type) async {
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final sent = channel.sent.whereType<FileRequest>();
      if (sent.isNotEmpty && sent.last.type == type) return;
    }
    fail('no $type frame was sent');
  }
  void reply(String type, [Map<String, Object?> extra = const {}]) =>
      channel.incoming.add(
        FileReply({
          'type': type,
          'in_reply_to': lastRequest().id,
          'transfer_id': 'handle',
          ...extra,
        }),
      );
  Future<void> send({
    String room = 'room-a',
    String caption = '',
    bool steer = false,
    PendingFile? which,
  }) => repository.send(
    which ?? file,
    messageId: 'msg-1',
    peer: 'paired-key',
    room: room,
    caption: caption,
    steer: steer,
    onProgress: progress.add,
  );

  test('hashes first, then opens, streams sequential chunks and closes', () async {
    final future = send(caption: 'look', steer: true);
    await flush();
    final open = lastRequest().toJson();
    expect(open, {
      'type': 'file_open',
      'id': open['id'],
      'name': 'clip.mov',
      'mime': 'video/quicktime',
      'size': 1000,
      'sha256': hash,
      'duration_ms': 4200,
      'text': 'look',
      'streaming_behavior': 'steer',
    });
    reply('file_opened', {'in_reply_to': 'foreign'});
    await flush();
    expect(channel.sent.whereType<FileRequest>().length, 1);
    reply('file_opened');
    await flush();
    final chunk = lastRequest().toJson();
    expect(chunk['type'], 'file_chunk');
    expect(chunk['offset'], 0);
    expect(base64Decode(chunk['data'] as String), bytes);
    reply('file_ack', {'offset': 1000});
    await flush();
    final close = lastRequest();
    expect(close.type, 'file_close');
    expect(close.id, 'msg-1');
    expect(close.toJson()['transfer_id'], 'handle');
    reply('file_done', {'path': '/Users/x/.pi/remote/attachments/a-clip.mov'});
    await future;
    expect(progress.first, 0);
    expect(progress.last, 1);
    expect(channel.sent.whereType<FileRequest>().map((r) => r.type), [
      'file_open',
      'file_chunk',
      'file_close',
    ]);
  });

  test('splits a real file into bounded chunks with correct offsets', () async {
    final dir = await Directory.systemTemp.createTemp('rp-file-transfer');
    addTearDown(() => dir.delete(recursive: true));
    final big = List<int>.generate(
      FileTransferRepository.chunkBytes * 2 + 17,
      (i) => (i * 7) % 256,
    );
    final path = '${dir.path}/big.bin';
    await File(path).writeAsBytes(big);
    final real = FileTransferRepository(
      connection,
      timeout: const Duration(milliseconds: 100),
    );
    addTearDown(real.dispose);
    final future = real.send(
      PendingFile(
        path: path,
        name: 'big.bin',
        mime: 'application/octet-stream',
        size: big.length,
      ),
      messageId: 'msg-2',
      peer: 'paired-key',
      room: 'room-a',
      onProgress: progress.add,
    );
    await settle('file_open');
    expect(
      lastRequest().toJson()['sha256'],
      (await Sha256().hash(
        big,
      )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
    reply('file_opened');
    final received = <int>[];
    for (final expected in [0, 192 * 1024, 384 * 1024]) {
      await settle('file_chunk');
      final chunk = lastRequest().toJson();
      expect(chunk['type'], 'file_chunk');
      expect(chunk['offset'], expected);
      final part = base64Decode(chunk['data'] as String);
      expect(part.length, lessThanOrEqualTo(FileTransferRepository.chunkBytes));
      received.addAll(part);
      reply('file_ack', {'offset': received.length});
    }
    await settle('file_close');
    expect(received, big);
    reply('file_done');
    await future;
    expect(progress, contains(closeTo(0.5, 0.01)));
    expect(progress.last, 1);
  });

  test('refuses the size cap and empty files before any frame', () async {
    await expectLater(
      send(which: PendingFile(path: 'x', name: 'x', mime: 'video/mp4', size: FileTransferRepository.maxBytes + 1)),
      throwsA(isA<FileTransferFailure>()),
    );
    await expectLater(
      send(which: const PendingFile(path: 'x', name: 'x', mime: 'video/mp4', size: 0)),
      throwsA(isA<FileTransferFailure>()),
    );
    expect(channel.sent.whereType<FileRequest>(), isEmpty);
  });

  test('refuses to start for a room other than the active one', () async {
    await expectLater(send(room: 'room-b'), throwsA(isA<FileTransferFailure>()));
    expect(channel.sent.whereType<FileRequest>(), isEmpty);
  });

  for (final bad in <Map<String, Object?>>[
    {'offset': 5},
    {'transfer_id': 'other'},
    {'type': 'file_error', 'code': 'invalid', 'message': 'nope'},
  ]) {
    test('a wrong ack $bad fails and cancels the transfer', () async {
      final failed = expectLater(send(), throwsA(isA<FileTransferFailure>()));
      await flush();
      reply('file_opened');
      await flush();
      reply('file_ack', {'offset': 1000, ...bad});
      await failed;
      expect(lastRequest().type, 'file_cancel');
      expect(lastRequest().toJson()['transfer_id'], 'handle');
    });
  }

  test('a pane switch mid-upload cancels and never re-routes', () async {
    final failed = expectLater(send(), throwsA(isA<FileTransferFailure>()));
    await flush();
    reply('file_opened');
    await flush();
    connection.switchRoom('room-b');
    await failed;
    // The cancel is not sent to the new room.
    expect(lastRequest().type, isNot('file_cancel'));
    connection.switchRoom('room-a');
    await flush();
    expect(channel.sent.whereType<FileRequest>().length, 2);
  });

  test('cancel stops a pending request and tells the pane', () async {
    final failed = expectLater(send(), throwsA(isA<FileTransferFailure>()));
    await flush();
    reply('file_opened');
    await flush();
    await repository.cancel();
    await failed;
    expect(lastRequest().type, 'file_cancel');
    // Fresh send allowed afterwards.
    final again = send();
    await flush();
    expect(lastRequest().type, 'file_open');
    await repository.cancel();
    await expectLater(again, throwsA(isA<FileTransferFailure>()));
  });

  test('silence times out honestly and a second send waits', () async {
    final first = send();
    await flush();
    await expectLater(send(), throwsA(isA<FileTransferFailure>()));
    await expectLater(first, throwsA(isA<FileTransferFailure>()));
  });
}
