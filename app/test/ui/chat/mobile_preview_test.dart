import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:app/domain/entities/draft_panel.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/system_font.dart';

const panel =
    '''┌──────────────────────────────────────────────────────────────┐
│ EMAIL DRAFT                                                  │
├─────────┬────────────────────────────────────────────────────┤
│ To      │ Synthetic Recipient <long-recipient@example.invalid> │
│ Cc      │ Another Synthetic Recipient <review@example.invalid> │
│ Subject │ A mobile draft with complete readable content       │
├─────────┴────────────────────────────────────────────────────┤
│ Hello,                                                       │
│                                                              │
│ This synthetic paragraph is deliberately longer than a phone screen, so the draft must wrap without hiding its final words. │
│                                                              │
│ The attachment is ready for review. Nothing is sent.         │
│ Zach                                                         │
└──────────────────────────────────────────────────────────────┘''';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadSystemMono();
    await loadSystemSans();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.where(
      (e) => (e['family'] as String).contains('Lucide'),
    )) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  });
  test('recognition is conservative; source is preserved exactly', () {
    final parsed = DraftPanel.parse('text', panel)!;
    expect(parsed.source, panel);
    expect(parsed.title, 'EMAIL DRAFT');
    expect(parsed.recipient!.value, contains('long-recipient@example.invalid'));
    expect(parsed.body, endsWith('Nothing is sent.\nZach'));
    expect(DraftPanel.parse('dart', panel), isNull);
    expect(DraftPanel.parse('text', 'regular code'), isNull);
    // Unboxed text after the panel is a footer; nothing is dropped.
    final ambiguous = '$panel\nextra unboxed content';
    expect(DraftPanel.parse('text', ambiguous)!.footer, [
      'extra unboxed content',
    ]);
  });
  final fixtures = {
    'email': panel,
    'whatsapp': File(
      'test/ui/chat/fixtures/draft-panels/whatsapp-attachments.txt',
    ).readAsStringSync().trim(),
    'imessage': File(
      'test/ui/chat/fixtures/draft-panels/imessage-steps.txt',
    ).readAsStringSync().trim(),
  };
  for (final MapEntry(key: channel, value: panel) in fixtures.entries) {
    for (final width in [320.0, 390.0, 440.0]) {
      testWidgets(
        '$channel draft wraps at $width and regular code remains scrollable',
        (tester) async {
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildDarkTheme(),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: AgentMarkdown(
                        '```text\n$panel\n```\n\n```dart\nfinal unchangedCode = "this remains a normal horizontally scrolling code block";\n```',
                        selectable: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final card = find.byKey(const Key('mobile-draft-card'));
          expect(card, findsOneWidget);
          expect(tester.getSize(card).width, lessThanOrEqualTo(width - 32));
          expect(
            find.descendant(
              of: card,
              matching: find.byType(SingleChildScrollView),
            ),
            findsNothing,
          );
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
            findsOneWidget,
          );
          final output = Platform.environment['RP_REVIEW_DIR'];
          if (output != null) {
            final boundary =
                key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/draft-$channel-${width.toInt()}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          await tester.tap(
            find.descendant(
              of: card,
              matching: find.byKey(const Key('code-copy')),
            ),
          );
          await tester.pump();
          expect(copied?.trim(), panel);
          await tester.pumpWidget(const SizedBox());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        },
      );
    }
  }
  testWidgets('body links: literal text stays, trailing punctuation excluded', (
    tester,
  ) async {
    final source = File(
      'test/ui/chat/fixtures/draft-panels/email-boundaries.txt',
    ).readAsStringSync().trim();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentMarkdown('```text\n$source\n```', selectable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('mobile-draft-card'));
    // Every character of the message is on the card, markdown delimiters too.
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining(
          'Use [portal](https://example.invalid/private) or '
          'https://example.invalid/a_(b) today.',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    final body = tester.widget<RichText>(
      find.descendant(
        of: card,
        matching: find.textContaining('Use [portal]', findRichText: true),
      ),
    );
    final links = <String>[];
    body.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) links.add(span.text!);
      return true;
    });
    expect(links, [
      '[portal](https://example.invalid/private)',
      'https://example.invalid/a_(b)',
    ]);
    // Tapping the bare URL opens it without the trailing period (no platform
    // launcher in tests, so the failure snackbar echoes the exact url).
    final span = body.text.getSpanForPosition(
      TextPosition(offset: body.text.toPlainText().indexOf('a_(b)')),
    );
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      launched.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    ((span as TextSpan).recognizer as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    expect(launched, ['https://example.invalid/a_(b)']);

    // Markdown destinations keep balanced parentheses too.
    final unicode = File(
      'test/ui/chat/fixtures/draft-panels/whatsapp-unicode.txt',
    ).readAsStringSync().trim();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentMarkdown('```text\n$unicode\n```', selectable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('mobile-draft-card')),
        matching: find.textContaining('See [the doc]', findRichText: true),
      ),
    );
    launched.clear();
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        expect(span.text, '[the doc](https://example.invalid/a_(b))');
        (span.recognizer as TapGestureRecognizer).onTap!();
      }
      return true;
    });
    await tester.pumpAndSettle();
    expect(launched, ['https://example.invalid/a_(b)']);
  });
  testWidgets('image bubble opens zoomable in-app image', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAIAAAAC64paAAAAGklEQVR4nGMwTptJNmIY1TyqeVTzqOaB1QwA8FLeMFLukKAAAAAASUVORK5CYII=';
    // Decode only synthetic bytes; no desktop or third-party image request.
    expect(base64Decode(png), isNotEmpty);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: ImageBubble(
            image: MessageImage(mime: 'image/png', data: png),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(base64Decode(png)),
        tester.element(find.byType(Image).first),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Image preview'), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
