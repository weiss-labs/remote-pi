import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:app/domain/entities/draft_panel.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
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
│ The attachment is ready for review. Nothing is sent here.     │
│ Zach                                                         │
└──────────────────────────────────────────────────────────────┘''';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadSystemMono();
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
    expect(parsed.content, contains('long-recipient@example.invalid'));
    expect(DraftPanel.parse('dart', panel), isNull);
    expect(DraftPanel.parse('text', 'regular code'), isNull);
    final ambiguous = '$panel\nextra unboxed content';
    expect(DraftPanel.parse('text', ambiguous)!.content, ambiguous);
  });
  for (final width in [320.0, 390.0, 440.0]) {
    testWidgets('draft wraps at $width and regular code remains scrollable', (
      tester,
    ) async {
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
            child: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
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
        find.descendant(of: card, matching: find.byType(SingleChildScrollView)),
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
        find.descendant(of: card, matching: find.byKey(const Key('code-copy'))),
      );
      await tester.pump();
      expect(copied?.trim(), panel);
      final output = Platform.environment['RP_REVIEW_DIR'];
      if (output != null) {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/draft-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }
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
