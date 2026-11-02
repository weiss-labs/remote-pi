import 'dart:async';

import 'package:app/domain/entities/draft_panel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/artifact_dialog.dart';
import 'package:provider/provider.dart';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/gestures.dart';
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
    // Markdown allows `[text](<url>)`; gpt_markdown passes the brackets through.
    if (url.startsWith('<') && url.endsWith('>')) {
      url = url.substring(1, url.length - 1);
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('This link could not be opened.')),
      );
      return;
    }
    if (uri.scheme == 'file') {
      final vm = context.read<ChatViewModel>();
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ArtifactDialog(url: url, viewModel: vm),
      );
      return;
    }
    if (!const {'https', 'http', 'mailto', 'tel'}.contains(uri.scheme)) {
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

/// Platform sans for draft cards (the app theme's default family is Menlo).
const String kCardSansFamily = '.SF Pro Text';

/// A draft panel laid out for a phone: channel header, recipient first,
/// machine ids demoted, the message body as the focus. Every field and every
/// character of the body stays visible; copy still copies the exact source.
class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.panel});
  final DraftPanel panel;

  static const _channelName = {
    DraftChannel.whatsapp: 'WhatsApp',
    DraftChannel.email: 'Email',
    DraftChannel.imessage: 'iMessage',
    DraftChannel.sms: 'SMS',
  };
  static const _channelIcon = {
    DraftChannel.whatsapp: LucideIcons.messageCircle,
    DraftChannel.email: LucideIcons.mail,
    DraftChannel.imessage: LucideIcons.messageSquare,
    DraftChannel.sms: LucideIcons.smartphone,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final tint = switch (panel.channel) {
      DraftChannel.whatsapp => colors.success,
      DraftChannel.email => colors.accent,
      DraftChannel.imessage || DraftChannel.sms => colors.link,
    };
    final label = TextStyle(
      fontFamily: kMonoFamily,
      fontSize: 10,
      height: 1.4,
      color: colors.muted2,
      letterSpacing: 0.8,
    );
    // ThemeData.fontFamily is Menlo and sansBody's family is null, so it would
    // inherit mono; name the platform sans like pi_voice_theme does.
    final sans = typo.sansBody.copyWith(
      fontFamily: kCardSansFamily,
      fontFamilyFallback: const ['Helvetica Neue', 'sans-serif'],
    );
    final value = sans.copyWith(fontSize: 13, height: 1.35);
    final machine = typo.monoSmall.copyWith(color: colors.muted2);
    final suffix = panel.titleSuffix;
    final recipient = panel.recipient;
    final others = panel.fields.where((f) => f != recipient).toList();

    Widget field(DraftField f) => Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(f.label.toUpperCase(), style: label),
            ),
          ),
          Expanded(
            child: _LinkedText(
              f.value,
              style: f.isMachine ? machine : value,
              linkColor: colors.link,
            ),
          ),
        ],
      ),
    );

    Widget recipientBlock(DraftField f) {
      final (primary, ids) = DraftPanel.splitMachineIds(f.value);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.label.toUpperCase(), style: label),
          const SizedBox(height: 2),
          Text(
            primary,
            style: sans.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (ids.isNotEmpty) Text(ids.join('\n'), style: machine),
        ],
      );
    }

    return Container(
      key: const Key('mobile-draft-card'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border(
          left: BorderSide(color: tint, width: 3),
          top: BorderSide(color: colors.border),
          right: BorderSide(color: colors.border),
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: colors.surface,
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 0),
            child: Row(
              children: [
                Icon(_channelIcon[panel.channel], size: 14, color: tint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: _channelName[panel.channel],
                      style: sans.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tint,
                      ),
                      children: [
                        TextSpan(
                          text: '  draft · not sent',
                          style: label.copyWith(letterSpacing: 0.2),
                        ),
                        if (suffix.isNotEmpty)
                          TextSpan(
                            text: '  $suffix',
                            style: machine.copyWith(color: colors.muted),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _CopyButton(code: panel.source),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.border),
          if (panel.fallback)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                panel.body,
                softWrap: true,
                style: typo.mono.copyWith(fontSize: 11, height: 1.4),
              ),
            )
          else ...[
            if (panel.fields.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (recipient != null) recipientBlock(recipient),
                    if (recipient != null && others.isNotEmpty)
                      const SizedBox(height: 4),
                    ...others.map(field),
                  ],
                ),
              ),
            if (panel.fields.isNotEmpty)
              Divider(height: 1, thickness: 1, color: colors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: _LinkedText(
                panel.body,
                style: sans.copyWith(fontSize: 15, height: 1.45),
                linkColor: colors.link,
              ),
            ),
            if (panel.footer.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: _LinkedText(
                  panel.footer.join('\n'),
                  style: machine,
                  linkColor: colors.link,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Plain text with tappable bare URLs and `[text](url)` links. Markdown is
/// otherwise left alone so every character of a draft shows as written.
class _LinkedText extends StatefulWidget {
  const _LinkedText(this.text, {required this.style, required this.linkColor});
  final String text;
  final TextStyle style;
  final Color linkColor;

  @override
  State<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<_LinkedText> {
  // Markdown destinations may hold one level of balanced parentheses.
  static final _link = RegExp(
    r'\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|(?:https?://|mailto:)[^\s<>\]]+',
  );

  /// Bare URLs keep balanced parentheses but not trailing prose punctuation.
  static int _urlEnd(String url) {
    var end = url.length;
    while (end > 0) {
      final c = url[end - 1];
      if ('.,;:!?\'"'.contains(c)) {
        end--;
      } else if (c == ')' &&
          ')'.allMatches(url.substring(0, end)).length >
              '('.allMatches(url.substring(0, end)).length) {
        end--;
      } else {
        break;
      }
    }
    return end;
  }

  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _link.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      // The literal stays on screen (`[text](url)` included): Zach approves
      // the exact message text from this card.
      var text = m.group(0)!;
      var url = m.group(2) ?? text;
      if (m.group(2) == null) {
        final end = _urlEnd(text);
        url = text.substring(0, end);
        text = url;
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => AgentMarkdown._openLink(context, url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text,
          recognizer: recognizer,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
        ),
      );
      last = m.start + text.length;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      softWrap: true,
    );
  }
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
