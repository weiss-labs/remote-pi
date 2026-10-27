import 'dart:async';
import 'package:app/domain/contracts/notifications.dart';
import 'package:app/routing/notification_routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'cold tap queued before async boot redirect opens without later user navigation',
    (tester) async {
      final ready = ValueNotifier(false);
      final taps = StreamController<NotificationTarget>.broadcast();
      final router = GoRouter(
        initialLocation: '/boot',
        refreshListenable: ready,
        redirect: (_, state) =>
            ready.value && state.uri.path == '/boot' ? '/home' : null,
        routes: [
          for (final path in ['/boot', '/home', '/chat', '/settings'])
            GoRoute(
              path: path,
              builder: (_, _) => Scaffold(body: Text(path)),
            ),
        ],
      );
      final opened = <NotificationTarget>[];
      final coordinator = NotificationRoutes(
        router: router,
        taps: taps.stream,
        routeChanged: () {},
        open: (target) async {
          opened.add(target);
          router.push('/chat');
        },
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      taps.add(const NotificationTarget('paired', 'room-a', 'cold'));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text('/boot'), findsOneWidget);
      // Same redirect/refresh sequence as _BootState completing its network pull.
      ready.value = true;
      await tester.pumpAndSettle();
      expect(opened.single.eventId, 'cold');
      expect(currentNotificationPath(router), '/chat');
      router.pop();
      await tester.pumpAndSettle();
      router.push('/settings');
      await tester.pumpAndSettle();
      expect(opened.length, 1);
      expect(currentNotificationPath(router), '/settings');
      coordinator.dispose();
      await taps.close();
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      ready.dispose();
    },
  );
  testWidgets(
    'popping pushed chat clears native visibility even when selection stays set',
    (tester) async {
      final taps = StreamController<NotificationTarget>.broadcast();
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
          GoRoute(
            path: '/chat',
            builder: (_, _) => const Scaffold(body: Text('Chat')),
          ),
        ],
      );
      final nativeTargets = <(String?, String?)>[];
      // Selection intentionally remains unchanged after pop, matching phone UI.
      const selectedPeer = 'paired';
      const selectedRoom = 'room-a';
      final coordinator = NotificationRoutes(
        router: router,
        taps: taps.stream,
        open: (_) async {},
        routeChanged: () {
          final visible = currentNotificationPath(router) == '/chat';
          nativeTargets.add((
            visible ? selectedPeer : null,
            visible ? selectedRoom : null,
          ));
        },
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(nativeTargets.last, (null, null));
      router.push('/chat');
      await tester.pumpAndSettle();
      expect(nativeTargets.last, (selectedPeer, selectedRoom));
      router.pop();
      await tester.pumpAndSettle();
      expect(nativeTargets.last, (null, null));
      expect(find.text('Home'), findsOneWidget);
      coordinator.dispose();
      await taps.close();
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    },
  );
}
