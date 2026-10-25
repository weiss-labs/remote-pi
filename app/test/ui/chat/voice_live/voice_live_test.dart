import 'dart:async';
import 'package:app/ui/chat/voice_live/voice_approval_card.dart';
import 'package:app/ui/chat/voice_live/voice_live_page.dart';
import 'package:app/ui/chat/voice_live/voice_live_session.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_voice_live_session.dart';

VoiceApproval draft({String hash = 'v1', String? body}) => VoiceApproval(
  id: 'approval-1',
  toolName: 'send_email',
  args: const {'account': 'demo@example.com'},
  draft: VoiceDraft(
    hash: hash,
    to: const ['recipient@example.com'],
    cc: const ['copy@example.com'],
    subject: 'Synthetic review draft',
    body:
        body ??
        List.generate(
          60,
          (i) => 'Line $i: the exact message must be reviewed.',
        ).join('\n'),
    attachments: const ['proposal.pdf'],
  ),
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
    VoiceApproval a,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 550,
              child: VoiceApprovalCard(approval: a, session: s),
            ),
          ),
        ),
      ),
    );
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
      expect(s.decisions, [('approval-1', true)]);
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
      await t.tap(find.text('Deny'));
      await t.pump();
      expect(s.decisions, [('approval-1', false)]);
      await t.pump();
      expect(s.seen.length, 1);
    },
  );

  testWidgets('tool approval shows exact args and forwards allow once', (
    t,
  ) async {
    final s = FakeVoiceLiveSession();
    await card(
      t,
      s,
      const VoiceApproval(
        id: 'tool-7',
        toolName: 'bash',
        args: {'command': 'pwd'},
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
