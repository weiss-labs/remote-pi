import 'dart:async';
import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/credential_request_sheet.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CredentialRequest _request() => CredentialRequest(
  id: 'req-1',
  macKey: 'mac',
  room: 'room',
  session: 's',
  expiresAt: DateTime.now().millisecondsSinceEpoch + 600000,
  label: 'Stripe secret key (live)',
  reference: '1Password → Weiss Labs → Stripe live → secret key',
  purpose: 'Create the payment link for this task.',
  macEpk: 'epk',
  sig: 'sig',
);

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required Future<void> Function(Uint8List) onSubmit,
  Future<void> Function()? onCancel,
  String? error,
  bool submitting = false,
  double keyboard = 300,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: CredentialRequestSheet(
          request: _request(),
          error: error,
          submitting: submitting,
          onSubmit: onSubmit,
          onCancel: onCancel ?? () async {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final width in [320.0, 390.0, 440.0]) {
    testWidgets('compact masked form fits at $width with the keyboard up', (
      tester,
    ) async {
      await _pump(tester, width: width, onSubmit: (_) async {});
      expect(tester.takeException(), isNull);
      expect(find.text('Credential needed'), findsOneWidget);
      expect(find.text('Stripe secret key (live)'), findsOneWidget);
      expect(find.text('Find in 1Password'), findsOneWidget);
      expect(
        find.textContaining('Weiss Labs → Stripe live → secret key'),
        findsOneWidget,
      );
      expect(find.textContaining('Create the payment link'), findsOneWidget);
      expect(find.textContaining('Desktop authorization'), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('credential-field')),
      );
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, contains(AutofillHints.password));
      expect(
        tester.getSize(find.byKey(const ValueKey('credential-use'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('credential-paste'))).height,
        greaterThanOrEqualTo(44),
      );
    });
  }

  testWidgets(
    'typed value is submitted as exact bytes and the field is cleared',
    (tester) async {
      Uint8List? got;
      await _pump(
        tester,
        width: 390,
        onSubmit: (b) async => got = Uint8List.fromList(b),
      );
      final use = find.byKey(const ValueKey('credential-use'));
      expect(tester.widget<FilledButton>(use).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('credential-field')),
        'sk_test_synthetic ✓',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(use).onPressed, isNotNull);
      await tester.tap(use);
      await tester.pump();
      expect(got, Uint8List.fromList(utf8.encode('sk_test_synthetic ✓')));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('credential-field')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'Paste keeps multi-line text exact behind a masked summary; Clear wipes it',
    (tester) async {
      const key =
          '-----BEGIN SYNTHETIC KEY-----\nabc\ndef==\n-----END SYNTHETIC KEY-----\n';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': key};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Uint8List? got;
      await _pump(
        tester,
        width: 320,
        onSubmit: (b) async => got = Uint8List.fromList(b),
      );
      await tester.tap(find.byKey(const ValueKey('credential-paste')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('credential-pasted')), findsOneWidget);
      expect(find.textContaining('4 lines'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC'), findsNothing);
      expect(find.byKey(const ValueKey('credential-field')), findsNothing);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(find.byKey(const ValueKey('credential-field')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('credential-paste')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-use')));
      await tester.pump();
      expect(got, Uint8List.fromList(utf8.encode(key)));
    },
  );

  testWidgets(
    'background wipes typed plaintext but keeps the form; cancel and back route to onCancel; errors show',
    (tester) async {
      var cancels = 0;
      await _pump(
        tester,
        width: 390,
        onSubmit: (_) async {},
        onCancel: () async => cancels++,
        error: 'The Mac did not accept it.',
      );
      expect(find.byKey(const ValueKey('credential-error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('credential-field')),
        'typed',
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('credential-field')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Credential needed'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(cancels, 1);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(cancels, 2);
    },
  );

  testWidgets('a clipboard read that completes after background is dropped', (
    tester,
  ) async {
    final gate = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          await gate.future;
          return <String, dynamic>{'text': 'late-synthetic-value'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, width: 390, onSubmit: (_) async {});
    await tester.tap(find.byKey(const ValueKey('credential-paste')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('credential-pasted')), findsNothing);
    expect(find.byKey(const ValueKey('credential-field')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('credential-use')))
          .onPressed,
      isNull,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('submitting disables inputs', (tester) async {
    await _pump(tester, width: 390, onSubmit: (_) async {}, submitting: true);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('credential-field')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('credential-use')))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Cancel and back stay available while delivery is unconfirmed.
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('credential-cancel')))
          .onPressed,
      isNotNull,
    );
  });
}
