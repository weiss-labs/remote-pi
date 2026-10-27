import 'dart:async';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/notifications.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class EmptyPairings extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [];
}

class FakeNotifications extends Notifications {
  final updates = StreamController<void>.broadcast();
  int prompts = 0;
  @override
  NotificationPreferences preferences = const NotificationPreferences();
  @override
  String get permission => 'notDetermined';
  @override
  String get status => 'Off';
  @override
  bool get supported => true;
  @override
  Stream<void> get changes => updates.stream;
  @override
  Stream<NotificationTarget> get taps => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> requestPermission() async {
    prompts++;
  }

  @override
  Future<void> update(NotificationPreferences value) async {
    preferences = value;
    updates.add(null);
  }

  @override
  Future<void> openSettings() async {}
  @override
  Future<void> visibleTarget(String? peer, String? room) async {}
  @override
  Future<bool> acceptTap(NotificationTarget target) async => false;
  @override
  Future<bool> isKnownRoom(NotificationTarget target) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('settings prompts only on enable and toggles have 44pt targets', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final storage = EmptyPairings();
    final conn = ConnectionManager(
      factory: (_, _) => throw StateError('No network in UI test'),
      storage: storage,
    );
    final notifications = FakeNotifications();
    final vm = SettingsViewModel(storage, prefs, conn, null, notifications);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<Preferences>.value(value: prefs),
          ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
        ],
        child: MaterialApp(theme: buildDarkTheme(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(notifications.prompts, 0);
    expect(find.textContaining('not a Focus override'), findsOneWidget);
    final allow = find.widgetWithText(SwitchListTile, 'Allow notifications');
    await tester.ensureVisible(allow);
    await tester.pumpAndSettle();
    expect(tester.getSize(allow).height, greaterThanOrEqualTo(44));
    await tester.tap(allow);
    await tester.pumpAndSettle();
    expect(notifications.prompts, 1);
    expect(notifications.preferences.enabled, true);
    final input = find.widgetWithText(SwitchListTile, 'Input needed');
    await tester.ensureVisible(input);
    await tester.pumpAndSettle();
    expect(tester.getSize(input).height, greaterThanOrEqualTo(44));
    expect(notifications.preferences.categories.contains('input_needed'), true);
    final credential = find.widgetWithText(
      SwitchListTile,
      'Credential or sign-in needed',
    );
    await tester.ensureVisible(credential);
    await tester.pumpAndSettle();
    expect(tester.getSize(credential).height, greaterThanOrEqualTo(44));
    expect(
      notifications.preferences.categories.contains('credential_needed'),
      true,
    );
    expect(
      find.text('Priority delivery. A pane needs sign-in or credentials.'),
      findsOneWidget,
    );
    await tester.tap(credential);
    await tester.pumpAndSettle();
    expect(
      notifications.preferences.categories.contains('credential_needed'),
      false,
    );
    expect(notifications.prompts, 1);
    final privacy = find.widgetWithText(SwitchListTile, 'Show pane name');
    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();
    expect(notifications.preferences.showPaneName, false);
    await tester.tap(privacy);
    await tester.pumpAndSettle();
    expect(notifications.preferences.showPaneName, true);
    expect(notifications.prompts, 1);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
    conn.dispose();
    prefs.dispose();
    await notifications.updates.close();
  });
}
