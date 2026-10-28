import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:flutter/services.dart';

/// Plan/74 — real pasteboard items (copied photos, videos, files) as files.
/// Plain text and URLs never come back from here; the composer keeps those
/// as text. Native copies each item into an app-private temp directory.
abstract class IPasteboardService {
  /// Cheap check used to decide whether the Paste action should attach.
  Future<bool> hasAttachments();

  /// Copies every image/video/file item out of the pasteboard. Empty when
  /// the pasteboard only holds text or the platform has no native bridge.
  Future<List<PendingFile>> readAttachments();
}

class PasteboardService implements IPasteboardService {
  PasteboardService([
    this.channel = const MethodChannel('ai.weisslabs.remotepi/pasteboard'),
  ]);
  final MethodChannel channel;

  @override
  Future<bool> hasAttachments() async {
    try {
      return await channel.invokeMethod<bool>('hasAttachments') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<List<PendingFile>> readAttachments() async {
    List<dynamic>? items;
    try {
      items = await channel.invokeListMethod<dynamic>('readAttachments');
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
    return parsePasteboardItems(items);
  }
}

/// Pure mapping from the native item list to [PendingFile]s. Rejects
/// anything without a non-empty path, name and positive size.
List<PendingFile> parsePasteboardItems(List<dynamic>? items) {
  final out = <PendingFile>[];
  for (final raw in items ?? const []) {
    if (raw is! Map) continue;
    final path = raw['path'], name = raw['name'], size = raw['size'];
    if (path is! String || path.isEmpty || size is! int || size <= 0) continue;
    final label = name is String && name.isNotEmpty ? name : path.split('/').last;
    final mime = raw['mime'];
    out.add(
      PendingFile(
        path: path,
        name: label,
        mime: mime is String && mime.contains('/') ? mime : mimeForName(label),
        size: size,
        durationMs: raw['duration_ms'] is int ? raw['duration_ms'] as int : null,
      ),
    );
  }
  return out;
}
