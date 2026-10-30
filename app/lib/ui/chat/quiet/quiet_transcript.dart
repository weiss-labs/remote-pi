// Plan/75 — quiet mode fold. A pure view transform over the chat's message
// list: consecutive tool steps between two non-tool rows become one
// `QuietGroup` ("Worked for 2m 4s · 6 steps"); human-action steps and
// incoming pane messages stay out of the count as their own rows. The input
// list and every ChatMessage in it are read, never copied-with or mutated.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/quiet/quiet_presentation.dart';

sealed class QuietItem {
  const QuietItem();

  /// Stable list key.
  String get key;
}

/// A user / assistant / compaction row, unchanged.
class QuietPass extends QuietItem {
  final ChatMessage message;
  const QuietPass(this.message);
  @override
  String get key => message.id;
}

/// One folded run of ordinary steps.
class QuietGroup extends QuietItem {
  final List<ToolEvent> steps;
  final List<QuietView> views;

  /// Real run timing when both ends exist; null → count only.
  final Duration? duration;
  const QuietGroup({
    required this.steps,
    required this.views,
    required this.duration,
  });
  @override
  String get key => 'group-${steps.first.id}';

  String get label {
    final n = steps.length;
    final count = '$n step${n == 1 ? '' : 's'}';
    final d = duration;
    if (d == null) return count;
    final s = d.inSeconds;
    final time = s < 60 ? '${s}s' : '${s ~/ 60}m ${s % 60}s';
    return 'Worked for $time · $count';
  }
}

/// A step that needs a human (approval / sign-in / blocked) or carries an
/// exact-text draft panel (`view.draft`, shown in full).
class QuietProminent extends QuietItem {
  final ToolEvent tool;
  final QuietView view;
  const QuietProminent(this.tool, this.view);
  @override
  String get key => 'prominent-${tool.id}';
}

/// An incoming message from another pane, one line.
class QuietNotice extends QuietItem {
  final ToolEvent tool;
  final QuietView view;
  final String label;
  const QuietNotice(this.tool, this.view, this.label);
  @override
  String get key => 'notice-${tool.id}';
}

/// Timestamps the Mac did not have arrive as epoch 0; treat anything before
/// 2000 as "no timing".
bool _plausible(DateTime? t) => t != null && t.year >= 2000;

/// Fold [messages] for quiet display. While [working] is true the trailing
/// run of steps is the live one: it is omitted here because the status line
/// represents it, and it appears as a group once the reply lands.
List<QuietItem> foldQuiet(List<ChatMessage> messages, {required bool working}) {
  final out = <QuietItem>[];
  final run = <ToolEvent>[];

  void flush(ChatMessage? closing) {
    if (run.isEmpty) return;
    final steps = <ToolEvent>[];
    final views = <QuietView>[];
    final rest = <QuietItem>[];
    for (final t in run) {
      final view = presentation(t);
      if (isIncomingMessage(t)) {
        if (view.draft) {
          rest.add(QuietProminent(t, view));
        } else {
          final from = (t.args as Map)['from']?.toString();
          final label =
              meshLabel(from) + (view.prominent ? ' · ${view.label}' : '');
          rest.add(QuietNotice(t, view, label));
        }
      } else if (view.prominent) {
        rest.add(QuietProminent(t, view));
      } else {
        steps.add(t);
        views.add(view);
      }
    }
    final live = closing == null && working;
    if (steps.isNotEmpty && !live) {
      final start = steps.first.ts;
      final end = closing?.ts;
      final duration =
          _plausible(start) && _plausible(end) && !end!.isBefore(start!)
          ? end.difference(start)
          : null;
      out.add(QuietGroup(steps: steps, views: views, duration: duration));
    }
    out.addAll(rest);
    run.clear();
  }

  for (final m in messages) {
    if (m is ToolEvent) {
      run.add(m);
    } else {
      flush(m);
      out.add(QuietPass(m));
    }
  }
  flush(null);
  return out;
}
