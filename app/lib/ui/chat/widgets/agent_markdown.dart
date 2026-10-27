import 'dart:async';

import 'package:app/domain/entities/draft_panel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/artifact_dialog.dart';
import 'package:provider/provider.dart';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/unordered_ordered_list.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Plan/32b — renders the agent's Markdown reply (GFM + code) themed to the
/// app's dark/mono look. Links open in the system browser (url_launcher);
/// code blocks get a copy button. Tolerant of partial markdown so it can also
/// drive the live streaming bubble.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key, this.selectable = false});

  final String data;

  /// Wrap in a [SelectionArea] so prose/code can be selected + copied. Off for
  /// the streaming bubble (content changes every frame).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final markdown = GptMarkdown(
      data,
      style: typo.mono,
      unOrderedListBuilder: (context, child, config) => UnorderedListView(
        bulletColor: colors.codeAccent,
        padding: 7,
        spacing: 10,
        bulletSize: 0.3 * (config.style?.fontSize ?? 13),
        textDirection: config.textDirection,
        child: child,
      ),
      onLinkTap: (url, _) => _openLink(context, url),
      // Inline `code` — subtle highlight, keeps the baseline.
      highlightBuilder: (context, text, style) =>
          Text(text, style: typo.mono.copyWith(color: colors.codeAccent)),
      // Fenced ``` blocks — dark card + copy button.
      codeBuilder: (context, name, code, closed) {
        final panel = DraftPanel.parse(name, code);
        return panel == null
            ? _CodeBlock(language: name, code: code)
            : _DraftCard(panel: panel);
      },
    );
    // Weiss Labs: Pi's desktop markdown palette (gold headings, blue links).
    TextStyle h(double size) => typo.mono.copyWith(
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: colors.heading,
    );
    final themed = GptMarkdownTheme(
      gptThemeData: GptMarkdownThemeData(
        brightness: Theme.of(context).brightness,
        h1: h(18),
        h2: h(16),
        h3: h(15),
        h4: h(14),
        h5: h(14),
        h6: h(14),
        linkColor: colors.link,
        linkHoverColor: colors.link,
        hrLineColor: colors.border,
      ),
      child: markdown,
    );
    return selectable ? SelectionArea(child: themed) : themed;
  }

  static Future<void> _openLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (uri.scheme == 'file') {
      final vm = context.read<ChatViewModel>();
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ArtifactDialog(url: url, viewModel: vm),
      );
      return;
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      messenger?.showSnackBar(
        const SnackBar(content: Text('This link type is not supported.')),
      );
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.panel});
  final DraftPanel panel;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('mobile-draft-card'),
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
    decoration: BoxDecoration(
      color: context.colors.codeBg,
      border: Border.all(color: context.colors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                panel.title ?? 'Draft preview',
                style: context.typo.monoSmall,
              ),
            ),
            _CopyButton(code: panel.source),
          ],
        ),
        Text(panel.content, softWrap: true, style: context.typo.sansBody),
      ],
    ),
  );
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10,
                      color: colors.muted,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                _CopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text(
              code,
              style: typo.mono.copyWith(color: colors.gaugeOk, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      key: const Key('code-copy'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      iconSize: 15,
      splashRadius: 16,
      tooltip: 'Copy code',
      onPressed: _copy,
      icon: Icon(
        _copied ? LucideIcons.check : LucideIcons.copy,
        color: _copied ? colors.success : colors.muted,
      ),
    );
  }
}
