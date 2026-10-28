import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

/// Plan/74 — bounded sequential upload of one local file to the paired pane
/// (the mirror of [ArtifactPreviewRepository]). The channel, peer and room are
/// captured when the send starts and every step re-checks them, so a pane
/// switch cancels instead of re-routing. The Mac verifies the whole-file
/// SHA-256 before the pane ever hears about the file.
class FileTransferRepository extends FileTransfer {
  FileTransferRepository(
    this.connection, {
    this.timeout = const Duration(seconds: 30),
    this.readFile = _readFile,
  }) {
    _status = connection.statusStream.listen((_) => _checkSource());
    _rooms = connection.roomsStream.listen((_) => _checkSource());
  }
  final ConnectionManager connection;
  final Duration timeout;

  /// Streams the file in [chunkBytes] pieces; a seam for tests.
  final Stream<List<int>> Function(String path, int chunkBytes) readFile;
  static const maxBytes = 200 * 1024 * 1024;
  static const chunkBytes = 192 * 1024;
  late final StreamSubscription<ConnectionStatus> _status;
  late final StreamSubscription<Map<String, List<RoomInfo>>> _rooms;
  StreamSubscription<ServerMessage>? _replies;
  IChannel? _channel;
  String? _peer, _room, _transfer, _pendingId;
  Completer<Map<String, dynamic>>? _pending;
  int _generation = 0, _sequence = 0;
  bool _busy = false;
  @override
  ValueNotifier<FileTransferProgress?> get current => _current;
  final _current = ValueNotifier<FileTransferProgress?>(null);

  static Stream<List<int>> _readFile(String path, int chunk) =>
      File(path).openRead().transform(_Rechunk(chunk));

  bool get _sameSource =>
      identical(connection.channel, _channel) &&
      connection.activePeer?.remoteEpk == _peer &&
      connection.activeRoomId == _room;
  void _checkSource() {
    if (_busy && !_sameSource) unawaited(cancel());
  }

  void _check(int generation) {
    if (!_busy || generation != _generation || !_sameSource) {
      throw const FileTransferFailure(
        'Upload cancelled because the pane changed or was closed.',
      );
    }
  }

  String _id() => 'file-${uuid7()}-${_sequence++}';

