import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:flutter/services.dart';

/// Plan/74 — hand-off with the iOS Share extension through the App Group
/// container. The extension cannot reach the paired channel, so it copies the
/// shared item into the container, queues a JSON entry bound to the pane the
/// user picked, and tries to open the app. The app drains the queue on every
/// foreground (cold start included) and sends each item to exactly that pane.
///
/// The extension's pane picker reads a snapshot the app publishes whenever
/// Home renders: same Herdr workspace/tab/pane grouping and names.
class SharedItem {
  final String id, peer, room, label;
  final PendingFile file;
  const SharedItem({
    required this.id,
    required this.peer,
    required this.room,
    required this.label,
    required this.file,
  });
}

/// One row of the pane snapshot the Share extension shows.
class SharedPane {
  final String peer, room, workspace, pane, device;
  final String? tab;
  final bool online;
  const SharedPane({
    required this.peer,
    required this.room,
    required this.workspace,
    this.tab,
    required this.pane,
    required this.device,
    required this.online,
  });
  Map<String, Object?> toJson() => {
    'peer': peer,
    'room': room,
    'workspace': workspace,
    if (tab != null) 'tab': tab,
    'pane': pane,
    'device': device,
    'online': online,
  };
}

abstract class ShareInbox {
  /// Queued items, oldest first. Items stay queued until [complete].
  Future<List<SharedItem>> takeQueued();

  /// Delete the entry and its file (sent, failed or refused).
  Future<void> complete(String id);

  /// Replace the pane snapshot the extension lists.
  Future<void> publishPanes(List<SharedPane> panes);
}

class NativeShareInbox implements ShareInbox {
  NativeShareInbox([
    this.channel = const MethodChannel('ai.weisslabs.remotepi/share'),
  ]);
  final MethodChannel channel;

  @override
  Future<List<SharedItem>> takeQueued() async {
    try {
      return parseSharedItems(
        await channel.invokeListMethod<dynamic>('takeQueued'),
      );
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<void> complete(String id) async {
    try {
      await channel.invokeMethod<void>('complete', {'id': id});
    } on PlatformException {
      /* Already gone. */
    } on MissingPluginException {
      /* Not iOS. */
    }
  }

  @override
  Future<void> publishPanes(List<SharedPane> panes) async {
    try {
      await channel.invokeMethod<void>('publishPanes', {
        'panes': [for (final p in panes) p.toJson()],
      });
    } on PlatformException {
      /* Snapshot is best-effort; the extension shows its last copy. */
    } on MissingPluginException {
      /* Not iOS. */
    }
  }
}

/// Pure parse of the native queue list. Entries missing a peer/room/path or
/// with a non-positive size are skipped (never routed to a guessed pane).
List<SharedItem> parseSharedItems(List<dynamic>? raw) {
  final out = <SharedItem>[];
  for (final entry in raw ?? const []) {
    if (entry is! Map) continue;
    final id = entry['id'], peer = entry['peer'], room = entry['room'];
    final path = entry['path'], size = entry['size'];
    if (id is! String ||
        id.isEmpty ||
        peer is! String ||
        peer.isEmpty ||
        room is! String ||
        room.isEmpty ||
        path is! String ||
        path.isEmpty ||
        size is! int ||
        size <= 0) {
      continue;
    }
    final name = entry['name'];
    final label = name is String && name.isNotEmpty ? name : path.split('/').last;
    final mime = entry['mime'];
    final paneLabel = entry['label'];
    out.add(
      SharedItem(
        id: id,
        peer: peer,
        room: room,
        label: paneLabel is String ? paneLabel : '',
        file: PendingFile(
          path: path,
          name: label,
          mime: mime is String && mime.contains('/') ? mime : mimeForName(label),
          size: size,
          durationMs: entry['duration_ms'] is int ? entry['duration_ms'] as int : null,
        ),
      ),
    );
  }
  return out;
}
