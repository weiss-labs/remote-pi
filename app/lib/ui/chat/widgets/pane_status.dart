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
  const PaneUsage({
    required this.provider,
    required this.windows,
    this.email,
    this.extra,
  });

  final String provider;
  final String? email;

  /// Codex reserve credits ("+62,500 credits"), shown in the header line.
  final String? extra;
  final List<UsageWindow> windows;

  factory PaneUsage.fromJson(Map<String, dynamic> j) {
    final windows = [
      for (final w in (j['windows'] as List? ?? const []))
        if (w is Map<String, dynamic>) UsageWindow.fromJson(w),
    ];
    // Same order as the desktop widget: session, weekly, then model caps.
    int rank(UsageWindow w) => w.label == '5h'
        ? 0
        : w.label == 'weekly'
        ? 1
        : 2;
    windows.sort((a, b) => rank(a).compareTo(rank(b)));
    return PaneUsage(
      provider: j['provider'] as String? ?? '',
      email: j['email'] as String?,
      extra: j['extra'] as String?,
      windows: windows,
    );
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
      resetsAt: ms == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
    );
  }

  String get name => label == '5h'
      ? 'Session'
      : label == 'weekly'
      ? 'Weekly'
      : label;
}

/// The desktop "gas gauges", laid out like Pi's subscription widget in Herdr:
/// a dark band with "Provider · email", then one row per window:
/// `Session  84% left · resets 3:30 PM  [█████░░]`. Green above 50% left,
/// amber to 20%, red below.
class UsageGauges extends StatelessWidget {
  const UsageGauges(this.usage, {super.key});

  final PaneUsage usage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = context.typo.monoSmall.copyWith(
      color: colors.muted,
      height: 1.5,
    );
    final header = [
      usage.provider,
      if (usage.email != null && usage.email!.isNotEmpty) usage.email!,
    ].join(' · ');
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(header, style: base),
          if (usage.extra != null && usage.extra!.isNotEmpty)
            Text(usage.extra!, style: base.copyWith(color: colors.gaugeOk)),
          for (final w in usage.windows)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(width: 58, child: Text(w.name, style: base)),
                    Expanded(
                      child: Text(
                        w.leftPercent == null
                            ? '--% left'
                            : '${w.leftPercent!.round()}% left',
                        style: base.copyWith(
                          color: _color(colors, w.leftPercent),
                        ),
                      ),
                    ),
                    _BlockBar(
                      left: w.leftPercent,
                      color: _color(colors, w.leftPercent),
                      style: base,
                    ),
                  ],
                ),
                if (w.resetsAt != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 58),
                    child: Text(
                      'resets ${_reset(w.resetsAt!)}',
                      style: base.copyWith(
                        color: _color(colors, w.leftPercent),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static Color _color(AppColors colors, double? left) =>
      left == null || left <= 20
      ? colors.error
      : left <= 50
      ? colors.gaugeWarn
      : colors.gaugeOk;

  /// "3:30 PM" today, else "Mon, Oct 26, 7:00 PM" (the desktop's format).
  static String _reset(DateTime at) {
    final now = DateTime.now();
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final time =
        '$h:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}';
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return time;
    }
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[at.weekday - 1]}, ${months[at.month - 1]} ${at.day}, $time';
  }
}

/// `[█████░░]` — a square-cornered battery that drains right to left.
class _BlockBar extends StatelessWidget {
  const _BlockBar({
    required this.left,
    required this.color,
    required this.style,
  });

  final double? left;
  final Color color;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('[', style: style),
        Container(
          width: 64,
          height: 11,
          color: context.colors.toolPendingBg,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: ((left ?? 0) / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: color),
          ),
        ),
        Text(']', style: style),
      ],
    );
  }
}
