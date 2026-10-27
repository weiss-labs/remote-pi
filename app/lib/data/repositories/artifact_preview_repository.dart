import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:app/domain/contracts/artifact_preview.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';

/// Bounded sequential transfer. No URL/path is passed to the native viewer.
class ArtifactPreviewRepository extends ArtifactPreview {
  ArtifactPreviewRepository(
    this.connection, {
    this.native = const MethodChannel('ai.weisslabs.remotepi/artifacts'),
    this.timeout = const Duration(seconds: 20),
  }) {
    _status = connection.statusStream.listen((_) => _checkSource());
    _rooms = connection.roomsStream.listen((_) => _checkSource());
  }
  final ConnectionManager connection;
  final MethodChannel native;
  final Duration timeout;
  static const maxBytes = 20 * 1024 * 1024;
  static const chunkBytes = 192 * 1024;
  late final StreamSubscription<ConnectionStatus> _status;
  late final StreamSubscription<Map<String, List<RoomInfo>>> _rooms;
  StreamSubscription<ServerMessage>? _replies;
  IChannel? _channel;
  String? _peer, _room, _transfer, _pendingId;
  Completer<Map<String, dynamic>>? _pending;
  int _generation = 0, _sequence = 0;
  bool _busy = false;

  bool get _sameSource =>
      identical(connection.channel, _channel) &&
      connection.activePeer?.remoteEpk == _peer &&
      connection.activeRoomId == _room;
  void _checkSource() {
    if (_busy && !_sameSource) unawaited(cancel());
  }

  void _check(int generation) {
    if (!_busy || generation != _generation || !_sameSource) {
      throw const ArtifactFailure(
        'Preview cancelled because the pane changed or was closed.',
      );
    }
  }

  String _id() =>
      'artifact-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  Future<Map<String, dynamic>> _request(
    ArtifactRequest request,
    int generation,
  ) async {
    _check(generation);
    final completer = Completer<Map<String, dynamic>>();
    _pending = completer;
    _pendingId = request.id;
    // Install the error listener before a send can race cancellation.
    final response = completer.future.timeout(timeout);
    unawaited(_send(request, completer));
    try {
      final result = await response;
      _check(generation);
      if (result['type'] == 'artifact_error') {
        throw const ArtifactFailure(
          'This file is unavailable or not authorized for preview.',
        );
      }
      return result;
    } on TimeoutException {
      throw const ArtifactFailure(
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
    ArtifactRequest request,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      await _channel!.send(request);
    } on Exception {
      if (!completer.isCompleted) {
        completer.completeError(
          const ArtifactFailure('Could not reach the paired pane.'),
        );
      }
    } on StateError {
      if (!completer.isCompleted) {
        completer.completeError(
          const ArtifactFailure('The connection closed.'),
        );
      }
    }
  }

  @override
  Future<void> open(
    String url, {
    required void Function(double) progress,
  }) async {
    if (_busy) throw const ArtifactFailure('Close the current preview first.');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'file' || url.length > 8192) {
      throw const ArtifactFailure('Only linked files can use this preview.');
    }
    _channel = connection.channel;
    _peer = connection.activePeer?.remoteEpk;
    _room = connection.activeRoomId;
    if (_channel == null || _peer == null) {
      throw const ArtifactFailure('Connect to this pane first.');
    }
    _busy = true;
    final generation = ++_generation;
    _replies = _channel!.serverMessages.listen((message) {
      _checkSource();
      if (generation != _generation ||
          !_sameSource ||
          message is! ArtifactReply) {
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
      final opened = await _request(
        ArtifactRequest(type: 'artifact_open', id: _id(), url: url),
        generation,
      );
      final transfer = opened['transfer_id'];
      final size = opened['size'];
      final mime = opened['mime'];
      final hash = opened['sha256'];
      const extensions = {
        'application/pdf': 'pdf',
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/gif': 'gif',
        'image/webp': 'webp',
      };
      if (opened['type'] != 'artifact_opened' ||
          transfer is! String ||
          transfer.isEmpty ||
          transfer.length > 256) {
        throw const ArtifactFailure('Invalid file preview response.');
      }
      _transfer = transfer;
      if (size is! int ||
          size <= 0 ||
          size > maxBytes ||
          !extensions.containsKey(mime) ||
          hash is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
        throw const ArtifactFailure(
          'Unsupported file type, size, or integrity metadata.',
        );
      }
      final bytes = Uint8List(size);
      var offset = 0;
      while (offset < size) {
        final chunk = await _request(
          ArtifactRequest(
            type: 'artifact_chunk',
            id: _id(),
            transferId: transfer,
            offset: offset,
          ),
          generation,
        );
        final encoded = chunk['data'];
        if (chunk['type'] != 'artifact_chunk' ||
            chunk['transfer_id'] != transfer ||
            chunk['offset'] != offset ||
            encoded is! String ||
            encoded.length > ((chunkBytes + 2) ~/ 3) * 4) {
          throw const ArtifactFailure('Invalid file chunk.');
        }
        final part = base64Decode(encoded);
        if (part.isEmpty ||
            part.length > chunkBytes ||
            offset + part.length > size ||
            chunk['eof'] != (offset + part.length == size)) {
          throw const ArtifactFailure('Invalid file chunk bounds.');
        }
        bytes.setRange(offset, offset + part.length, part);
        offset += part.length;
        progress(offset / size);
      }
      final actual = (await Sha256().hash(
        bytes,
      )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _check(generation);
      if (actual != hash.toLowerCase()) {
        throw const ArtifactFailure(
          'File integrity check failed. Nothing was opened.',
        );
      }
      await _closeTransfer();
      _check(generation);
      await native.invokeMethod<void>('preview', {
        'bytes': bytes,
        'extension': extensions[mime],
      });
      _check(generation);
    } on FormatException {
      throw const ArtifactFailure('Invalid file data.');
    } on PlatformException {
      throw const ArtifactFailure(
        'The native file viewer could not open this file.',
      );
    } on MissingPluginException {
      throw const ArtifactFailure(
        'Native file preview is not available on this platform.',
      );
    } finally {
      await _closeTransfer();
      await _replies?.cancel();
      _replies = null;
      _busy = false;
    }
  }

  Future<void> _closeTransfer() async {
    final transfer = _transfer;
    _transfer = null;
    if (transfer == null) return;
    final request = ArtifactRequest(
      type: 'artifact_close',
      id: _id(),
      transferId: transfer,
    );
    try {
      final channel = _channel;
      if (_sameSource) {
        await channel?.send(request);
      }
    } on Exception {
      /* Backend TTL also releases abandoned handles. */
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const ArtifactFailure('Preview cancelled.'));
    }
    await _closeTransfer();
    try {
      await native.invokeMethod<void>('dismiss');
    } on PlatformException {
      /* Already dismissed. */
    } on MissingPluginException {
      /* Unsupported platform. */
    }
  }

  @override
  void dispose() {
    unawaited(cancel());
    unawaited(_status.cancel());
    unawaited(_rooms.cancel());
    unawaited(_replies?.cancel());
    super.dispose();
  }
}
