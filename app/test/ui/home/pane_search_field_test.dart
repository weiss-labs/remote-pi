import 'package:app/ui/home/widgets/pane_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('X appears with text and clears the search', (tester) async {
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaneSearchField(query: '', onChanged: queries.add),
        ),
      ),
    );
    final clear = find.byTooltip('Clear search');
    expect(clear, findsNothing);

    await tester.enterText(find.byType(TextField), 'main');
    await tester.pump();
    expect(clear, findsOneWidget);

    await tester.tap(clear);
    await tester.pump();
    expect(queries.last, '');
    expect(find.text('main'), findsNothing);
    expect(clear, findsNothing);
  });
}
