import 'dart:typed_data';
import 'dart:async';
import 'package:app/ui/chat/voice_live/voice_approval_card.dart';
import 'package:app/ui/chat/voice_live/voice_live_page.dart';
import 'package:app/ui/chat/voice_live/voice_live_session.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_voice_live_session.dart';

VoiceDraft draft({String hash = 'v1', String? body}) => VoiceDraft(
  id: 'approval-1',
  hash: hash,
  title: 'EMAIL DRAFT',
  raw:
      'To: recipient@example.com\nCc: copy@example.com\nSubject: Synthetic review draft\n\n${body ?? List.generate(60, (i) => 'Line $i: the exact message must be reviewed.').join('\n')}',
  eligible: true,
  seen: false,
  attachments: const [
    VoiceDraftAttachment(id: 'a1', name: 'mockup.png', size: 42000, mime: 'image/png'),
  ],
);

class _DelayedSession extends FakeVoiceLiveSession {
  final confirmation = Completer<void>();
  @override
  Future<void> draftSeen(String id, String hash) async {
    seen.add((id, hash));
    await confirmation.future;
  }
}

void main() {
  Future<void> card(
    WidgetTester t,
    FakeVoiceLiveSession s,
    Object a,
  ) async {
    t.view.physicalSize = const Size(440, 956); // iPhone 17 Pro Max points
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 720, // phone-height card; image previews take up to 220
              child: a is VoiceDraft
                  ? VoiceApprovalCard(draft: a, session: s)
                  : VoiceApprovalCard(tool: a as VoiceToolApproval, session: s),
            ),
          ),
        ),
      ),
    );
    // Image attachments decode (real async work) before review can count:
    // wait until every preview rendered or failed (max ~2s).
    final images = a is VoiceDraft ? a.attachments.where((x) => x.mime.startsWith('image/')).length : 0;
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      final done = find.byType(RawImage).evaluate().length + find.text('Preview unavailable').evaluate().length;
      if (done >= images) break;
    }
    await t.pump();
  }

  testWidgets(
    'draft seen only after all scrollable content, send waits for review',
    (t) async {
      final s = FakeVoiceLiveSession();
      await card(t, s, draft());
      expect(s.seen, isEmpty);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send this exact draft'),
            )
            .onPressed,
        isNull,
      );
      final scroll = t
          .widget<SingleChildScrollView>(
            find.byKey(const Key('voice-approval-scroll')),
          )
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await t.pump();
      expect(
        s.seen,
        isEmpty,
        reason: 'Jumping over unread text cannot certify a draft',
      );
      scroll.jumpTo(0);
      await t.pump();
      while (scroll.offset < scroll.position.maxScrollExtent) {
        scroll.jumpTo(
          (scroll.offset + 150).clamp(0, scroll.position.maxScrollExtent),
        );
        await t.pump();
      }
      await t.pump();
      expect(s.seen, [('approval-1', 'v1')]);
      await t.tap(find.text('Send this exact draft'));
      await t.pump();
      expect(s.confirms, 1);
      expect(s.decisions, isEmpty);
      await card(t, s, draft(hash: 'v2'));
      expect(s.seen.length, 1);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send this exact draft'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'short complete draft is seen after layout once, deny is genuine tap',
    (t) async {
      final s = FakeVoiceLiveSession();
      await card(t, s, draft(body: 'The complete short message.'));
      await t.pump();
      expect(s.seen, [('approval-1', 'v1')]);
      expect(s.decisions, isEmpty);
      await t.tap(find.text('Not now'));
      await t.pump();
      expect(s.decisions, isEmpty);
      expect(s.confirms, 0);
      await t.pump();
      expect(s.seen.length, 1);
    },
  );

  testWidgets('a corrupt image holds approval', (t) async {
    final s = _CorruptImage();
    await card(t, s, draft(body: 'Short.'));
    expect(s.seen, isEmpty);
    expect(find.textContaining("can't be previewed here"), findsOneWidget);
  });

  testWidgets('a PDF attachment holds approval (no in-app preview)', (t) async {
    final s = FakeVoiceLiveSession();
    await card(
      t,
      s,
      const VoiceDraft(
        id: 'd9',
        hash: 'h9',
        title: 'EMAIL DRAFT',
        raw: 'To: a@example.com\nSubject: x\n\nShort.',
        eligible: true,
        seen: false,
        attachments: [VoiceDraftAttachment(id: 'p', name: 'quote.pdf', size: 9000, mime: 'application/pdf')],
      ),
    );
    await t.pump();
    await t.pump();
    expect(s.seen, isEmpty);
    expect(find.textContaining("can't be previewed here"), findsOneWidget);
    expect(
      t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send this exact draft')).onPressed,
      isNull,
    );
  });

  testWidgets('tool approval shows exact args and forwards allow once', (
    t,
  ) async {
    final s = FakeVoiceLiveSession();
    await card(
      t,
      s,
      const VoiceToolApproval(
        id: 'tool-7',
        tool: 'bash',
        args: '{\n  "command": "pwd"\n}',
        title: 'Allow bash once?',
      ),
    );
    expect(find.textContaining('"command": "pwd"'), findsOneWidget);
    expect(s.decisions, isEmpty);
    await t.tap(find.text('Allow once'));
    await t.pump();
    expect(s.decisions, [('tool-7', true)]);
    expect(s.seen, isEmpty);
    expect(find.text('Decision sent'), findsOneWidget);
  });

  testWidgets(
    'composer voice button is distinct, 44pt, and hidden while typing',
    (t) async {
      var starts = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(
            body: InputBar(onSend: (_) {}, onStartVoiceLive: () => starts++),
          ),
        ),
      );
      final button = find.byTooltip('Start Pi Voice');
      expect(t.getSize(button).width, greaterThanOrEqualTo(44));
      await t.tap(button);
      expect(starts, 1);
      await t.enterText(find.byType(TextField), 'typed');
      await t.pump();
      expect(button, findsNothing);
    },
  );

  testWidgets(
    'review confirmation survives equivalent heartbeat object without duplicate calls',
    (t) async {
      final s = _DelayedSession();
      await card(t, s, draft(body: 'Complete message.'));
      expect(s.seen.length, 1);
      await card(t, s, draft(body: 'Complete message.'));
      expect(s.seen.length, 1);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send this exact draft'),
            )
            .onPressed,
        isNull,
      );
      s.confirmation.complete();
      await t.pump();
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send this exact draft'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'live controls, typed input, explicit restart and wake lifecycle',
    (t) async {
      final s = FakeVoiceLiveSession()..phase = VoiceLivePhase.working;
      final wake = <bool>[];
      await t.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: VoiceLivePage(
            session: s,
            paneName: 'Scratch pane',
            keepAwake: (v) async => wake.add(v),
          ),
        ),
      );
      await t.tap(find.byTooltip('Mute'));
      await t.pump();
      expect(s.muted, true);
      expect(
        find.textContaining('mute does not pause billing'),
        findsOneWidget,
      );
      await t.tap(find.text('Cancel work'));
      await t.pump();
      expect(s.cancels, 1);
      await t.enterText(find.byType(TextField), 'Check the tests');
      await t.tap(find.byTooltip('Send text'));
      await t.pump();
      expect(s.texts, ['Check the tests']);
      await t.tap(find.byTooltip('End call'));
      await t.pump();
      expect(find.text('Stopped'), findsOneWidget);
      expect(s.starts, 0);
      expect(wake, containsAllInOrder([true, false]));
      await t.tap(find.text('Start again'));
      await t.pump();
      expect(s.starts, 1);
      await t.pumpWidget(const SizedBox());
      expect(wake.last, false);
    },
  );

  testWidgets('back edge asks before stopping and stay keeps the session', (
    t,
  ) async {
    final s = FakeVoiceLiveSession();
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: VoiceLivePage(
          session: s,
          paneName: 'Scratch',
          keepAwake: (_) async {},
        ),
      ),
    );
    await t.drag(
      find.byKey(const Key('voice-back-edge')),
      const Offset(120, 0),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('End this voice call?'), findsOneWidget);
    expect(s.phase, VoiceLivePhase.listening);
    await t.tap(find.text('Stay'));
    await t.pump(const Duration(milliseconds: 300));
    expect(s.phase, VoiceLivePhase.listening);
    expect(find.text('End this voice call?'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'small phone keyboard keeps typed composer and controls available',
    (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = FakeVoiceLiveSession();
      await t.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              viewInsets: EdgeInsets.only(bottom: 280),
            ),
            child: VoiceLivePage(
              session: s,
              paneName: 'Scratch',
              keepAwake: (_) async {},
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.byTooltip('End call'), findsOneWidget);
      expect(find.byType(VoiceCloud), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
}

class _CorruptImage extends FakeVoiceLiveSession {
  @override
  Future<({Uint8List bytes, String mime})> attachment(String draftId, String attachmentId) async =>
      (bytes: Uint8List.fromList([1, 2, 3, 4]), mime: 'image/png');
}
