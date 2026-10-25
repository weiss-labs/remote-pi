import 'dart:convert';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Weiss Labs: the structured Pi footer the Mac's compact-footer extension
/// publishes as JSON (context %, model, thinking, subscription usage). Older
/// panes still send plain text; [parse] returns null for those so the header
/// shows nothing rather than raw terminal escapes.
class PaneFooter {
  const PaneFooter({this.ctxPct, this.model, this.thinking, this.usage});

  final double? ctxPct;
  final String? model;
  final String? thinking;
  final PaneUsage? usage;

  static PaneFooter? parse(String? raw) {
    if (raw == null || !raw.startsWith('{')) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final u = j['usage'];
      return PaneFooter(
        ctxPct: (j['ctxPct'] as num?)?.toDouble(),
        model: j['model'] as String?,
        thinking: j['thinking'] as String?,
        usage: u is Map<String, dynamic> ? PaneUsage.fromJson(u) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class PaneUsage {
  const PaneUsage({required this.provider, required this.windows});

  final String provider;
  final List<UsageWindow> windows;

  factory PaneUsage.fromJson(Map<String, dynamic> j) {
    final windows = [
      for (final w in (j['windows'] as List? ?? const []))
        if (w is Map<String, dynamic>) UsageWindow.fromJson(w),
    ];
    // Same order as the desktop widget: session, weekly, then model caps.
    int rank(UsageWindow w) => w.label == '5h' ? 0 : w.label == 'weekly' ? 1 : 2;
    windows.sort((a, b) => rank(a).compareTo(rank(b)));
    return PaneUsage(provider: j['provider'] as String? ?? '', windows: windows);
  }
}

class UsageWindow {
  const UsageWindow({required this.label, this.leftPercent, this.resetsAt});

  final String label;
  final double? leftPercent;
  final DateTime? resetsAt;

  factory UsageWindow.fromJson(Map<String, dynamic> j) {
    final ms = j['resetsAtMs'] as num?;
    return UsageWindow(
      label: j['label'] as String? ?? '',
      leftPercent: (j['leftPercent'] as num?)?.toDouble(),
      resetsAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
    );
  }

  String get name => label == '5h'
      ? 'Session'
      : label == 'weekly'
      ? 'Weekly'
      : label;
}

/// The desktop "gas gauges": one line per usage window, bar drains as the
/// window is used. Green above 50% left, amber to 20%, red below.
class UsageGauges extends StatelessWidget {
  const UsageGauges(this.usage, {super.key});

  final PaneUsage usage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = TextStyle(fontFamily: kMonoFamily, fontSize: 10, color: colors.muted);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in usage.windows)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    '${usage.provider} ${w.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: label,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (w.leftPercent ?? 0) / 100,
                      minHeight: 6,
                      backgroundColor: colors.border,
                      color: _color(colors, w.leftPercent),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  [
                    w.leftPercent == null ? '--%' : '${w.leftPercent!.round()}%',
                    if (w.resetsAt != null) _reset(w.resetsAt!),
                  ].join(' · '),
                  style: label.copyWith(color: _color(colors, w.leftPercent)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Color _color(AppColors colors, double? left) => left == null || left <= 20
      ? colors.error
      : left <= 50
      ? colors.warning
      : colors.success;

  static String _reset(DateTime at) {
    final now = DateTime.now();
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final time = '$h:${at.minute.toString().padLeft(2, '0')}${at.hour < 12 ? 'a' : 'p'}';
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    if (sameDay) return time;
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[at.weekday - 1]} $time';
  }
}
