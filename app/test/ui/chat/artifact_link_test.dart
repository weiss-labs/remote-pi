import 'dart:async';
import 'package:app/data/credentials/credential_request_controller.dart';
import 'package:app/domain/contracts/artifact_preview.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class PreviewChat extends ChangeNotifier implements ChatViewModel {
  @override
  CredentialRequestController? get credentials => null;
  final result = Completer<void>();
  String? requested;
  int cancellations = 0;
  @override
  Future<void> previewArtifact(String url, void Function(double) progress) {
    requested = url;
    progress(0.5);
    return result.future;
  }

  @override
  Future<void> cancelArtifact() async {
    cancellations++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<PreviewChat> tapFile(WidgetTester tester) async {
    final vm = PreviewChat();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatViewModel>.value(
        value: vm,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(
            body: AgentMarkdown('[Synthetic PDF](file:///tmp/synthetic.pdf)'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Synthetic PDF'));
    await tester.pumpAndSettle();
    expect(vm.requested, 'file:///tmp/synthetic.pdf');
    expect(find.text('File preview'), findsOneWidget);
    return vm;
  }

  testWidgets(
    'PDF link uses paired preview and dismisses after native completion',
    (tester) async {
      final vm = await tapFile(tester);
      vm.result.complete();
      await tester.pumpAndSettle();
      expect(find.text('File preview'), findsNothing);
      expect(vm.cancellations, 1);
    },
  );
  testWidgets('PDF denial displays honest error, no local URL fallback', (
    tester,
  ) async {
    final vm = await tapFile(tester);
    vm.result.completeError(
      const ArtifactFailure('Not authorized for preview.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not authorized for preview.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(vm.cancellations, 1);
  });
  testWidgets(
    'cancel button cancels operation, late completion cannot reopen',
    (tester) async {
      final vm = await tapFile(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(vm.cancellations, 1);
      vm.result.complete();
      await tester.pumpAndSettle();
      expect(find.text('File preview'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
