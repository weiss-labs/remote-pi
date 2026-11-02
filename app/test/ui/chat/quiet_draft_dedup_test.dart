import 'dart:convert';
import 'dart:io';

import 'package:app/data/local/records/message_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quiet/quiet_presentation.dart';
import 'package:app/ui/chat/quiet/quiet_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/ui/chat/fixtures/draft-dedup.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final toolText = fixture['tool'] as String;
  final assistant = fixture['assistant'] as String;
  List<QuietItem> fold({
    String? tool,
    String? reply,
    bool finalized = true,
    bool working = false,
  }) => foldQuiet([
    const UserMsg(id: 'user', text: 'Change only the subject.'),
    ToolEvent(
      id: 'draft',
      toolCallId: 'draft',
      tool: 'bash',
      args: const {'command': 'python3 email-preview.py'},
      status: ToolEventStatus.completed,
      result: tool ?? toolText,
    ),
    AssistantMsg(
      id: 'reply',
      text: reply ?? assistant,
      reviewFinalized: finalized,
    ),
  ], working: working);
  int visiblePanels(List<QuietItem> items) => items.fold(
    0,
    (sum, item) =>
        sum +
        switch (item) {
          QuietProminent(:final tool) => draftIdentities(
            resultText(tool.result),
          ).length,
          QuietPass(message: AssistantMsg(:final text)) => draftIdentities(
            text,
          ).length,
          _ => 0,
        },
  );

  test(
    'sanitized real subject-only edit shows one panel and keeps raw step',
    () {
      expect(draftIdentities(toolText), draftIdentities(assistant));
      final items = fold();
      expect(visiblePanels(items), 1);
      expect(
        items.whereType<QuietGroup>().single.steps.single.result,
        toolText,
      );
      expect(items.whereType<QuietProminent>(), isEmpty);
    },
  );
  for (final change in {
    'subject': ['Questions before', 'Changed subject before'],
    'recipient': ['alex@example.test', 'other@example.test'],
    'body': ['Synthetic review content line 2', 'Different body line 2'],
    'attachment': ['example-map.png', 'other-map.png'],
    'preview id': ['synthetic-preview-176', 'other-preview'],
  }.entries) {
    test('different ${change.key} keeps both panels', () {
      expect(
        visiblePanels(
          fold(reply: assistant.replaceFirst(change.value[0], change.value[1])),
        ),
        2,
      );
    });
  }
  test(
    'streaming keeps tool panel even when finalized evidence is present',
    () {
      expect(visiblePanels(fold(working: true)), 2);
    },
  );
  test(
    'an extra incomplete draft in the tool output keeps the tool visible',
    () {
      final extra =
          '$toolText\n┌────────────────────────┐\n│ EMAIL DRAFT            │\n'
          '├──────┬─────────────────┤\n│ To   │ different@example.test';
      expect(draftHeadings(extra), 2);
      expect(draftIdentities(extra).length, 1);
      final items = fold(tool: extra);
      expect(items.whereType<QuietProminent>().single.tool.id, 'draft');
    },
  );

  test('aborted, retry, legacy and incomplete turns retain tool panel', () {
    expect(visiblePanels(fold(finalized: false)), 2);
    expect(visiblePanels(fold(reply: 'No final panel.')), 1);
    expect(visiblePanels(fold(reply: assistant.replaceFirst('└', 'x'))), 1);
  });
  test('previous turn cannot fold a tool panel in a later turn', () {
    final items = foldQuiet([
      AssistantMsg(id: 'old', text: assistant, reviewFinalized: true),
      const UserMsg(id: 'new', text: 'Again'),
      ToolEvent(
        id: 't',
        toolCallId: 't',
        tool: 'bash',
        args: const {},
        result: toolText,
        status: ToolEventStatus.completed,
      ),
    ], working: false);
    expect(items.whereType<QuietProminent>().length, 1);
  });
  test('visible cleanup leaves raw output unchanged', () {
    expect(
      quietDraftOutput(toolText),
      isNot(contains('Using keyring backend')),
    );
    expect(toolText, contains('Using keyring backend'));
  });
  test('agent_done outcome is optional and explicit false is distinct', () {
    expect(AgentDone.fromJson({'in_reply_to': 'u'}).aborted, isNull);
    expect(
      AgentDone.fromJson({'in_reply_to': 'u', 'aborted': false}).aborted,
      false,
    );
    expect(
      AgentDone.fromJson({'in_reply_to': 'u', 'aborted': true}).aborted,
      true,
    );
  });
  test(
    'local completion evidence survives cache projection without changing text',
    () {
      final record = MessageRecord(
        id: 'r',
        seq: 1,
        role: MsgRole.assistant,
        text: assistant,
        reviewFinalized: true,
        ts: DateTime(2026),
      );
      final restored =
          MessageRecord.fromJson(record.toJson()).toChatMessage()
              as AssistantMsg;
      expect(restored.reviewFinalized, true);
      expect(restored.text, assistant);
      final legacy = Map<String, dynamic>.from(record.toJson())
        ..remove('review_finalized');
      expect(
        (MessageRecord.fromJson(legacy).toChatMessage() as AssistantMsg)
            .reviewFinalized,
        false,
      );
    },
  );
}
