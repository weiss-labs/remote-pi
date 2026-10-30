// Shared fixtures with the Mac quiet-mode extension
// (~/.local/state/pi-quiet-mode/activity-labels.json → test-activity-labels.mjs).
// Both copies must stay byte-identical so the phone and the Mac say the same
// thing about the same step.

import 'dart:convert';
import 'dart:io';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/quiet/quiet_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixtures =
      jsonDecode(
            File(
              'test/ui/chat/fixtures/activity-labels.json',
            ).readAsStringSync(),
          )
          as List;

  test('every shared fixture produces the Mac label', () {
    final failures = <String>[];
    for (final f in fixtures.cast<Map<String, dynamic>>()) {
      final actual = liveSummary(
        f['tool'] as String,
        f['args'],
        f['intent'] as String?,
      );
      final shaped =
          actual.length <= 40 &&
          !RegExp(r'[.:!?]$').hasMatch(actual) &&
          RegExp(r'^[A-Z]').hasMatch(actual);
      if (actual != f['label'] || !shaped) {
        failures.add('${jsonEncode(f)} -> $actual');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(fixtures.length, greaterThan(100));
  });

  test('every shared notice fixture sorts like the Mac', () {
    final notices =
        jsonDecode(
              File(
                'test/ui/chat/fixtures/notice-views.json',
              ).readAsStringSync(),
            )
            as List;
    final failures = <String>[];
    for (final f in notices.cast<Map<String, dynamic>>()) {
      final v = noticeView(
        f['type'] as String,
        f['text'] as String,
        f['sender'] as String,
      );
      if (v.routine != f['routine'] || v.label != f['label']) {
        failures.add('${jsonEncode(f)} -> ${v.routine} ${v.label}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(notices.length, greaterThanOrEqualTo(30));
  });

  test('live status uses the assistant text right before the call only', () {
    final t0 = DateTime(2026, 10, 30);
    ToolEvent tool(String id, String command) => ToolEvent(
      id: id,
      ts: t0,
      toolCallId: id,
      tool: 'bash',
      args: {'command': command},
    );
    final said = AssistantMsg(
      id: 'a',
      ts: t0,
      text: 'Let me check the release:',
    );
    expect(
      liveStatusLabel([said, tool('t1', 'gh release view')]),
      'Checking the release',
    );
    // A parallel second call is preceded by the first call, not the text.
    expect(
      liveStatusLabel([
        said,
        tool('t1', 'gh release view'),
        tool('t2', 'npm test'),
      ]),
      'Running the tests',
    );
    expect(
      liveStatusLabel([tool('t1', 'python3 -c "print(1)"')]),
      'Checking task details',
    );
  });
}
