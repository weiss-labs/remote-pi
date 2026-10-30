// Plan/75 — quiet mode widgets. Presentation only: nothing here writes to
// the transcript cache or sends anything to the Mac. Styled like the
// running-tool strip (toolPendingBg, Menlo) so the rows read as part of
// Pi's own chrome rather than a second UI.

import 'dart:async';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/quiet/quiet_presentation.dart';
import 'package:app/ui/chat/quiet/quiet_transcript.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/artifact_dialog.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

const _frames = ['●··', '·●·', '··●', '·●·'];

TextStyle _rowStyle(BuildContext context, {Color? color, FontWeight? weight}) =>
    TextStyle(
      fontFamily: kMonoFamily,
      fontSize: 12,
      height: 1.35,
      color: color ?? context.colors.text,
      fontWeight: weight,
    );

/// The one live status: a four-frame moving dot every 180 ms (same frames
/// and cadence as Pi's working indicator on the Mac) beside plain language.
class QuietStatusLine extends StatefulWidget {
  const QuietStatusLine({super.key, required this.label});
  final String label;

  @override
  State<QuietStatusLine> createState() => _QuietStatusLineState();
}

class _QuietStatusLineState extends State<QuietStatusLine> {
  Timer? _timer;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 180), (_) {
      if (mounted) setState(() => _frame = (_frame + 1) % _frames.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      key: const Key('quiet-status'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      color: colors.toolPendingBg,
      child: Row(
        children: [
          Text(
            _frames[_frame],
            key: const Key('quiet-status-dots'),
            style: _rowStyle(context, color: colors.working),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _rowStyle(context, color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Worked for 2m 4s · 6 steps". Tap the header to fold/unfold; tap a step
/// to open its preview.
class QuietWorkRow extends StatelessWidget {
  const QuietWorkRow({
    super.key,
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.onOpenStep,
  });
  final QuietGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(ToolEvent tool, QuietView view) onOpenStep;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      key: Key('quiet-group-${group.steps.first.id}'),
      width: double.infinity,
      color: colors.toolPendingBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: Key('quiet-group-toggle-${group.steps.first.id}'),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 14,
                    color: colors.muted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      group.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _rowStyle(context, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            for (var i = 0; i < group.steps.length; i++)
              _StepLine(
                tool: group.steps[i],
                view: group.views[i],
                onTap: () => onOpenStep(group.steps[i], group.views[i]),
              ),
          if (expanded) const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({
    required this.tool,
    required this.view,
    required this.onTap,
  });
  final ToolEvent tool;
  final QuietView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pending =
        tool.status == ToolEventStatus.pending ||
        tool.status == ToolEventStatus.allowed;
    final (marker, color) = view.failed
        ? ('✗', colors.warning)
        : pending
        ? ('·', colors.muted)
        : ('✓', colors.success);
    return InkWell(
      key: Key('quiet-step-${tool.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 6, 12, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 14,
              child: Text(marker, style: _rowStyle(context, color: color)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                view.label,
                style: _rowStyle(
                  context,
                  color: view.failed ? colors.warning : colors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line for a human action or an incoming pane message; tap → preview.
class QuietNoticeLine extends StatelessWidget {
  const QuietNoticeLine({
    super.key,
    required this.label,
    required this.prominent,
    required this.onTap,
  });
  final String label;
  final bool prominent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = prominent ? colors.warning : colors.muted;
    return Material(
      color: colors.toolPendingBg,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  prominent
                      ? LucideIcons.triangleAlert
                      : LucideIcons.messageSquare,
                  size: 13,
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: _rowStyle(
                    context,
                    color: color,
                    weight: prominent ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An exact-text draft/approval panel inside a tool step: never folded,
/// never summarised. Shows the complete arguments and output.
class QuietAttentionCard extends StatelessWidget {
  const QuietAttentionCard({super.key, required this.tool, required this.view});
  final ToolEvent tool;
  final QuietView view;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = [
      if (hasDraftPanel(tool.args)) prettyJson(tool.args),
      resultText(tool.result),
      if (tool.error != null) sanitize(tool.error!),
    ].where((s) => s.trim().isNotEmpty).join('\n\n');
    return Container(
      key: Key('quiet-attention-${tool.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: colors.toolPendingBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.triangleAlert, size: 13, color: colors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  view.label,
                  style: _rowStyle(
                    context,
                    color: colors.warning,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(body, style: context.typo.mono),
        ],
      ),
    );
  }
}

/// Small top-bar control: "Quiet" ⇄ "Full details".
class QuietTogglePill extends StatelessWidget {
  const QuietTogglePill({super.key, required this.quiet, required this.onTap});
  final bool quiet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      toggled: quiet,
      label: quiet
          ? 'Quiet view, tap for full details'
          : 'Full details, tap for quiet view',
      child: InkWell(
        key: const Key('quiet-toggle'),
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                quiet ? LucideIcons.eyeOff : LucideIcons.eye,
                size: 12,
                color: colors.muted,
              ),
              const SizedBox(width: 5),
              Text(
                quiet ? 'Quiet' : 'Full details',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 10,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// In-app preview of one step: the full command/arguments, the complete
/// output, and any Mac image paths it named (opened through the paired
/// pane's authenticated artifact transport). Local UI state only.
Future<void> showQuietPreview(
  BuildContext context, {
  required String title,
  required ToolEvent tool,
}) {
  // The sheet's own context sits above the chat providers; capture now.
  final vm = context.read<ChatViewModel>();
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: context.colors.bg,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: QuietPreviewSheet(title: title, tool: tool, viewModel: vm),
    ),
  );
}

class QuietPreviewSheet extends StatelessWidget {
  const QuietPreviewSheet({
    super.key,
    required this.title,
    required this.tool,
    required this.viewModel,
  });
  final String title;
  final ToolEvent tool;
  final ChatViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final output = resultText(tool.result);
    final error = tool.error == null ? '' : sanitize(tool.error!);
    final images = [
      ...toolImageUrls(tool.result),
      for (final path in imagePaths('$output\n$error'))
        Uri.file(path).toString(),
    ];
    final status = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => 'running',
      ToolEventStatus.completed => 'done',
      ToolEventStatus.failed => 'failed',
      ToolEventStatus.denied => 'denied',
      ToolEventStatus.expired => 'expired',
    };
    final heading = _rowStyle(
      context,
      color: colors.muted,
      weight: FontWeight.w600,
    );
    final mono = context.typo.mono.copyWith(fontSize: 12);
    // Complete text, in 100-line blocks: lazy enough for a multi-megabyte
    // log (a jump to the end lays out blocks, not every line) while
    // SelectionArea still copies across them.
    Iterable<Widget> blocks(String text) sync* {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i += 100) {
        yield Text(
          lines.sublist(i, (i + 100).clamp(0, lines.length)).join('\n'),
          style: mono,
        );
      }
    }

    final lines = <Widget>[
      Text('ARGUMENTS', style: heading),
      const SizedBox(height: 4),
      ...blocks(prettyJson(tool.args)),
      const SizedBox(height: 16),
      Text('OUTPUT', style: heading),
      const SizedBox(height: 4),
      if (output.isEmpty && images.isEmpty)
        Text('No text output', style: mono.copyWith(color: colors.muted))
      else
        ...blocks(output),
      if (error.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('ERROR', style: heading.copyWith(color: colors.warning)),
        const SizedBox(height: 4),
        ...blocks(error),
      ],
      if (images.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('IMAGES', style: heading),
        const SizedBox(height: 4),
        for (final (i, url) in images.indexed)
          _ImageChip(
            path: url.startsWith('pi-tool-image:')
                ? 'Image ${i + 1}'
                : Uri.parse(url).toFilePath(),
            onTap: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => ArtifactDialog(url: url, viewModel: viewModel),
            ),
          ),
      ],
      const SizedBox(height: 24),
    ];
    return Column(
      key: const Key('quiet-preview'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tool.tool} · $status',
                      style: _rowStyle(context, color: colors.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('quiet-preview-close'),
                tooltip: 'Close',
                icon: Icon(LucideIcons.x, size: 18, color: colors.muted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.border),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              itemCount: lines.length,
              itemBuilder: (_, i) => lines[i],
            ),
          ),
        ),
      ],
    );
  }
}

class _ImageChip extends StatelessWidget {
  const _ImageChip({required this.path, required this.onTap});
  final String path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        key: Key('quiet-image-$path'),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.image, size: 14, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  path.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _rowStyle(context, color: colors.text),
                ),
              ),
              Text('Open', style: _rowStyle(context, color: colors.accent)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet transcript: same reversed list as the full view, with folded
/// groups, one-line notices, full draft cards and the live status line at
/// the bottom while a run is active.
class QuietMessageList extends StatefulWidget {
  const QuietMessageList({
    super.key,
    required this.messages,
    required this.streaming,
    required this.working,
  });
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final bool working;

  @override
  State<QuietMessageList> createState() => _QuietMessageListState();
}

class _QuietMessageListState extends State<QuietMessageList> {
  final _expanded = <String>{};

  void _open(BuildContext context, ToolEvent tool, String title) =>
      unawaited(showQuietPreview(context, title: title, tool: tool));

  @override
  Widget build(BuildContext context) {
    final items = foldQuiet(widget.messages, working: widget.working);
    final tail = <Widget>[
      if (widget.streaming != null)
        KeyedSubtree(
          key: const ValueKey('streaming'),
          child: StreamingBubble(widget.streaming!),
        ),
      if (widget.working)
        KeyedSubtree(
          key: const ValueKey('quiet-status-row'),
          child: QuietStatusLine(label: liveStatusLabel(widget.messages)),
        ),
    ];
    final itemCount = items.length + tail.length;
    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        // Index 0 = bottom = newest; the tail (streaming, status) sits last.
        if (i < tail.length) return tail[tail.length - 1 - i];
        final item = items[items.length - 1 - (i - tail.length)];
        return KeyedSubtree(
          key: ValueKey(item.key),
          child: switch (item) {
            QuietPass(:final message) => switch (message) {
              UserMsg() => UserBubble(message),
              AssistantMsg() => AssistantBubble(message),
              CompactionMsg() => CompactionBubble(message),
              ToolEvent() => const SizedBox.shrink(),
            },
            QuietGroup() => QuietWorkRow(
              group: item,
              expanded: _expanded.contains(item.key),
              onToggle: () => setState(() {
                if (!_expanded.remove(item.key)) _expanded.add(item.key);
              }),
              onOpenStep: (tool, view) => _open(context, tool, view.label),
            ),
            QuietProminent(:final tool, :final view) =>
              view.draft
                  ? QuietAttentionCard(tool: tool, view: view)
                  : QuietNoticeLine(
                      key: Key('quiet-notice-${tool.id}'),
                      label: view.label,
                      prominent: true,
                      onTap: () => _open(context, tool, view.label),
                    ),
            QuietNotice(:final tool, :final view, :final label) =>
              QuietNoticeLine(
                key: Key('quiet-notice-${tool.id}'),
                label: label,
                prominent: view.prominent,
                onTap: () => _open(context, tool, label),
              ),
          },
        );
      },
    );
  }
}
