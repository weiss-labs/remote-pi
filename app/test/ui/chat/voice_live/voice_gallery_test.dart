import 'dart:convert';
import '../../../support/system_font.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:app/ui/chat/voice_live/voice_live_page.dart';
import 'package:app/ui/chat/voice_live/voice_live_session.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_voice_live_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadSystemMono();
    final systemFont = File('/System/Library/Fonts/SFNS.ttf');
    if (await systemFont.exists()) {
      final sans = FontLoader('.SF Pro Text');
      sans.addFont(
        systemFont.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await sans.load();
    }
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.where(
      (e) => (e['family'] as String).contains('Lucide'),
    )) {
      final icons = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        icons.addFont(rootBundle.load(font['asset'] as String));
      }
      await icons.load();
    }
  });
  testWidgets('voice review gallery, synthetic data and system Menlo', (
    t,
  ) async {
    t.view.physicalSize = const Size(440, 956);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Future<void> capture(String name, Widget child) async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: RepaintBoundary(
            key: const Key('capture'),
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(440, 956),
                padding: EdgeInsets.only(top: 60, bottom: 34),
              ),
              child: child,
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
      final dir = Platform.environment['RP_REVIEW_DIR'];
      if (dir != null) {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture')),
        );
        await t.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$dir/voice-$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await t.pumpWidget(const SizedBox());
    }

    await capture(
      'composer',
      Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              const Text('Scratch pane'),
              const Spacer(),
              InputBar(onSend: (_) {}, onStartVoiceLive: () {}),
            ],
          ),
        ),
      ),
    );
    for (final phase in [
      VoiceLivePhase.connecting,
      VoiceLivePhase.listening,
      VoiceLivePhase.speaking,
      VoiceLivePhase.working,
      VoiceLivePhase.ended,
    ]) {
      final s = FakeVoiceLiveSession()
        ..phase = phase
        ..endedReason = 'Relay lost. The live session has ended.'
        ..costFinal = phase == VoiceLivePhase.ended;
      if (phase != VoiceLivePhase.connecting) {
        s.items = [
          const VoiceLiveItem(
            id: '1',
            kind: VoiceLiveItemKind.zach,
            text: 'Check the preview and tell me what still needs work.',
          ),
          const VoiceLiveItem(
            id: '2',
            kind: VoiceLiveItemKind.voice,
            text:
                'I’ll check the preview in your scratch pane. You can keep talking while I work.',
          ),
          if (phase == VoiceLivePhase.working)
            const VoiceLiveItem(
              id: '3',
              text: 'Working in Pi',
              kind: VoiceLiveItemKind.backend,
              status: 'working',
            ),
        ];
      }
      await capture(
        phase.name,
        VoiceLivePage(
          session: s,
          paneName: 'Remote Pi / Scratch pane',
          keepAwake: (_) async {},
        ),
      );
      s.dispose();
    }
    for (final isDraft in [false, true]) {
      final s = FakeVoiceLiveSession()
        ..phase = VoiceLivePhase.working
        ..pendingApproval = isDraft
            ? null
            : const VoiceToolApproval(
                id: 'approval',
                tool: 'bash',
                args: '{\n  "command": "flutter test",\n  "cwd": "/projects/remote-pi/app"\n}',
                title: 'Allow bash once?',
              )
        ..draft = isDraft
            ? const VoiceDraft(
                id: 'draft-1',
                hash: 'synthetic-hash',
                title: 'EMAIL DRAFT',
                raw:
                    'To: alex@example.com\nCc: review@example.com\nSubject: Preview ready for your review\n\nHi Alex,\n\nThe updated preview is ready. The voice screen now shows the live session cost and keeps the exact approval text visible.\n\nPlease review the attached notes before we schedule the next test. Nothing has been sent or deployed.\n\nZach',
                eligible: true,
                seen: false,
                attachments: [
                  VoiceDraftAttachment(id: 'att-1', name: 'preview-notes.pdf', size: 43008, mime: 'application/pdf'),
                ],
              )
            : null;
      await capture(
        isDraft ? 'draft' : 'approval',
        VoiceLivePage(
          session: s,
          paneName: 'Remote Pi / Scratch pane',
          keepAwake: (_) async {},
        ),
      );
      s.dispose();
    }
  });
}
