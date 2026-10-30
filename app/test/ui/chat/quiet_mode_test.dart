// Plan/75 — quiet mode on the chat page. Opt-in PNG capture at phone width:
//   RP_REVIEW_DIR=/tmp/rp-quiet/screens flutter test test/ui/chat/quiet_mode_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/data/credentials/credential_request_controller.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/contracts/artifact_preview.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/quiet/quiet_widgets.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/system_font.dart';

final _peer = PeerRecord(
  remoteEpk: 'cGVlcg==',
  sessionName: 'Mac',
  relayUrl: 'wss://example.invalid',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _Prefs extends ChangeNotifier implements Preferences {
  bool _quiet = true;
  @override
  bool get quietMode => _quiet;
  @override
  Future<void> setQuietMode(bool value) async {
    _quiet = value;
    notifyListeners();
  }

  @override
  bool get hideUsage => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Attach extends ChangeNotifier implements AttachmentViewModel {
  @override
  AttachmentState get state => const AttachmentEmpty(visionSupported: true);
  @override
  bool get hasImage => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Speech implements SpeechService {
  @override
  Future<SpeechAvailability> init({String? preferredLocaleId}) async =>
      const SpeechReady('en_US');
  @override
  Stream<double> get soundLevel => const Stream.empty();
  @override
  Future<void> start({
    required String localeId,
    required Duration maxDuration,
  }) async {}
  @override
  Future<String> stop() async => '';
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}

class _Chat extends ChangeNotifier implements ChatViewModel {
  _Chat(this.messages, {this.working = false, this.streaming});
  List<ChatMessage> messages;
  bool working;
  StreamingMessage? streaming;
  int cancelled = 0;
  void set(
    List<ChatMessage> next, {
    bool? working,
    StreamingMessage? streaming,
  }) {
    messages = next;
    this.working = working ?? this.working;
    this.streaming = streaming;
    notifyListeners();
  }

  @override
  CredentialRequestController? get credentials => null;
  @override
  ValueListenable<FileTransferProgress?> get upload => ValueNotifier(null);
  @override
  PeerRecord get activePeer => _peer;
  @override
  RoomInfo get activeRoom => const RoomInfo(
    startedAt: 0,
    roomId: 'quiet',
    name: 'Weiss_Labs›Remote_Pi›Quiet mode',
    model: 'Claude',
  );
  @override
  bool get connectionResolved => true;
  @override
  bool get isRoomLive => true;
  @override
  bool get isWorking => working;
  @override
  String? get cancelTargetId => working ? 'working' : null;
  @override
  ChatState get state =>
      ChatReady(messages: messages, streaming: streaming, isWorking: working);
  @override
  Future<void> previewArtifact(
    String url,
    void Function(double) progress,
  ) async {
    throw const ArtifactFailure('File preview is unavailable.');
  }

  @override
  Future<void> cancelArtifact() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _t0 = DateTime(2026, 10, 30, 9, 41);
ToolEvent _tool(
  String id,
  String name, {
  dynamic args = const <String, dynamic>{},
  dynamic result,
  String? error,
  ToolEventStatus? status,
  int at = 0,
}) => ToolEvent(
  id: id,
  ts: _t0.add(Duration(seconds: at)),
  toolCallId: id,
  tool: name,
  args: args,
  result: result,
  error: error,
  status:
      status ??
      (error != null ? ToolEventStatus.failed : ToolEventStatus.completed),
);

/// A normal run: parallel reads, tests, a failed command retried successfully,
/// an image-only screenshot, then the reply.
List<ChatMessage> _normalRun() => [
  UserMsg(id: 'u1', ts: _t0, text: 'Ship the quiet mode row and show me.'),
  _tool(
    'r1',
    'read',
    args: {'path': '/x/chat_page.dart'},
    result: 'class ChatPage {}',
    at: 1,
  ),
  _tool(
    'r2',
    'read',
    args: {'path': '/x/app_colors.dart'},
    result: 'class AppColors {}',
    at: 1,
  ),
  _tool(
    'b1',
    'bash',
    args: {'command': 'flutter test --no-pub'},
    result: '705 passed',
    at: 4,
  ),
  _tool(
    'b2',
    'bash',
    args: {'command': 'flutter buid ios'},
    error:
        'Error: unknown option "buid"\nSTACK TRACE LINE 1\nSTACK TRACE LINE 2',
    at: 40,
  ),
  _tool(
    'b3',
    'bash',
    args: {'command': 'flutter build ios'},
    result: 'Built Runner.app',
    at: 45,
  ),
  _tool(
    's1',
    'mcp__custom-tools__chrome_screenshot',
    args: {'format': 'png'},
    result: 'Saved /tmp/rp-quiet/screens/quiet.png',
    at: 100,
  ),
  AssistantMsg(
    id: 'a1',
    // First step at +1s → reply at +125s = 2m 4s of work.
    ts: _t0.add(const Duration(minutes: 2, seconds: 5)),
    text: 'Done. The fold row shows timing and the step count.',
  ),
];

List<ChatMessage> _holdsAndDrafts() => [
  ..._normalRun(),
  _tool(
    'mesh_1',
    'agent-network',
    args: {
      'from': '/tmp@William›Main›FB_Ads',
      'message':
          '{"status":"needs_approval","summary":"Publish the page","detail":"FULL_PRIVATE_MESH_BODY"}',
    },
    result: {
      'from': '/tmp@William›Main›FB_Ads',
      'message':
          '{"status":"needs_approval","summary":"Publish the page","detail":"FULL_PRIVATE_MESH_BODY"}',
    },
    at: 130,
  ),
  _tool(
    'hold',
    'mcp__custom-tools__notify_user',
    args: {'category': 'input_needed'},
    error: 'Approval required: confirm before sending to the client.',
    at: 131,
  ),
  _tool(
    'cred',
    'request_credential',
    args: {'label': 'Stripe key'},
    error: 'Sign-in required on the Mac.',
    at: 132,
  ),
  _tool(
    'draft',
    'mcp__custom-tools__codemode',
    args: {'code': 'panel()'},
    result:
        '┌────────────────────┐\n│ EMAIL DRAFT        │\n├────────────────────┤\n│ Hi Michael, exact  │\n│ body to approve.   │\n└────────────────────┘',
    at: 133,
  ),
  AssistantMsg(
    id: 'a2',
    ts: _t0.add(const Duration(minutes: 3)),
    text: 'Waiting on you.',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadSystemMono();
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

  Future<void> capture(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    final dir = Platform.environment['RP_REVIEW_DIR'];
    if (dir == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<(_Chat, _Prefs)> pump(
    WidgetTester tester,
    List<ChatMessage> messages, {
    bool working = false,
    StreamingMessage? streaming,
    bool quiet = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final vm = _Chat(messages, working: working, streaming: streaming);
    final prefs = _Prefs().._quiet = quiet;
    final attach = _Attach();
    final voice = VoiceInputViewModel(_Speech());
    addTearDown(() {
      vm.dispose();
      prefs.dispose();
      attach.dispose();
      voice.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        // Boundary above the Navigator so bottom-sheet previews are captured.
        builder: (_, child) =>
            RepaintBoundary(key: const Key('capture'), child: child),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 54, bottom: 34),
          ),
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
            ],
            child: const ChatPage(initialOnline: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return (vm, prefs);
  }

  testWidgets(
    'normal run folds into one timed row; steps expand; raw messages untouched',
    (tester) async {
      final messages = _normalRun();
      final snapshot = List<ChatMessage>.of(messages);
      await pump(tester, messages);

      expect(find.byType(ToolRequestCard), findsNothing);
      expect(find.text('Worked for 2m 4s · 6 steps'), findsOneWidget);
      // The Quiet switch lives in Quick actions, not the app bar.
      expect(find.text('Quiet'), findsNothing);
      expect(find.textContaining('STACK TRACE'), findsNothing);
      await capture(tester, 'quiet-collapsed');

      await tester.tap(find.byKey(const Key('quiet-group-toggle-r1')));
      await tester.pump();
      expect(find.text('Read chat_page.dart'), findsOneWidget);
      expect(find.text('Read app_colors.dart'), findsOneWidget);
      expect(find.text('Run tests'), findsOneWidget);
      expect(
        find.text('Could not run the command (option not accepted)'),
        findsOneWidget,
      );
      expect(find.text('Run command'), findsOneWidget);
      expect(find.text('Chrome screenshot'), findsOneWidget);
      expect(find.textContaining('STACK TRACE'), findsNothing);
      await capture(tester, 'quiet-expanded');

      // Collapse again hides the steps.
      await tester.tap(find.byKey(const Key('quiet-group-toggle-r1')));
      await tester.pump();
      expect(find.text('Run tests'), findsNothing);

      for (var i = 0; i < messages.length; i++) {
        expect(identical(messages[i], snapshot[i]), isTrue);
      }
      expect((messages[4] as ToolEvent).error, contains('STACK TRACE LINE 2'));
    },
  );

  testWidgets(
    'tapping a step opens the full in-app preview and closing keeps the scroll position',
    (tester) async {
      // Enough history to scroll.
      final messages = <ChatMessage>[
        for (var i = 0; i < 6; i++) ...[
          UserMsg(id: 'u$i', ts: _t0, text: 'Earlier request $i'),
          AssistantMsg(
            id: 'a$i',
            ts: _t0,
            text: 'Earlier reply $i\n\nwith a few lines\n\nof prose.',
          ),
        ],
        ..._normalRun(),
      ];
      await pump(tester, messages);
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      await tester.tap(find.byKey(const Key('quiet-group-toggle-r1')));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.byKey(const Key('quiet-step-b2')));
      await tester.pump();
      final offsetBefore = position.pixels;
      expect(offsetBefore, greaterThan(0));

      await tester.tap(find.byKey(const Key('quiet-step-b2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quiet-preview')), findsOneWidget);
      expect(find.text('ARGUMENTS'), findsOneWidget);
      expect(find.textContaining('flutter buid ios'), findsOneWidget);
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.textContaining('STACK TRACE LINE 2'), findsOneWidget);
      await capture(tester, 'quiet-preview-failed');

      await tester.tap(find.byKey(const Key('quiet-preview-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quiet-preview')), findsNothing);
      expect(position.pixels, offsetBefore);
      // The expanded state survived the preview; nothing else expanded.
      expect(find.text('Run tests'), findsOneWidget);
    },
  );

  testWidgets(
    'image-only result previews through the in-app artifact route, never a URL',
    (tester) async {
      await pump(tester, _normalRun());
      await tester.tap(find.byKey(const Key('quiet-group-toggle-r1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('quiet-step-s1')));
      await tester.pumpAndSettle();
      expect(find.text('IMAGES'), findsOneWidget);
      expect(find.text('quiet.png'), findsOneWidget);
      await capture(tester, 'quiet-preview-image');
      await tester.ensureVisible(
        find.byKey(const Key('quiet-image-/tmp/rp-quiet/screens/quiet.png')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('quiet-image-/tmp/rp-quiet/screens/quiet.png')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The fake pane has no artifact service: the in-app dialog reports it,
      // which proves the path went through ChatViewModel.previewArtifact.
      expect(find.text('Preview unavailable'), findsOneWidget);
      expect(find.text('File preview is unavailable.'), findsOneWidget);
    },
  );

  testWidgets('long output renders completely and lazily', (tester) async {
    final big = List.generate(20000, (i) => 'line $i').join('\n');
    await pump(tester, [
      const UserMsg(id: 'u', text: 'dump'),
      _tool(
        'big',
        'bash',
        args: {'command': 'cat huge.log'},
        result: big,
        at: 1,
      ),
      AssistantMsg(
        id: 'a',
        ts: _t0.add(const Duration(seconds: 9)),
        text: 'ok',
      ),
    ]);
    await tester.tap(find.byKey(const Key('quiet-group-toggle-big')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiet-step-big')));
    await tester.pumpAndSettle();
    expect(find.textContaining('line 0\n'), findsOneWidget);
    expect(
      find.textContaining('line 19999'),
      findsNothing,
    ); // not built until scrolled
    final list = find.descendant(
      of: find.byKey(const Key('quiet-preview')),
      matching: find.byType(ListView),
    );
    final position = Scrollable.of(
      tester.element(find.textContaining('line 0\n')),
    ).position;
    // Lazy extent is an estimate that grows as blocks lay out: keep jumping.
    for (
      var i = 0;
      i < 40 && find.textContaining('line 19999').evaluate().isEmpty;
      i++
    ) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    expect(find.textContaining('line 19999'), findsOneWidget);
    expect(list, findsOneWidget);
  });

  testWidgets('holds, sign-in, cross-pane messages and exact draft panels', (
    tester,
  ) async {
    await pump(tester, _holdsAndDrafts());
    // Human actions are prominent lines outside the count.
    expect(find.text('Worked for 2m 4s · 6 steps'), findsOneWidget);
    expect(
      find.text("Approval needed. Open this step's preview."),
      findsOneWidget,
    );
    expect(
      find.text("Sign-in needed. Open this step's preview."),
      findsOneWidget,
    );
    // An approval request from another pane is one meaningful line; its
    // full body is hidden until tapped.
    expect(
      find.text('Approval needed · Main / FB Ads: Publish the page'),
      findsOneWidget,
    );
    expect(find.textContaining('FULL_PRIVATE_MESH_BODY'), findsNothing);
    // The draft panel is fully visible, exact text intact.
    expect(find.byKey(const Key('quiet-attention-draft')), findsOneWidget);
    expect(find.text('Needs your approval, shown in full'), findsOneWidget);
    expect(find.textContaining('Hi Michael, exact'), findsOneWidget);
    await capture(tester, 'quiet-holds-drafts');

    await tester.tap(find.byKey(const Key('quiet-notice-mesh_1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('FULL_PRIVATE_MESH_BODY'), findsWidgets);
    await capture(tester, 'quiet-preview-message');
    await tester.tap(find.byKey(const Key('quiet-preview-close')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('quiet-notice-hold')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiet-notice-hold')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('confirm before sending to the client'),
      findsOneWidget,
    );
  });

  testWidgets('live run shows one animated status line and no cards', (
    tester,
  ) async {
    final (vm, _) = await pump(tester, [
      UserMsg(id: 'u', ts: _t0, text: 'Run the tests and fix what breaks.'),
    ], working: true);
    expect(find.byKey(const Key('quiet-status')), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    final dots = find.byKey(const Key('quiet-status-dots'));
    final seen = <String>{};
    for (var i = 0; i < 4; i++) {
      seen.add(tester.widget<Text>(dots).data!);
      await tester.pump(const Duration(milliseconds: 180));
    }
    // Four 180ms frames cycle ●·· ·●· ··● ·●· : three distinct glyphs.
    expect(seen, {'●··', '·●·', '··●'});

    vm.set([
      ...vm.messages,
      _tool(
        't',
        'bash',
        args: {'command': 'npm test'},
        status: ToolEventStatus.pending,
      ),
    ]);
    await tester.pump();
    expect(find.text('Running the tests'), findsOneWidget);
    expect(find.byType(QuietWorkRow), findsNothing);
    expect(find.byType(ToolRequestCard), findsNothing);
    await capture(tester, 'quiet-working');

    vm.set([
      ...vm.messages.sublist(0, 1),
      _tool('t', 'bash', args: {'command': 'npm test'}, result: 'ok'),
    ]);
    await tester.pump();
    expect(find.text('Working'), findsOneWidget);

    // Streaming reply: status stays until the turn settles.
    vm.set(
      vm.messages,
      streaming: const StreamingMessage(inReplyTo: 'u', buffer: 'Tests pass.'),
    );
    await tester.pump();
    expect(find.byKey(const Key('quiet-status')), findsOneWidget);
    expect(find.byKey(const Key('streaming-cursor')), findsOneWidget);

    // Settled: the status stops and the fold row appears with real timing.
    vm.set([
      ...vm.messages,
      AssistantMsg(
        id: 'a',
        ts: _t0.add(const Duration(seconds: 42)),
        text: 'Tests pass.',
      ),
    ], working: false);
    await tester.pump();
    expect(find.byKey(const Key('quiet-status')), findsNothing);
    expect(find.text('Worked for 42s · 1 step'), findsOneWidget);
  });

  testWidgets('historical session without timing shows a count only', (
    tester,
  ) async {
    await pump(tester, [
      UserMsg(id: 'u', ts: DateTime.fromMillisecondsSinceEpoch(0), text: 'old'),
      ToolEvent(
        id: 'h1',
        ts: DateTime.fromMillisecondsSinceEpoch(0),
        toolCallId: 'h1',
        tool: 'read',
        args: const {'path': 'old.md'},
        status: ToolEventStatus.completed,
      ),
      const ToolEvent(
        id: 'h2',
        toolCallId: 'h2',
        tool: 'bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      ),
      AssistantMsg(
        id: 'a',
        ts: DateTime.fromMillisecondsSinceEpoch(0),
        text: 'old reply',
      ),
    ]);
    expect(find.text('2 steps'), findsOneWidget);
    expect(find.textContaining('Worked for'), findsNothing);
  });

  testWidgets(
    'toggle round trip: Quiet ⇄ Full details restores native cards without losing content',
    (tester) async {
      final (_, prefs) = await pump(tester, _holdsAndDrafts());
      expect(find.byType(ToolRequestCard), findsNothing);
      await prefs.setQuietMode(false);
      await tester.pump();
      expect(prefs.quietMode, isFalse);
      expect(find.byType(ToolRequestCard), findsWidgets);
      expect(find.byType(QuietWorkRow), findsNothing);
      // Native cards: every tool back, including the one carrying the draft.
      expect(find.text('MCP__CUSTOM-TOOLS__CODEMODE'), findsOneWidget);
      await capture(tester, 'full-details');

      await prefs.setQuietMode(true);
      await tester.pump();
      expect(prefs.quietMode, isTrue);
      expect(find.byType(ToolRequestCard), findsNothing);
      expect(find.text('Worked for 2m 4s · 6 steps'), findsOneWidget);
    },
  );

  // Fleet #117/#120 demo: the same transcript renders on main (before) and
  // this branch (after). RP_REVIEW_DIR=/tmp/rp-labels/demo/after flutter test
  // --plain-name 'activity labels demo' test/ui/chat/quiet_mode_test.dart
  testWidgets('activity labels demo', (tester) async {
    final before = Platform.environment['RP_DEMO_BEFORE'] != null;
    Map<String, String> mesh(String text) => {
      'from': '/x@Personal_Projects›Remote_Pi›Main',
      'message': text,
    };
    final (vm, _) = await pump(tester, [
      UserMsg(id: 'u', ts: _t0, text: 'Add task-specific activity labels.'),
      _tool('r1', 'read', args: {'path': '/a/quiet-mode.ts'}, at: 1),
      _tool(
        'ack1',
        'agent-network',
        args: mesh('Got it, on it.'),
        result: mesh('Got it, on it.'),
        at: 2,
      ),
      _tool(
        'ack2',
        'agent-network',
        args: mesh('Got it, on it.'),
        result: mesh('Got it, on it.'),
        at: 3,
      ),
      _tool('t1', 'bash', args: {'command': 'flutter test --no-pub'}, at: 30),
      _tool(
        'done1',
        'agent-network',
        args: mesh(
          '{"status":"success","summary":"Build 16 uploaded and verified."}',
        ),
        result: mesh(
          '{"status":"success","summary":"Build 16 uploaded and verified."}',
        ),
        at: 40,
      ),
      AssistantMsg(
        id: 'a1',
        ts: _t0.add(const Duration(seconds: 45)),
        text: 'Labels are in.',
      ),
      UserMsg(
        id: 'u2',
        ts: _t0.add(const Duration(seconds: 50)),
        text: 'Check the release.',
      ),
      AssistantMsg(
        id: 'a2',
        ts: _t0.add(const Duration(seconds: 51)),
        text: 'Let me check the release:',
      ),
      _tool(
        'gh',
        'bash',
        args: {'command': 'gh release view --json tagName'},
        status: ToolEventStatus.pending,
        at: 52,
      ),
    ], working: true);
    if (!before) {
      expect(find.text('Checking the release'), findsOneWidget);
      expect(find.text('Message from Remote Pi / Main'), findsNothing);
      expect(find.text('Worked for 44s · 4 steps'), findsOneWidget);
      expect(
        find.text('Done · Remote Pi / Main: Build 16 uploaded and verified'),
        findsOneWidget,
      );
    }
    await capture(tester, 'demo-live-and-notices');
    await tester.tap(find.textContaining('Worked for'));
    await tester.pump(const Duration(milliseconds: 300));
    await capture(tester, 'demo-expanded');
    expect(vm.messages.length, 10);
  });
}
