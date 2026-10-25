import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:app/ui/core/themes/themes.dart';

import 'voice_live_session.dart';

/// A new id/hash must create a new card. Visibility never carries across drafts.
class VoiceApprovalCard extends StatefulWidget {
  const VoiceApprovalCard({
    super.key,
    required this.approval,
    required this.session,
  });
  final VoiceApproval approval;
  final VoiceLiveSession session;

  @override
  State<VoiceApprovalCard> createState() => _VoiceApprovalCardState();
}

class _VoiceApprovalCardState extends State<VoiceApprovalCard> {
  final _scroll = ScrollController();
  double _seenThrough = 0;
  bool _seen = false;
  bool _markingSeen = false;
  bool _pending = false;
  bool _resolved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleVisibility);
    _scheduleVisibility();
  }

  @override
  void didUpdateWidget(VoiceApprovalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.approval.id != widget.approval.id ||
        oldWidget.approval.draft?.hash != widget.approval.draft?.hash) {
      _seenThrough = 0;
      _seen = false;
      _markingSeen = false;
      _pending = false;
      _resolved = false;
      _error = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scheduleVisibility();
    }
  }

  void _scheduleVisibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
  }

  bool _isCurrent(VoiceApproval approval) =>
      widget.approval.id == approval.id &&
      widget.approval.draft?.hash == approval.draft?.hash;

  Future<void> _checkVisibility() async {
    if (!mounted ||
        _seen ||
        _markingSeen ||
        !_scroll.hasClients ||
        widget.approval.draft == null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final p = _scroll.position;
    // Only count contiguous viewports. Jumping to the bottom cannot certify
    // skipped text. The bounded card is always fully inside the page viewport.
    if (p.pixels > _seenThrough + 1) return;
    _seenThrough = (p.pixels + p.viewportDimension).clamp(
      _seenThrough,
      double.infinity,
    );
    if (_seenThrough + 1 < p.maxScrollExtent + p.viewportDimension) return;
    final approval = widget.approval;
    _markingSeen = true;
    try {
      await widget.session.draftSeen(approval.id, approval.draft!.hash);
      if (!mounted || !_isCurrent(approval)) return;
      setState(() {
        _seen = true;
        _error = null;
      });
    } catch (_) {
      if (mounted && _isCurrent(approval)) {
        setState(
          () => _error = 'Could not confirm draft review. Scroll to retry.',
        );
      }
    } finally {
      if (mounted && _isCurrent(approval)) _markingSeen = false;
    }
  }

  Future<void> _approve(bool allow) async {
    if (_pending || _resolved) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    final approval = widget.approval;
    try {
      await widget.session.approve(approval.id, allow);
      if (mounted && _isCurrent(approval)) {
        setState(() => _resolved = true);
      }
    } catch (_) {
      if (mounted && _isCurrent(approval)) {
        setState(() => _error = 'Could not send decision. Try again.');
      }
    } finally {
      if (mounted && _isCurrent(approval)) {
        setState(() => _pending = false);
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.approval;
    final draft = a.draft;
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            draft == null ? 'Allow this operation?' : 'Review exact draft',
            style: context.typo.sansBody.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                key: const Key('voice-approval-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(a.toolName, style: context.typo.monoSmall),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: c.inputFill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(a.args),
                        style: context.typo.mono,
                      ),
                    ),
                    if (draft != null) ...[
                      const SizedBox(height: 18),
                      SelectableText(
                        'To: ${draft.to.join(', ')}\nCc: ${draft.cc.join(', ')}\nSubject: ${draft.subject}',
                        style: context.typo.sansBody.copyWith(fontSize: 13),
                      ),
                      const SizedBox(height: 18),
                      Divider(color: c.border),
                      const SizedBox(height: 12),
                      SelectableText(
                        draft.body,
                        style: context.typo.sansBody.copyWith(height: 1.7),
                      ),
                      const SizedBox(height: 18),
                      SelectableText(
                        'Attachments: ${draft.attachments.isEmpty ? 'None' : draft.attachments.join('\n')}',
                        style: context.typo.sansBody.copyWith(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (draft != null && !_seen)
            Text(
              'Read to the end to enable sending.',
              style: context.typo.monoSmall,
            ),
          if (_error != null)
            Text(
              _error!,
              style: context.typo.monoSmall.copyWith(color: c.error),
            ),
          if (_resolved)
            Text(
              'Decision sent',
              style: context.typo.monoSmall.copyWith(color: c.success),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.text,
                      backgroundColor: c.inputFill,
                      side: BorderSide(color: c.border),
                      textStyle: context.typo.sansBody.copyWith(fontSize: 13),
                    ),
                    onPressed: _pending ? null : () => _approve(false),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: draft == null ? 1 : 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.text,
                      foregroundColor: c.bg,
                      textStyle: context.typo.sansBody.copyWith(fontSize: 13),
                    ),
                    onPressed: _pending || (draft != null && !_seen)
                        ? null
                        : () => _approve(true),
                    child: Text(
                      draft == null ? 'Allow once' : 'Send this exact draft',
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
