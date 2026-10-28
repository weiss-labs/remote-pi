import 'dart:async';
import 'package:app/ui/chat/widgets/credential_needed_dialog.dart';

import 'package:app/domain/contracts/notifications.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/config/dependencies.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/share/share_inbox.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/routing/notification_routes.dart';
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

  late final NotificationRoutes _notificationRoutes;
  Notifications get _notifications => injector.get<Notifications>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationRoutes = NotificationRoutes(
      router: _router,
      taps: _notifications.taps,
      open: _openTap,
      routeChanged: _updateVisibleTarget,
    );
    injector.get<SessionSelection>().addListener(_updateVisibleTarget);
    unawaited(_notifications.start());
    // Plan/74 — items queued by the Share extension while we were closed.
    unawaited(_drainShareInbox());
  }

  // ---------------------------------------------------------------------------
  // Plan/74 — Share-sheet queue. Each item is sent to exactly the pane picked
  // in the extension; nothing is ever re-routed to the current chat.
  // ---------------------------------------------------------------------------
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  bool _shareDraining = false;
  static const _shareNotReady =
      'Remote Pi was not ready. It will send the next time you open the app.';

  Future<void> _drainShareInbox() async {
    if (_shareDraining || !mounted) return;
    _shareDraining = true;
    try {
      final inbox = injector.get<ShareInbox>();
      for (final item in await inbox.takeQueued()) {
        if (!mounted) return;
        final error = await _sendShared(item);
        if (error == _shareNotReady) {
          // Keep it (and everything after it) queued for the next foreground.
          _toast('${item.file.name}: $error');
          return;
        }
        await inbox.complete(item.id);
        _toast(
          error == null
              ? 'Sent ${item.file.name} to ${item.label}.'
              : '${item.file.name}: $error',
        );
      }
    } finally {
      _shareDraining = false;
    }
  }

  void _toast(String text) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Null on success, otherwise the user-facing reason the item was dropped.
  Future<String?> _sendShared(SharedItem item) async {
    if (!await _waitUntil(
      () => {
        '/home',
        '/chat',
        '/settings',
      }.contains(currentNotificationPath(_router)),
      const Duration(seconds: 15),
    )) {
      return _shareNotReady;
    }
    final peers = await injector.get<PairingStorage>().listPeers();
    final peer = peers
        .where((p) => toStandardB64(p.remoteEpk) == toStandardB64(item.peer))
        .firstOrNull;
    if (peer == null || !mounted) return 'That Mac is no longer paired.';
    await _openPane(peer, item.room);
    final conn = injector.get<ConnectionManager>();
    if (!await _waitUntil(
      () =>
          conn.channel != null &&
          conn.activePeer?.remoteEpk == peer.remoteEpk &&
          conn.activeRoomId == item.room &&
          conn.isRoomLive(peer.remoteEpk, item.room),
      const Duration(seconds: 20),
    )) {
      return 'That pane is offline. Share it again when it is back.';
    }
    try {
      await injector.get<FileTransfer>().send(
        item.file,
        messageId: 'cli_${uuid7()}',
        peer: peer.remoteEpk,
        room: item.room,
        steer: conn.isRoomWorking(peer.remoteEpk, item.room),
      );
      return null;
    } on FileTransferFailure catch (e) {
      return e.message;
    }
  }

  Future<bool> _waitUntil(bool Function() ready, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (mounted) {
      if (ready()) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Select + connect + show the chat for (peer, room). Shared by notification
  /// taps and the Share-sheet queue.
  Future<void> _openPane(PeerRecord peer, String room) async {
    await injector.get<Preferences>().setSelectedRoom(
      epk: peer.remoteEpk,
      roomId: room,
    );
    if (!mounted) return;
    final conn = injector.get<ConnectionManager>();
    conn.switchRoom(room);
    unawaited(conn.switchTo(peer.copyWith(roomId: room)));
    injector.get<SessionSelection>().select(
      peer.remoteEpk,
      room,
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
  }

  Future<void> _openTap(NotificationTarget target) async {
    if (!await _notifications.acceptTap(target) || !mounted) return;
    final knownRoom = await _notifications.isKnownRoom(target);
    if (!mounted) return;
    if (!knownRoom) {
      // A stale push never selects or creates a guessed session.
      injector.get<SessionSelection>().clear();
      _router.go('/home');
      await _showCredentialInstructions(target);
      return;
    }
    final storage = injector.get<PairingStorage>();
    final peers = await storage.listPeers();
    final peer = peers
        .where((p) => toStandardB64(p.remoteEpk) == toStandardB64(target.peer))
        .firstOrNull;
    if (peer == null || !mounted) return;
    await _openPane(peer, target.room);
    if (!mounted) return;
    await _showCredentialInstructions(target);
  }

  Future<void> _showCredentialInstructions(NotificationTarget target) async {
    if (target.kind != 'credential_needed') return;
    // A structured request_credential push carries the request id as its
    // event id; the chat's private form handles it (replayed on session
    // sync). Only the generic blocker gets the instructions dialog.
    if (!target.eventId.endsWith('-credential_needed')) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final dialogContext = _router.routerDelegate.navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    await showDialog<void>(
      context: dialogContext,
      builder: (_) => CredentialNeededDialog(
        onAskPane: () => injector.get<SyncService>().sendMessage(
          CredentialNeededDialog.askPaneMessage,
        ),
      ),
    );
  }

  void _updateVisibleTarget() {
    final path = currentNotificationPath(_router);
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
    _notificationRoutes.dispose();
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
    if (state == AppLifecycleState.resumed) {
      unawaited(_notifications.refresh());
      injector.get<SyncService>().noteAppResumed();
      unawaited(_drainShareInbox());
    }
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
          scaffoldMessengerKey: _messenger,
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
