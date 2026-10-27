// Opt-in PNG capture: RP_REVIEW_DIR=/tmp/rp-astra/review/before flutter test test/ui/design_review_test.dart
import 'dart:async';
import 'dart:convert';
import '../support/system_font.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/data/credentials/credential_request_controller.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

final _peer = PeerRecord(
  remoteEpk: 'cGVlcg==',
  sessionName: 'Mac',
  relayUrl: 'wss://example.invalid',
  pairedAt: '2026-01-01T00:00:00Z',
);
final _rooms = [
  const RoomInfo(
    startedAt: 0,
    roomId: 'pinned',
    name: 'Studio›Design›Review',
    model: 'GPT-6 Astra',
  ),
  const RoomInfo(
    startedAt: 0,
    roomId: 'working',
    name: 'Remote_Pi›Mobile›Interface polish',
    model: 'GPT-6 Astra',
  ),
  const RoomInfo(
    startedAt: 0,
    roomId: 'relay',
    name: 'Remote_Pi›Services›Relay',
    model: 'Claude Fable',
  ),
  const RoomInfo(
    startedAt: 0,
    roomId: 'site',
    name: 'Weiss_Labs›Website›Main',
    model: 'Claude Fable',
  ),
  const RoomInfo(
    startedAt: 0,
    roomId: 'offline',
    name: 'Personal›1›Notes',
    model: 'Grok',
  ),
];

class _Home extends ChangeNotifier implements HomeViewModel {
  @override
  HomeList get state => HomeList(
    peers: [_peer],
    roomsByPeer: {_peer.remoteEpk: _rooms},
    filter: HomeFilter.all,
  );
  @override
  List<HomeItem> get visibleItems => state.items();
  @override
  bool get isRelayConnected => true;
  @override
  String get query => '';
  @override
  ({int all, int online, int offline}) get counts =>
      (all: 5, online: 4, offline: 1);
  @override
  bool isPinned(HomeItem it) => it.room.roomId == 'pinned';
  @override
  bool isRoomLive(String epk, String roomId) => roomId != 'offline';
  @override
  bool isRoomWorking(String epk, String roomId) => roomId == 'working';
  @override
  List<String> orderWorkspaces(Iterable<String> names) => names.toList();
  @override
  List<HomeItem> byRecency(List<HomeItem> items) => items;
  @override
  int lastActive(HomeItem it) => 0;
  @override
  Future<void> refresh() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Update extends ChangeNotifier implements UpdateBannerViewModel {
  @override
  UpdateBannerState get state => const UpdateBannerHidden();
  @override
  Future<void> check() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Prefs extends ChangeNotifier implements Preferences {
  @override
  bool get hideToolCalls => false;
  @override
  bool get hideUsage => false;
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
  Future<String> stop() async => 'Synthetic dictation';
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}

class _Chat extends ChangeNotifier implements ChatViewModel {
  _Chat(this.provider);
  final String provider;
  @override
  CredentialRequestController? get credentials => null;
  @override
  PeerRecord get activePeer => _peer;
  @override
  RoomInfo get activeRoom => RoomInfo(
    startedAt: 0,
    roomId: 'review',
    name: 'Remote_Pi›Mobile›Interface polish',
    model: provider,
    footer: jsonEncode({
      'model': provider == 'Claude'
          ? 'Fable'
          : provider == 'Codex'
          ? 'GPT-6'
          : 'Grok',
      'thinking': 'high',
      'ctxPct': 24,
      'usage': {
        'provider': provider,
        'email': 'demo@example.com',
        if (provider == 'Codex') 'extra': '+62,500 credits',
        'windows': [
          {
            'label': '5h',
            'leftPercent': provider == 'Claude' ? 84 : 99,
            'resetsAtMs': DateTime(2026, 10, 26, 15, 30).millisecondsSinceEpoch,
          },
          if (provider == 'Claude') ...[
            {
              'label': 'weekly',
              'leftPercent': 42,
              'resetsAtMs': DateTime(2026, 10, 26, 19).millisecondsSinceEpoch,
            },
            {
              'label': 'Fable',
              'leftPercent': 52,
              'resetsAtMs': DateTime(
                2026,
                10,
                26,
                18,
                59,
              ).millisecondsSinceEpoch,
            },
          ],
        ],
      },
    }),
  );
  @override
  bool get connectionResolved => true;
  @override
  bool get isRoomLive => true;
  @override
  bool get isWorking => false;
  @override
  String? get cancelTargetId => null;
  @override
  ChatState get state => const ChatReady(
    messages: [
      UserMsg(id: 'u', text: 'Polish the interface, keep every interaction.'),
      AssistantMsg(
        id: 'a',
        text:
            '## Interface check\n- Keep the pane tree.\n- Match the `Pi` palette.\n\n[Review notes](https://example.com)\n```dart\nflutter test\n```',
      ),
      ToolEvent(
        id: 't1',
        toolCallId: 't1',
        tool: 'bash',
        args: {'command': 'flutter analyze'},
      ),
      ToolEvent(
        id: 't2',
        toolCallId: 't2',
        tool: 'bash',
        args: {'command': 'flutter test'},
        status: ToolEventStatus.completed,
      ),
      ToolEvent(
        id: 't3',
        toolCallId: 't3',
        tool: 'bash',
        args: {'command': 'check preview'},
        status: ToolEventStatus.failed,
        error: 'Preview unavailable',
      ),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
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
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/weiss-labs-logo.png'),
        tester.element(find.byKey(const Key('capture'))),
      );
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('home review with system Menlo and synthetic panes', (
    tester,
  ) async {
    final home = _Home();
    final update = _Update();
    final shell = ShellLayout();
    await pump(
      tester,
      MultiProvider(
        providers: [
          ChangeNotifierProvider<HomeViewModel>.value(value: home),
          ChangeNotifierProvider<UpdateBannerViewModel>.value(value: update),
          ChangeNotifierProvider<ShellLayout>.value(value: shell),
        ],
        child: const HomePage(),
      ),
    );
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // Offline count, not a tab heading.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await capture(tester, 'home');
    await tester.pumpWidget(const SizedBox());
    home.dispose();
    update.dispose();
    shell.dispose();
  });
  for (final provider in ['Claude', 'Codex', 'Grok']) {
    testWidgets('$provider chat and dictation review', (tester) async {
      final vm = _Chat(provider);
      final prefs = _Prefs();
      final attach = _Attach();
      final voice = VoiceInputViewModel(_Speech());
      await pump(
        tester,
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ChatViewModel>.value(value: vm),
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
          ],
          child: const ChatPage(initialOnline: true),
        ),
      );
      await capture(tester, 'chat-${provider.toLowerCase()}');
      await tester.tap(find.byIcon(LucideIcons.mic600));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('recording-strip')), findsOneWidget);
      await capture(tester, 'dictation-${provider.toLowerCase()}');
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 300));
      await capture(tester, 'history-top-${provider.toLowerCase()}');
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      prefs.dispose();
      attach.dispose();
      voice.dispose();
    });
  }
}
