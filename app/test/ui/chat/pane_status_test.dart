import 'package:app/ui/chat/widgets/pane_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structured footer parses; legacy terminal text is ignored', () {
    final f = PaneFooter.parse(
      '{"v":1,"ctxPct":33.6,"model":"GPT-6 Astra","thinking":"high",'
      '"usage":{"provider":"Codex","windows":[{"label":"weekly","leftPercent":40,"resetsAtMs":0},'
      '{"label":"5h","leftPercent":90,"resetsAtMs":null}]}}',
    )!;
    expect(f.ctxPct, 33.6);
    expect(f.model, 'GPT-6 Astra');
    expect(f.thinking, 'high');
    expect(f.usage!.windows.map((w) => w.name), ['Session', 'Weekly']);
    expect(f.usage!.windows.first.resetsAt, isNull);
    final codex = PaneFooter.parse(
      '{"v":1,"usage":{"provider":"Codex","email":"a@b.c","extra":"+62,500 credits","windows":[]}}',
    )!.usage!;
    expect([codex.email, codex.extra], ['a@b.c', '+62,500 credits']);
    expect(PaneFooter.parse('↑7.9M ↓1.0M CH99.9% 33.6%/1.0M\ngpt-6-astra'), isNull);
    expect(PaneFooter.parse(null), isNull);
  });
}
