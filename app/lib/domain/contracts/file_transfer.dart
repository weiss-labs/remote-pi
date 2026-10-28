import 'package:flutter/foundation.dart' show ValueListenable;

import 'repository.dart';

class FileTransferFailure implements Exception {
  final String message;
  const FileTransferFailure(this.message);
  @override
  String toString() => message;
}

/// Plan/74 — a local file (video, pasted file, shared item) waiting to be
/// sent to a pane. [path] is app-private; [size] is read when picked.
class PendingFile {
  final String path, name, mime;
  final int size;
  final int? durationMs;
  const PendingFile({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
    this.durationMs,
  });
  bool get isVideo => mime.startsWith('video/');
}

/// Progress of the one in-flight upload (shown above the composer).
class FileTransferProgress {
  final PendingFile file;
  final double fraction;
  const FileTransferProgress(this.file, this.fraction);
}

abstract class FileTransfer extends Repository {
  /// The in-flight upload (null when idle), for progress UI anywhere.
  ValueListenable<FileTransferProgress?> get current;

  /// One source-bound upload at a time. [messageId] becomes the id of the
  /// user message the pane echoes once the file is verified. Refuses to start
  /// unless the active channel is routed to [peer]/[room].
  Future<void> send(
    PendingFile file, {
    required String messageId,
    required String peer,
    required String room,
    String caption = '',
    bool steer = false,
    void Function(double)? onProgress,
  });
  Future<void> cancel();
}
