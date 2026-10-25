import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('composer actions retain 44 point touch targets without glow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            onOpenAttach: () {},
            onOpenQuickActions: () {},
            onStartAudio: () {},
          ),
        ),
      ),
    );
    for (final key in [
      'input-bar-action',
      'input-bar-attach',
      'input-bar-quick-actions',
    ]) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
    final action = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const Key('input-bar-action')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((action.decoration! as BoxDecoration).boxShadow, isNull);
  });

  test('terminal palette and base type scale remain explicit', () {
    expect(AppColors.dark.bg, const Color(0xFF0B0E14));
    expect(AppColors.dark.text, const Color(0xFFDEE0E1));
    expect(AppColors.dark.heading, const Color(0xFFCD9A22));
    expect(AppColors.dark.editorBorder, const Color(0xFF5FA8CC));
    expect(AppTypography.dark.mono.fontFamily, kMonoFamily);
    expect(AppTypography.dark.mono.fontSize, 13);
    expect(AppTypography.dark.monoSmall.fontSize, 11);
    expect(AppTypography.dark.sansBody.fontSize, 14);
  });
}
