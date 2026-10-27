import 'dart:async';

import 'package:app/domain/contracts/notifications.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/config/dependencies.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Plan 31 — open the v2 SSOT boxes + WIPE the volatile runtime box BEFORE
  // anything subscribes (#3 / Risk 2).
  await LocalBoxes.init();
  await setupDependencies();
  // Eagerly construct the SSOT writer so it's consuming the channel from boot
  // (messages can arrive before the chat screen mounts).
  injector.get<SyncService>();
  runApp(const RemotePiApp());
}

class RemotePiApp extends StatefulWidget {
  const RemotePiApp({super.key});

  @override
  State<RemotePiApp> createState() => _RemotePiAppState();
}

class _RemotePiAppState extends State<RemotePiApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    injector.get<PairingStorage>(),
    injector.get<ConnectionManager>(),
    injector.get<Preferences>(),
    injector.get<OwnerIdentityBridge>(),
    injector.get<MeshSyncService>(),
  );

  StreamSubscription<NotificationTarget>? _tapSub;
  final List<NotificationTarget> _pendingTaps = [];
  bool _openingTap = false;
  Notifications get _notifications => injector.get<Notifications>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tapSub = _notifications.taps.listen((target) {
      _pendingTaps.add(target);
      _routeChanged();
    });
    _router.routeInformationProvider.addListener(_routeChanged);
    injector.get<SessionSelection>().addListener(_updateVisibleTarget);
    unawaited(_notifications.start());
  }

  void _routeChanged() {
    _updateVisibleTarget();
    final path = _router.routeInformationProvider.value.uri.path;
    if (!{'/home', '/chat', '/settings'}.contains(path) ||
        _pendingTaps.isEmpty ||
        _openingTap) {
      return;
    }
    unawaited(_openTap());
  }

  Future<void> _openTap() async {
    _openingTap = true;
    final target = _pendingTaps.removeAt(0);
    try {
      if (!await _notifications.acceptTap(target) || !mounted) return;
      final storage = injector.get<PairingStorage>();
      final peers = await storage.listPeers();
      final peer = peers
          .where(
            (p) => toStandardB64(p.remoteEpk) == toStandardB64(target.peer),
          )
          .firstOrNull;
      if (peer == null || !mounted) return;
      await injector.get<Preferences>().setSelectedRoom(
        epk: peer.remoteEpk,
        roomId: target.room,
      );
      final conn = injector.get<ConnectionManager>();
      conn.switchRoom(target.room);
      unawaited(conn.switchTo(peer.copyWith(roomId: target.room)));
      injector.get<SessionSelection>().select(
        peer.remoteEpk,
        target.room,
        'Pane',
        peer.nickname ?? peer.sessionName,
      );
      _router.go('/home');
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      if (view.physicalSize.shortestSide / view.devicePixelRatio <
          kTabletBreakpoint) {
        _router.push(
          '/chat',
          extra: {'title': 'Pane', 'device': peer.nickname ?? peer.sessionName},
        );
      }
    } finally {
      _openingTap = false;
      if (mounted) _routeChanged();
    }
  }

  void _updateVisibleTarget() {
    final path = _router.routeInformationProvider.value.uri.path;
    final selected = injector.get<SessionSelection>().current;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final wide =
        view.physicalSize.shortestSide / view.devicePixelRatio >=
        kTabletBreakpoint;
    final visible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        (path == '/chat' || (path == '/home' && wide));
    unawaited(
      _notifications.visibleTarget(
        visible ? selected?.epk : null,
        visible ? selected?.roomId : null,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSub?.cancel();
    _router.routeInformationProvider.removeListener(_routeChanged);
    injector.get<SessionSelection>().removeListener(_updateVisibleTarget);
    disposeDependencies();
    super.dispose();
  }

  /// Plan 24 — keep the mesh poll timer aligned with the app's
  /// foreground lifecycle. Polling runs ONLY while resumed; in
  /// inactive/paused/hidden/detached we cancel so we don't drain the
  /// battery (and we'll resync via `pullOnDemand` on the next resume +
  /// boot path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final meshSync = injector.get<MeshSyncService>();
    _updateVisibleTarget();
    if (state == AppLifecycleState.resumed) unawaited(_notifications.refresh());
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        // ignore: unawaited_futures
        meshSync.pullOnDemand();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        meshSync.stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Preferences>.value(
          value: injector.get<Preferences>(),
        ),
        ChangeNotifierProvider<SessionSelection>.value(
          value: injector.get<SessionSelection>(),
        ),
        // Shell layout state — lets the adaptive shell collapse the split
        // into a single centered pane on zero-state Home (no Pi / empty).
        ChangeNotifierProvider<ShellLayout>.value(
          value: injector.get<ShellLayout>(),
        ),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: 'Remote Pi',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          // Weiss Labs: always dark, like the terminal.
          themeMode: ThemeMode.dark,
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
          // Issue #114 — user-chosen text size. Applied here rather than by
          // scaling `AppTypography`'s base sizes so the many per-widget
          // `copyWith(fontSize: …)` overrides scale too. `TextScaler.linear`
          // REPLACES the platform scaler, which is deliberate: Flutter can't
          // read iOS's per-app Text Size anyway (it only reads the global
          // accessibility setting), so honoring both would compound them.
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: prefs.fontScale.factor,
            maxScaleFactor: prefs.fontScale.factor,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
