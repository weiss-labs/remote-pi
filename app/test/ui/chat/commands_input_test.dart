import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:app/ui/chat/commands/viewmodels/commands_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'commands_viewmodel_test.dart' show FakePaneCommands;

void main() {
  setUpAll(() async {
    if (Platform.environment['RP_REVIEW_DIR'] == null) return;
    final mono = FontLoader(kMonoFamily);
    for (final weight in ['Regular', 'Light', 'Medium', 'Bold']) {
      mono.addFont(rootBundle.load('assets/fonts/SF-Mono-$weight.otf'));
    }
    await mono.load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final family = entry['family'] as String;
      if (family == kMonoFamily) continue;
      final loader = FontLoader(family);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
  });
  testWidgets(
    'narrow phone command list fits above keyboard with 44pt controls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final source = FakePaneCommands();
      final vm = CommandsViewModel(source);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Paired pane')),
              body: Align(
                alignment: Alignment.bottomCenter,
                child: InputBar(
                  commands: vm,
                  onSend: (_) => fail('No chat fallback'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Run')).height,
        greaterThanOrEqualTo(44),
      );
      expect(find.text('Complete sign-in on your Mac.'), findsOneWidget);
      final directory = Platform.environment['RP_REVIEW_DIR'];
      if (directory != null) {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final capture = await boundary.toImage(pixelRatio: 2);
          final bytes = await capture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/slash-commands-phone.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          capture.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      await source.changes.close();
    },
  );
  testWidgets(
    'slash suggestions select without running, Run is explicit and never chat',
    (tester) async {
      final source = FakePaneCommands();
      final vm = CommandsViewModel(source);
      final messages = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: InputBar(commands: vm, onSend: messages.add),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '/com');
      await tester.pumpAndSettle();
      expect(find.text('/compact'), findsOneWidget);
      expect(find.textContaining('Compact this session'), findsOneWidget);
      await tester.tap(find.text('/compact'));
      await tester.pumpAndSettle();
      expect(source.runs, isEmpty);
      expect(messages, isEmpty);
      final run = find.widgetWithText(FilledButton, 'Run');
      expect(tester.getSize(run).height, greaterThanOrEqualTo(44));
      source.pendingRun = Completer<void>();
      await tester.tap(run);
      await tester.pump();
      expect(find.text('Dispatching /compact…'), findsOneWidget);
      expect(source.runs.length, 1);
      expect(messages, isEmpty);
      source.pendingRun!.complete();
      await tester.pumpAndSettle();
      expect(find.text('PANE COMMANDS'), findsNothing);
      expect(
        find.text('Accepted by pane. Watch the conversation for results.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'normal text');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(messages, ['normal text']);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      await source.changes.close();
    },
  );
  testWidgets(
    'slash with no backend and disabled command cannot become ordinary chat',
    (tester) async {
      final messages = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: InputBar(onSend: messages.add)),
        ),
      );
      await tester.enterText(find.byType(TextField), '/login');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(messages, isEmpty);
      expect(
        find.text('Commands are unavailable. Nothing was sent.'),
        findsOneWidget,
      );
      expect(
        find.byType(TextField).evaluate().single.widget is TextField,
        true,
      );
    },
  );
}
