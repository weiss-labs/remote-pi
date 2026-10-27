import 'package:app/domain/entities/notification_preferences.dart';
import 'package:app/ui/chat/widgets/credential_needed_dialog.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'generic credential guidance names the private path, never collects a secret, and can ask the pane',
    (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(
            body: CredentialNeededDialog(onAskPane: () async => asked++),
          ),
        ),
      );
      expect(find.text('Credential needed'), findsOneWidget);
      expect(find.textContaining('exact 1Password item'), findsOneWidget);
      expect(
        find.textContaining('never asks for your 1Password account password'),
        findsOneWidget,
      );
      expect(find.textContaining('Do not paste secrets'), findsOneWidget);
      expect(
        find.textContaining('Desktop authorization required'),
        findsNothing,
      );
      expect(find.byType(TextField), findsNothing);
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Back to pane')).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.text('Ask pane for exact item'));
      await tester.pump();
      expect(asked, 1);
      expect(
        CredentialNeededDialog.askPaneMessage,
        contains('request_credential'),
      );
      expect(CredentialNeededDialog.askPaneMessage, isNot(contains('op://')));
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
