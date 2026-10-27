import 'dart:async';
import 'package:app/domain/contracts/notifications.dart';
import 'package:go_router/go_router.dart';

/// The delegate state includes imperative pushes and async redirect results.
/// RouteInformationProvider does not notify for every redirect or pop.
String currentNotificationPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.isEmpty
    ? '/boot'
    : router.routerDelegate.state.uri.path;

class NotificationRoutes {
  final GoRouter router;
  final Future<void> Function(NotificationTarget) open;
  final void Function() routeChanged;
  late final StreamSubscription<NotificationTarget> _taps;
  final List<NotificationTarget> _pending = [];
  bool _disposed = false, _opening = false, _scheduled = false;
  NotificationRoutes({
    required this.router,
    required Stream<NotificationTarget> taps,
    required this.open,
    required this.routeChanged,
  }) {
    _taps = taps.listen((target) {
      _pending.add(target);
      _changed();
    });
    router.routerDelegate.addListener(_changed);
    _changed();
  }
  void _changed() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_disposed) return;
      routeChanged();
      if (!_opening && _pending.isNotEmpty && _ready) unawaited(_drain());
    });
  }

  bool get _ready =>
      {'/home', '/chat', '/settings'}.contains(currentNotificationPath(router));
  Future<void> _drain() async {
    _opening = true;
    try {
      while (!_disposed && _ready && _pending.isNotEmpty) {
        await open(_pending.removeAt(0));
      }
    } finally {
      _opening = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    _taps.cancel();
    router.routerDelegate.removeListener(_changed);
  }
}
