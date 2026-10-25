import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// A row in the Home list.
///
/// Renders an inline presence dot (plano 12) driven by
/// [ConnectionManager.presenceStream]: green = online, grey = offline,
/// no dot = relay hasn't reported yet.
class SessionTile extends StatelessWidget {
  final PeerRecord peer;
  /// `true` when the room is announced live on the relay AND the
  /// relay itself is reachable. Drives the green dot.
  final bool isLive;
  /// `true` when the WS to the relay is currently retrying / down.
  /// Overrides `isLive` and renders an amber "reconnecting" dot —
  /// the app has no fresh signal on any room right now.
  final bool isReconnecting;
  /// Plan-18 follow-up — `true` when the agent in this room is
  /// currently producing a response. Highest-priority colour (blue).
  final bool isWorking;
  final RoomInfo? room;
  final VoidCallback onOpen;
  /// Plan/tablet — `true` when this is the session shown in the tablet's
  /// detail pane. Paints the accent left-bar + faint fill from the mock.
  /// Always `false` on phone (no persistent selection there).
  final bool isSelected;
  /// Plan-17 follow-up — long-press context menu. Caller wires the
  /// dialog (rename + delete-offline). Optional; when null the tile
  /// only responds to tap.
  final VoidCallback? onLongPress;
  /// Weiss Labs: explicit row title (the Herdr pane leaf) when set.
  final String? title;

  const SessionTile({
    super.key,
    required this.peer,
    required this.isLive,
    required this.onOpen,
    this.room,
    this.isReconnecting = false,
    this.isWorking = false,
    this.isSelected = false,
    this.onLongPress,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.bg,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isSelected ? colors.accent.withValues(alpha: 0.06) : colors.bg,
            border: Border(
              left: BorderSide(
                color: isSelected ? colors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Padding(
            // Trim the left inset by the 3px accent bar so content stays
            // aligned whether selected or not.
            padding: EdgeInsets.fromLTRB(isSelected ? 15 : 18, 14, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _TitleBlock(peer: peer, room: room, titleOverride: title),
                ),
                _PresenceDot(
                  isLive: isLive,
                  isReconnecting: isReconnecting,
                  isWorking: isWorking,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

class _PresenceDot extends StatelessWidget {
  final bool isLive;
  final bool isReconnecting;
  final bool isWorking;
  const _PresenceDot({
    required this.isLive,
    required this.isReconnecting,
    this.isWorking = false,
  });

  @override
  Widget build(BuildContext context) {
    // Plan-18 follow-up — 4-state dot. Priority high → low:
    //   working (agent streaming)   → blue
    //   reconnecting (relay down)   → amber
    //   live (relay up + announced) → green
    //   else (cached / offline)     → grey
    final colors = context.colors;
    // Weiss Labs: a spinning wheel while the pane is mid-task, like Herdr.
    if (isWorking) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.8, color: colors.working),
      );
    }
    final Color color = isReconnecting
            ? colors.warning
            : isLive
                ? colors.success
                : colors.muted;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final PeerRecord peer;
  final RoomInfo? room;
  final String? titleOverride;
  const _TitleBlock({required this.peer, required this.room, this.titleOverride});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final r = room;
    // Title preference: explicit room.name → cwd basename → peer
    // nickname → session name. The cwd path line was dropped on purpose
    // — the tile now shows just title + subtitle (model / paired date).
    final String title;
    if (titleOverride != null) {
      title = titleOverride!;
    } else if (r != null) {
      if (r.name != null && r.name!.isNotEmpty) {
        title = r.name!;
      } else if (r.cwd != null && r.cwd!.isNotEmpty) {
        final segs = r.cwd!.split('/').where((s) => s.isNotEmpty).toList();
        title = segs.isNotEmpty ? segs.last : r.cwd!;
      } else if (peer.nickname?.isNotEmpty == true) {
        title = peer.nickname!;
      } else {
        title = peer.sessionName;
      }
    } else {
      title =
          peer.nickname?.isNotEmpty == true ? peer.nickname! : peer.sessionName;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.text,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        // Subtitle = the Pi-extension's model (when surfaced via
        // `room_announced` / `room_meta_updated`), else the legacy
        // "Last paired" timestamp so the row keeps a stable height.
        Builder(builder: (_) {
          final model = room?.model;
          final hasModel = model != null && model.isNotEmpty;
          return Text(
            hasModel
                ? _truncateModel(model)
                : 'Last paired: ${_relativeTime(peer.pairedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasModel ? colors.accent : colors.muted,
              fontSize: 12,
              fontFamily: kMonoFamily,
            ),
          );
        }),
      ],
    );
  }
}

String _truncateModel(String name) =>
    name.length <= 24 ? name : '${name.substring(0, 21)}…';



String _relativeTime(String isoUtc) {
  final parsed = DateTime.tryParse(isoUtc);
  if (parsed == null) return isoUtc;
  final now = DateTime.now().toUtc();
  final diff = now.difference(parsed);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return isoUtc.substring(0, 10);
}
