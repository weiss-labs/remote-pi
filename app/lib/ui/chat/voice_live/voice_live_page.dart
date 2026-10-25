import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/themes/pi_voice_theme.dart';
import 'voice_approval_card.dart';
import 'voice_live_session.dart';

/// Native phone port of pi-voice/ui. The host owns the paid session and wake
/// lock. Mounting this page never starts or restarts a session automatically.
class VoiceLivePage extends StatefulWidget {
  const VoiceLivePage({
    super.key,
    required this.session,
    required this.paneName,
    required this.keepAwake,
  });
  final VoiceLiveSession session;
  final String paneName;
  final Future<void> Function(bool enabled) keepAwake;
  @override
  State<VoiceLivePage> createState() => _VoiceLivePageState();
}

class _VoiceLivePageState extends State<VoiceLivePage> {
  final _text = TextEditingController();
  final _chat = ScrollController();
  VoiceLivePhase? _previous;
  String? _actionError;
  bool _pending = false;
  bool _leaving = false;
  double _backDrag = 0;
  bool get _live =>
      widget.session.phase != VoiceLivePhase.ended &&
      widget.session.phase != VoiceLivePhase.error;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(VoiceLivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_changed);
      widget.session.addListener(_changed);
      _previous = null;
      _changed();
    }
  }

  void _changed() {
    if (_previous != widget.session.phase) {
      _previous = widget.session.phase;
      unawaited(HapticFeedback.selectionClick());
      unawaited(_wake(_live));
    }
    final follow = !_chat.hasClients || _chat.position.extentAfter < 80;
    if (mounted) setState(() {});
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _chat.hasClients) {
          _chat.jumpTo(_chat.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _wake(bool enabled) async {
    try {
      await widget.keepAwake(enabled);
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = 'Screen wake lock unavailable.');
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = 'Action failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final end =
        !_live ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('End this voice call?'),
                content: const Text('Leaving stops the live session.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Stay'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('End call'),
                  ),
                ],
              ),
            ) ==
            true;
    if (!mounted) return;
    if (end) {
      if (_live) {
        try {
          await widget.session.stop();
        } catch (_) {
          if (mounted) {
            setState(() => _actionError = 'Could not end call. Try again.');
          }
          _leaving = false;
          return;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    }
    _leaving = false;
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    unawaited(_wake(false));
    _text.dispose();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: buildPiVoiceTheme(),
    child: Builder(builder: _buildVoice),
  );

  Widget _buildVoice(BuildContext context) {
    final s = widget.session;
    final c = context.colors;
    final a = s.pendingApproval;
    final time =
        '${s.elapsed.inMinutes.toString().padLeft(2, '0')}:${(s.elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final phase =
        '${s.phase.name[0].toUpperCase()}${s.phase.name.substring(1)}';
    final status = !_live
        ? s.endedReason ??
              (s.phase == VoiceLivePhase.error ? 'Provider error' : 'Stopped')
        : phase;
    return PopScope(
      canPop: !_live,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: c.bg,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'pi',
                              style: context.typo.sansBody.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.3,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.paneName,
                                style: context.typo.sansBody.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: c.border),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'GPT-Live',
                                style: context.typo.monoSmall,
                              ),
                            ),
                            Text(
                              '\$${s.costUsd.toStringAsFixed(3)} ${s.costFinal ? 'final' : 'estimated'} · \$0.05/min',
                              style: context.typo.monoSmall,
                            ),
                            Text(time, style: context.typo.monoSmall),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  Expanded(
                    child: a != null && _live
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                            child: VoiceApprovalCard(
                              key: ValueKey('${a.id}:${a.draft?.hash}'),
                              approval: a,
                              session: s,
                            ),
                          )
                        : ListView.builder(
                            controller: _chat,
                            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                            itemCount: s.items.length,
                            itemBuilder: (context, i) {
                              final item = s.items[i];
                              final user = item.speaker == 'Zach';
                              final status =
                                  item.kind == VoiceLiveItemKind.backend ||
                                  item.kind == VoiceLiveItemKind.notice;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Align(
                                  alignment: user
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: user ? .82 : .92,
                                    child: Container(
                                      padding: user
                                          ? const EdgeInsets.symmetric(
                                              horizontal: 14,
                                              vertical: 8,
                                            )
                                          : EdgeInsets.zero,
                                      decoration: user
                                          ? BoxDecoration(
                                              color: c.userBubble,
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                            )
                                          : null,
                                      child: status
                                          ? Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 7,
                                                        right: 8,
                                                      ),
                                                  child: Container(
                                                    width: 7,
                                                    height: 7,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color:
                                                          item.text.contains(
                                                            'failed',
                                                          )
                                                          ? c.error
                                                          : item.text.contains(
                                                              'done',
                                                            )
                                                          ? c.success
                                                          : c.accent,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Text(
                                                    item.text,
                                                    style: context
                                                        .typo
                                                        .monoSmall
                                                        .copyWith(fontSize: 13),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Semantics(
                                              label: item.speaker,
                                              child: Text(
                                                item.text,
                                                style: context.typo.sansBody,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                    child: Column(
                      children: [
                        if (MediaQuery.viewInsetsOf(context).bottom == 0)
                          VoiceCloud(
                            phase: s.phase,
                            level: math.max(
                              s.muted ? 0 : s.micLevel,
                              s.voiceLevel,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          status,
                          textAlign: TextAlign.center,
                          style: context.typo.monoSmall.copyWith(
                            color: s.phase == VoiceLivePhase.error
                                ? c.error
                                : c.muted,
                          ),
                        ),
                        if (!_live)
                          TextButton(
                            onPressed: _pending ? null : () => _run(s.start),
                            child: Text(
                              'Start again',
                              style: context.typo.monoSmall.copyWith(
                                color: c.accent,
                              ),
                            ),
                          ),
                        if (_actionError != null)
                          Text(
                            _actionError!,
                            style: context.typo.monoSmall.copyWith(
                              color: c.error,
                            ),
                          ),
                        if (s.muted && _live)
                          Text(
                            'Muted · mute does not pause billing',
                            style: context.typo.monoSmall.copyWith(
                              color: c.error,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                          decoration: BoxDecoration(
                            color: c.inputFill,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            children: [
                              TextField(
                                controller: _text,
                                enabled: _live,
                                minLines: 1,
                                maxLines: 4,
                                style: context.typo.sansBody,
                                decoration: InputDecoration(
                                  hintText: 'Type a message',
                                  hintStyle: context.typo.sansBody.copyWith(
                                    color: c.muted,
                                  ),
                                  filled: false,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 2,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (s.phase == VoiceLivePhase.working)
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(
                                          onPressed: _pending
                                              ? null
                                              : () => _run(s.cancelWork),
                                          child: Text(
                                            'Cancel work',
                                            style: context.typo.monoSmall
                                                .copyWith(color: c.accent),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_live) ...[
                                    _control(
                                      context,
                                      label: s.muted ? 'Unmute' : 'Mute',
                                      icon: s.muted
                                          ? LucideIcons.micOff
                                          : LucideIcons.mic,
                                      color: s.muted ? c.error : c.success,
                                      fill: (s.muted ? c.error : c.success)
                                          .withValues(alpha: .14),
                                      action: () => s.setMuted(!s.muted),
                                    ),
                                    _control(
                                      context,
                                      label: 'Send text',
                                      icon: LucideIcons.arrowUp,
                                      color: c.bg,
                                      fill: c.text,
                                      action: _pending
                                          ? null
                                          : () => _run(() async {
                                              final text = _text.text.trim();
                                              if (text.isEmpty) return;
                                              await s.sendText(text);
                                              if (mounted &&
                                                  _text.text.trim() == text) {
                                                _text.clear();
                                              }
                                            }),
                                    ),
                                  ],
                                  _control(
                                    context,
                                    label: _live ? 'End call' : 'Close',
                                    icon: _live
                                        ? LucideIcons.square
                                        : LucideIcons.x,
                                    color: c.bg,
                                    fill: c.text,
                                    action: _pending
                                        ? null
                                        : _live
                                        ? () => _run(s.stop)
                                        : _leave,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // iOS disables its native back gesture when PopScope cannot pop.
            // Keep a narrow explicit edge gesture so it asks rather than discards.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 20,
              child: GestureDetector(
                key: const Key('voice-back-edge'),
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _backDrag = 0,
                onHorizontalDragUpdate: (details) =>
                    _backDrag += details.delta.dx,
                onHorizontalDragEnd: (_) {
                  if (_backDrag > 60) unawaited(_leave());
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _control(
    BuildContext context, {
    required String label,
    required IconData icon,
    required Color color,
    required Color fill,
    required VoidCallback? action,
  }) => SizedBox.square(
    dimension: 44,
    child: IconButton(
      tooltip: label,
      onPressed: action,
      padding: const EdgeInsets.all(6),
      icon: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: color),
      ),
    ),
  );
}

/// Direct Flutter canvas port of pi-voice/ui/app.js draw(), including its 80px
/// canvas, cobalt gradient, clipped white cloud and four blurred path layers.
class VoiceCloud extends StatefulWidget {
  const VoiceCloud({super.key, required this.phase, required this.level});
  final VoiceLivePhase phase;
  final double level;
  @override
  State<VoiceCloud> createState() => _VoiceCloudState();
}

class _VoiceCloudState extends State<VoiceCloud>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  )..repeat();
  double _level = 0;
  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final off =
        widget.phase == VoiceLivePhase.ended ||
        widget.phase == VoiceLivePhase.error;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: '${widget.phase.name} voice activity',
      child: SizedBox.square(
        dimension: 80,
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final activity = off ? 0.0 : widget.level.clamp(0.0, 1.0);
            _level += (activity - _level) * (activity > _level ? .24 : .085);
            return Opacity(
              opacity: off ? .35 : 1,
              child: CustomPaint(
                painter: _CloudPainter(
                  time: reduced || off ? 0 : _clock.value * 60000,
                  level: _level,
                  reduced: reduced,
                  off: off,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CloudPainter extends CustomPainter {
  const _CloudPainter({
    required this.time,
    required this.level,
    required this.reduced,
    required this.off,
  });
  final double time;
  final double level;
  final bool reduced;
  final bool off;
  @override
  void paint(Canvas canvas, Size size) {
    final t = time / 1800;
    final breath = reduced || off ? 0.0 : math.sin(time / 1500) * 1.1;
    final scale = (25 + level * (reduced ? 4 : 12) + breath) / 25;
    canvas.save();
    canvas.translate(40, 40);
    canvas.scale(scale);
    canvas.translate(-28, -28);
    canvas.clipPath(
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(28, 28), radius: 25)),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 56, 56),
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(6, 3),
          const Offset(48, 55),
          piVoiceCloudBlue,
          [0, .6, 1],
        ),
    );
    canvas.translate(28, 30);
    canvas.rotate(math.sin(t * .45) * .5 - .28);
    canvas.translate(-28, -30);
    for (var layer = 0; layer < 4; layer++) {
      final y = 33 + math.sin(t * .8) * (5 + level * 7) + layer * 2;
      final path = Path()
        ..moveTo(-12, y + 8)
        ..cubicTo(5, y + 9, 7 + math.sin(t) * 5, y - 14 - level * 8, 24, y - 4)
        ..cubicTo(39, y + 7, 40, y - 10 + math.cos(t) * 4, 68, y - 3)
        ..lineTo(68, 70)
        ..lineTo(-12, 70)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 - layer * .7)
          ..shader = ui.Gradient.linear(Offset(0, y - 10), Offset(0, y + 25), [
            piVoiceCloudWhite.withValues(alpha: .35 + layer * .12),
            piVoiceCloudWhite.withValues(alpha: .08),
          ]),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.time != time || old.level != level || old.off != off;
}
