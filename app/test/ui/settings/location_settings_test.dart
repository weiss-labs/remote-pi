import 'package:app/data/location/phone_location.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class FakeLocation extends PhoneLocation {
  String answer;
  int prompts = 0;
  FakeLocation(this.answer);
  @override
  bool get supported => true;
  @override
  Future<String> requestPermission() async {
    prompts++;
    return answer;
  }

  @override
  Future<void> openSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Preferences> pump(WidgetTester tester, FakeLocation location) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    await tester.pumpWidget(
      ChangeNotifierProvider<Preferences>.value(
        value: prefs,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: LocationSection(location: location)),
        ),
      ),
    );
    return prefs;
  }

  final toggle = find.widgetWithText(
    SwitchListTile,
    'Share location when a pane asks',
  );

  testWidgets('defaults off and never prompts until the user turns it on', (
    tester,
  ) async {
    final location = FakeLocation('authorized');
    final prefs = await pump(tester, location);
    expect(prefs.shareLocation, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(location.prompts, 0);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(location.prompts, 1);
    expect(prefs.shareLocation, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.shareLocation, isFalse);
    expect(location.prompts, 1);
  });

  testWidgets('stays off when iOS permission is denied and says how to fix', (
    tester,
  ) async {
    final location = FakeLocation('denied');
    final prefs = await pump(tester, location);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.shareLocation, isFalse);
    expect(find.textContaining('iOS Settings'), findsOneWidget);
  });
}