  Future<Map<String, dynamic>> _request(
    FileRequest request,
    int generation,
  ) async {
    _check(generation);
    final completer = Completer<Map<String, dynamic>>();
    _pending = completer;
    _pendingId = request.id;
    final response = completer.future.timeout(timeout);
    unawaited(_send(request, completer));
    try {
      final result = await response;
      _check(generation);
      if (result['type'] == 'file_error') {
        final message = result['message'];
        throw FileTransferFailure(
          message is String && message.isNotEmpty
              ? message
              : 'The pane refused this attachment.',
        );
      }
      return result;
    } on TimeoutException {
      throw const FileTransferFailure(
        'The pane did not respond. Try again when connected.',
      );
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
        _pendingId = null;
      }
    }
  }

  Future<void> _send(
    FileRequest request,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      await _channel!.send(request);
    } on Exception {
      if (!completer.isCompleted) {
        completer.completeError(
          const FileTransferFailure('Could not reach the paired pane.'),
        );
      }
    } on StateError {
      if (!completer.isCompleted) {
        completer.completeError(
          const FileTransferFailure('The connection closed.'),
        );
      }
    }
  }

  @override
  Future<void> send(
    PendingFile file, {
    required String messageId,
    required String peer,
    required String room,
    String caption = '',
    bool steer = false,
    void Function(double)? onProgress,
  }) async {
    void progress(double f) {
      _current.value = FileTransferProgress(file, f);
      onProgress?.call(f);
    }

    if (_busy) {
      throw const FileTransferFailure('Wait for the current upload to finish.');
    }
    if (file.size <= 0) throw const FileTransferFailure('That file is empty.');
    if (file.size > maxBytes) {
      throw const FileTransferFailure(
        'Attachments are limited to 200 MiB. Trim the video and try again.',
      );
    }
    _channel = connection.channel;
    _peer = connection.activePeer?.remoteEpk;
    _room = connection.activeRoomId;
    if (_channel == null ||
        _peer == null ||
        toStandardB64(_peer!) != toStandardB64(peer) ||
        _room != room) {
      _channel = null;
      throw const FileTransferFailure('Open this pane first, then send.');
    }
    _busy = true;
    final generation = ++_generation;
    _replies = _channel!.serverMessages.listen((message) {
      _checkSource();
      if (generation != _generation || !_sameSource || message is! FileReply) {
        return;
      }
      final data = message.data;
      if (data['in_reply_to'] == _pendingId &&
          _pending != null &&
          !_pending!.isCompleted) {
        _pending!.complete(data);
      }
    });
    try {
      progress(0);
      final hashSink = Sha256().newHashSink();
      var hashed = 0;
      await for (final part in readFile(file.path, chunkBytes)) {
        _check(generation);
        hashSink.add(part);
        hashed += part.length;
        if (hashed > file.size) break;
      }
      hashSink.close();
      if (hashed != file.size) {
        throw const FileTransferFailure(
          'That file changed while it was being read. Pick it again.',
        );
      }
      final sha256 = (await hashSink.hash()).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final opened = await _request(
        FileRequest('file_open', _id(), {
          'name': file.name,
          'mime': file.mime,
          'size': file.size,
          'sha256': sha256,
          if (file.durationMs != null && file.durationMs! > 0)
            'duration_ms': file.durationMs,
          if (caption.isNotEmpty) 'text': caption,
          if (steer) 'streaming_behavior': 'steer',
        }),
        generation,
      );
      final transfer = opened['transfer_id'];
      if (opened['type'] != 'file_opened' ||
          transfer is! String ||
          transfer.isEmpty ||
          transfer.length > 256) {
        throw const FileTransferFailure('Invalid upload response.');
      }
      _transfer = transfer;
      var offset = 0;
      await for (final part in readFile(file.path, chunkBytes)) {
        if (part.isEmpty) continue;
        if (part.length > chunkBytes || offset + part.length > file.size) {
          throw const FileTransferFailure('That file changed while uploading.');
        }
        final ack = await _request(
          FileRequest('file_chunk', _id(), {
            'transfer_id': transfer,
            'offset': offset,
            'data': base64Encode(part),
          }),
          generation,
        );
        offset += part.length;
        if (ack['type'] != 'file_ack' ||
            ack['transfer_id'] != transfer ||
            ack['offset'] != offset) {
          throw const FileTransferFailure('The pane lost track of the upload.');
        }
        progress(offset / file.size);
      }
      if (offset != file.size) {
        throw const FileTransferFailure('That file changed while uploading.');
      }
      final done = await _request(
        FileRequest('file_close', messageId, {'transfer_id': transfer}),
        generation,
      );
      _transfer = null;
      if (done['type'] != 'file_done' || done['transfer_id'] != transfer) {
        throw const FileTransferFailure('The pane did not confirm the upload.');
      }
      progress(1);
    } on FileSystemException {
      throw const FileTransferFailure('That file could not be read.');
    } finally {
      await _cancelTransfer();
      await _replies?.cancel();
      _replies = null;
      _busy = false;
      _current.value = null;
    }
  }

  Future<void> _cancelTransfer() async {
    final transfer = _transfer;
    _transfer = null;
    if (transfer == null) return;
    try {
      if (_sameSource) {
        await _channel?.send(
          FileRequest('file_cancel', _id(), {'transfer_id': transfer}),
        );
      }
    } on Exception {
      /* The Mac drops idle partial uploads on its own. */
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const FileTransferFailure('Upload cancelled.'));
    }
    await _cancelTransfer();
  }

  @override
  void dispose() {
    unawaited(cancel());
    unawaited(_status.cancel());
    unawaited(_rooms.cancel());
    unawaited(_replies?.cancel());
    _current.dispose();
    super.dispose();
  }
}

/// Re-slices an arbitrary byte stream into fixed-size pieces.
class _Rechunk extends StreamTransformerBase<List<int>, List<int>> {
  const _Rechunk(this.size);
  final int size;
  @override
  Stream<List<int>> bind(Stream<List<int>> stream) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final part in stream) {
      buffer.add(part);
      while (buffer.length >= size) {
        final bytes = buffer.takeBytes();
        yield bytes.sublist(0, size);
        buffer.add(bytes.sublist(size));
      }
    }
    if (buffer.isNotEmpty) yield buffer.takeBytes();
  }
}
