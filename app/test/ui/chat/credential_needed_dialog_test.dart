import 'package:app/domain/entities/notification_preferences.dart';
import 'package:app/ui/chat/widgets/credential_needed_dialog.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'credential guidance is actionable, Mac-local and never secret input',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(body: CredentialNeededDialog()),
        ),
      );
      expect(find.text('Complete sign-in on your Mac'), findsOneWidget);
      expect(
        find.textContaining('Open the requesting pane on your Mac'),
        findsOneWidget,
      );
      expect(find.textContaining('does not unlock your Mac'), findsOneWidget);
      expect(find.textContaining('Do not paste passwords'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Understood')).height,
        greaterThanOrEqualTo(44),
      );
      final target = NotificationTarget.parse({
        'v': 1,
        'peer': 'paired',
        'room': 'room',
        'event_id': 'e',
        'kind': 'credential_needed',
      });
      expect(target?.kind, 'credential_needed');
    },
  );
}
