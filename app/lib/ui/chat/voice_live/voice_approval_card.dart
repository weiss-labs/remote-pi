import 'dart:async';
import 'dart:ui' as ui;

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
  // Draft attachments must be on screen before review counts: images load
  // first; anything that can't be previewed here holds approval (Pi Voice
  // rule: missing attachment previews never authorize a send).
  final Set<String> _loaded = {};
  bool _attachmentBlocked = false;

  bool get _attachmentsReady {
    final d = widget.draft;
    if (d == null) return true;
    return d.attachments.every((a) => _loaded.contains(a.id));
  }

  void _onAttachment(String id, bool ok) {
    if (!mounted) return;
    setState(() {
      if (ok) {
        _loaded.add(id);
      } else {
        _attachmentBlocked = true;
      }
    });
    _scheduleVisibility();
  }

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
      _loaded.clear();
      _attachmentBlocked = false;
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
        _attachmentBlocked ||
        !_attachmentsReady ||
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
    final blocked = draft != null && (!draft.eligible || draft.error != null || _attachmentBlocked);
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
                        _AttachmentPreview(
                          session: widget.session,
                          draft: draft,
                          attachment: att,
                          onResult: (ok) => _onAttachment(att.id, ok),
                        ),
                      ],
                      if (blocked) ...[
                        const SizedBox(height: 14),
                        Text(
                          draft.error ??
                              (_attachmentBlocked
                                  ? 'An attachment can\'t be previewed here, so approval is held. Review it in the original Pi chat.'
                                  : 'Voice cannot approve this draft. Approve it in the original Pi chat.'),
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
          if (draft != null && !_seen && !blocked)
            Text(
              _attachmentsReady ? 'Read to the end to enable sending.' : 'Loading attachments…',
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
  const _AttachmentPreview({
    required this.session,
    required this.draft,
    required this.attachment,
    required this.onResult,
  });
  final VoiceLiveSession session;
  final VoiceDraft draft;
  final VoiceDraftAttachment attachment;

  /// true once the preview is rendered; false if it can't be shown here.
  final ValueChanged<bool> onResult;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  // Decoded before it counts: a corrupt or unsupported image holds approval,
  // and the picture is laid out at full size before review can start.
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.attachment.mime.startsWith('image/')) {
      // PDFs and other files have no in-app preview yet.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResult(false));
      return;
    }
    unawaited(_decode());
  }

  Future<void> _decode() async {
    try {
      final data = await widget.session.attachment(widget.draft.id, widget.attachment.id);
      final codec = await ui.instantiateImageCodec(data.bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _image = frame.image);
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResult(true));
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onResult(false);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final caption = Text(
      '${a.name} · ${(a.size / 1024).ceil()} KB',
      style: context.typo.monoSmall,
    );
    if (!a.mime.startsWith('image/')) return caption;
    final img = _image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (img != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: AspectRatio(
                aspectRatio: img.width / img.height,
                child: RawImage(image: img, fit: BoxFit.contain),
              ),
            ),
          )
        else if (_failed)
          Text('Preview unavailable', style: context.typo.monoSmall)
        else
          const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        const SizedBox(height: 6),
        caption,
      ],
    );
  }
}
