import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/core/themes/themes.dart';

import 'voice_live_session.dart';

/// Either a tool Pi wants to run ("Allow once" → /approve) or a draft Pi
/// prepared ("Send this exact draft" → Pi Voice's canonical "send it", whose
/// exact-draft rules still decide). A new id/hash must create a new card.
/// Visibility never carries across drafts.
class VoiceApprovalCard extends StatefulWidget {
  const VoiceApprovalCard({
    super.key,
    this.tool,
    this.draft,
    required this.session,
    this.onDismissDraft,
  }) : assert(tool != null || draft != null);
  final VoiceToolApproval? tool;
  final VoiceDraft? draft;
  final VoiceLiveSession session;

  /// Hides the draft card here: after "Not now" (nothing is sent) or once
  /// the confirmation went to Pi Voice.
  final VoidCallback? onDismissDraft;

  String get id => tool?.id ?? draft!.id;
  String? get hash => tool == null ? draft!.hash : null;

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
    if (oldWidget.id != widget.id || oldWidget.hash != widget.hash) {
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

  bool _isCurrent(String id, String? hash) => widget.id == id && widget.hash == hash;

  Future<void> _checkVisibility() async {
    if (!mounted ||
        _seen ||
        _markingSeen ||
        !_scroll.hasClients ||
        widget.tool != null ||
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
    final draft = widget.draft!;
    _markingSeen = true;
    try {
      await widget.session.draftSeen(draft.id, draft.hash);
      if (!mounted || !_isCurrent(draft.id, draft.hash)) return;
      setState(() {
        _seen = true;
        _error = null;
      });
    } catch (_) {
      if (mounted && _isCurrent(draft.id, draft.hash)) {
        setState(
          () => _error = 'Could not confirm draft review. Scroll to retry.',
        );
      }
    } finally {
      if (mounted && _isCurrent(draft.id, draft.hash)) _markingSeen = false;
    }
  }

  Future<void> _approve(bool allow) async {
    if (_pending || _resolved) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    final id = widget.id, hash = widget.hash;
    try {
      if (widget.tool != null) {
        await widget.session.approve(id, allow);
      } else if (allow) {
        await widget.session.confirmDraft();
        widget.onDismissDraft?.call();
      } else {
        widget.onDismissDraft?.call();
      }
      if (mounted && _isCurrent(id, hash)) {
        setState(() => _resolved = true);
      }
    } catch (_) {
      if (mounted && _isCurrent(id, hash)) {
        setState(() => _error = 'Could not send decision. Try again.');
      }
    } finally {
      if (mounted && _isCurrent(id, hash)) {
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
    final tool = widget.tool;
    final draft = widget.draft;
    final c = context.colors;
    final blocked = draft != null && (!draft.eligible || draft.error != null);
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
            tool != null ? tool.title : 'Review exact draft',
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
                    if (tool != null) ...[
                      SelectableText(tool.tool, style: context.typo.monoSmall),
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
                        child: SelectableText(tool.args, style: context.typo.mono),
                      ),
                    ],
                    if (draft != null) ...[
                      SelectableText(draft.title, style: context.typo.monoSmall),
                      const SizedBox(height: 10),
                      // The complete card exactly as Pi prepared it.
                      SelectableText(
                        draft.raw,
                        style: context.typo.sansBody.copyWith(height: 1.6),
                      ),
                      for (final att in draft.attachments) ...[
                        const SizedBox(height: 14),
                        _AttachmentPreview(session: widget.session, draft: draft, attachment: att),
                      ],
                      if (blocked) ...[
                        const SizedBox(height: 14),
                        Text(
                          draft.error ?? 'Voice cannot approve this draft. Approve it in the original Pi chat.',
                          style: context.typo.monoSmall.copyWith(color: c.error),
                        ),
                      ],
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
                    child: Text(draft == null ? 'Deny' : 'Not now'),
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
                    onPressed: _pending || (draft != null && (!_seen || blocked))
                        ? null
                        : () => _approve(true),
                    child: Text(
                      draft == null
                          ? 'Allow once'
                          : draft.isApproval
                          ? 'Approve'
                          : 'Send this exact draft',
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

/// Draft attachment: image previews inline, other files by name and size.
class _AttachmentPreview extends StatefulWidget {
  const _AttachmentPreview({required this.session, required this.draft, required this.attachment});
  final VoiceLiveSession session;
  final VoiceDraft draft;
  final VoiceDraftAttachment attachment;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  Future<({Uint8List bytes, String mime})>? _load;

  @override
  void initState() {
    super.initState();
    if (widget.attachment.mime.startsWith('image/')) {
      _load = widget.session.attachment(widget.draft.id, widget.attachment.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final caption = Text(
      '${a.name} · ${(a.size / 1024).ceil()} KB',
      style: context.typo.monoSmall,
    );
    final load = _load;
    if (load == null) return caption;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder(
          future: load,
          builder: (context, snap) => snap.hasData
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(snap.data!.bytes, fit: BoxFit.contain),
                )
              : snap.hasError
              ? Text('Preview unavailable', style: context.typo.monoSmall)
              : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        const SizedBox(height: 6),
        caption,
      ],
    );
  }
}
