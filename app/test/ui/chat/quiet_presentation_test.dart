// Plan/75 — quiet mode wording and fold rules. The fixtures mirror the
// desktop extension's test-failures-messages.mjs / test-grouped.mjs so the
// phone says the same things as the Mac.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/quiet/quiet_presentation.dart';
import 'package:app/ui/chat/quiet/quiet_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

ToolEvent _tool(
  String name, {
  dynamic args = const <String, dynamic>{},
  dynamic result,
  String? error,
  ToolEventStatus? status,
  DateTime? ts,
  String? id,
}) => ToolEvent(
  id: id ?? name,
  ts: ts,
  toolCallId: id ?? name,
  tool: name,
  args: args,
  result: result,
  error: error,
  status:
      status ??
      (error != null ? ToolEventStatus.failed : ToolEventStatus.completed),
);

void main() {
  group('summary / liveSummary', () {
    test('short labels match the desktop wording', () {
      expect(summary('read', {'path': '/a/b/file.md'}), 'Read file.md');
      expect(summary('edit', {'file_path': 'x/y.dart'}), 'Edit y.dart');
      expect(summary('bash', {'command': 'npm test'}), 'Run tests');
      expect(
        summary('bash', {'command': 'flutter test --no-pub'}),
        'Run tests',
      );
      expect(summary('bash', {'command': 'rg foo'}), 'Search files');
      expect(summary('bash', {'command': 'git status'}), 'Check Git');
      expect(summary('bash', {'command': 'make'}), 'Run command');
      expect(summary('mcp__custom-tools__codemode', {}), 'Run tool script');
      expect(summary('agent_send', {'to': '/x@Main›Ads'}), 'Contact Main›Ads');
      expect(
        summary('chrome_navigate', {'url': 'https://example.com/p'}),
        'Open example.com',
      );
      expect(
        summary('mcp__firecrawl__firecrawl_scrape', {'url': 'https://a.b/c'}),
        'Read a.b',
      );
      expect(summary('observe_ui', {}), 'Observe ui');
    });

    test('live status is present tense', () {
      expect(liveSummary('read', {'path': 'file.md'}), 'Reading file.md');
      expect(liveSummary('bash', {'command': 'npm test'}), 'Running tests');
      expect(liveSummary('chrome_screenshot', {}), 'Taking a screenshot');
      expect(
        liveSummary('mcp__x__whatsapp_read', {}),
        'Reading WhatsApp messages',
      );
      expect(liveSummary('observe_ui', {}), 'Using observe ui');
    });
  });

  group('presentation', () {
    test(
      'failures get a plain-English reason only when the text supports it',
      () {
        const cases = [
          ('bash', 'unknown option --oops', 'option not accepted'),
          ('read', 'ENOENT no such file', 'file not found'),
          ('write', 'Permission denied', 'access denied'),
          ('edit', 'File not found', 'file not found'),
          ('chrome_click', 'Element not found', 'target not found'),
          ('observe_ui', 'No matching control', 'target not found'),
          (
            'mcp__firecrawl__firecrawl_search',
            'HTTP 429 rate limit',
            'service rate limit',
          ),
          ('codemode', 'ETIMEDOUT', 'timed out'),
          ('agent_send', 'ECONNREFUSED', 'connection refused'),
          ('custom', 'opaque failure detail', 'the tool reported a failure'),
        ];
        for (final (name, text, reason) in cases) {
          final view = presentation(_tool(name, error: text));
          expect(view.failed, isTrue, reason: name);
          expect(view.prominent, isFalse, reason: name);
          expect(view.label, contains(reason), reason: name);
        }
        expect(
          presentation(_tool('bash', error: 'unknown option')).label,
          'Could not run the command (option not accepted)',
        );
        expect(
          presentation(
            _tool('read', args: {'path': 'file.md'}, error: 'ENOENT'),
          ).label,
          'Could not read file.md (file not found)',
        );
        expect(
          presentation(_tool('chrome_click', error: 'target not found')).label,
          'Could not use the browser (target not found)',
        );
        expect(
          presentation(_tool('agent_send', error: 'connection refused')).label,
          'Could not reach the other pane (connection refused)',
        );
      },
    );

    test(
      'structured failure fields and exit codes count; read output never does',
      () {
        for (final text in [
          '{"success":false,"reason":"not_eligible"}',
          '{"error":{"message":"oops"}}',
          '{"status":"failed"}',
        ]) {
          expect(
            presentation(_tool('mcp__service__tool', result: text)).failed,
            isTrue,
          );
        }
        expect(
          presentation(
            _tool('bash', result: 'Command exited with code 2'),
          ).failed,
          isTrue,
        );
        expect(
          presentation(
            _tool('read', result: '{"success":false,"error":"x"}'),
          ).failed,
          isFalse,
        );
        expect(
          presentation(
            _tool('read', result: 'catch (error) { Failed: 0 }'),
          ).failed,
          isFalse,
        );
        expect(
          presentation(
            _tool('read', result: 'Approval required in this source example'),
          ).prominent,
          isFalse,
        );
        expect(
          presentation(_tool('bash', result: '52 passed, 0 failed')).failed,
          isFalse,
        );
      },
    );

    test('human actions become one prominent line', () {
      expect(
        presentation(_tool('custom', error: 'Approval required')).label,
        "Approval needed. Open this step's preview.",
      );
      expect(
        presentation(_tool('custom', error: 'Blocked by send guard')).label,
        "Action blocked. Open this step's preview.",
      );
      expect(
        presentation(_tool('custom', error: 'Sign-in required')).label,
        "Sign-in needed. Open this step's preview.",
      );
      expect(
        presentation(
          _tool(
            'custom',
            result: 'Chrome control is locked. Run /chrome authorize',
          ),
        ).label,
        "Chrome is locked on the Mac. Open this step's preview.",
      );
      for (final text in [
        'Approval required',
        'Blocked by send guard',
        'Sign-in required',
      ]) {
        expect(presentation(_tool('custom', error: text)).prominent, isTrue);
      }
    });

    test('exact draft/approval panels are full-detail, in args or results', () {
      final r = presentation(
        _tool('custom', result: 'EMAIL DRAFT\nExact body'),
      );
      expect(r.draft, isTrue);
      expect(r.prominent, isTrue);
      expect(r.label, 'Needs your approval, shown in full');
      expect(
        presentation(
          _tool('codemode', args: {'code': '┌──┐\n│ WHATSAPP DRAFT │'}),
        ).draft,
        isTrue,
      );
      expect(
        presentation(_tool('custom', result: 'SMS DRAFT\nhi')).draft,
        isTrue,
      );
      expect(
        presentation(_tool('custom', result: 'PAYMENT APPROVAL\n\$40')).draft,
        isTrue,
      );
      expect(
        presentation(
          _tool('custom', result: 'deployment approval granted earlier'),
        ).draft,
        isFalse,
      );
    });

    test('terminal escapes are stripped from shown text', () {
      expect(sanitize('\x1b[31mred\x1b[0m \x1b]0;title\x07ok'), 'red ok');
    });
  });

  group('incoming messages', () {
    test('mesh address → last two pane segments, underscores to spaces', () {
      expect(
        meshLabel('/tmp@William›Main›FB_Ads'),
        'Message from Main / FB Ads',
      );
      expect(meshLabel('/tmp@Demo_Main›Ads'), 'Message from Demo Main / Ads');
      expect(meshLabel('solo'), 'Message from solo');
      expect(meshLabel(null), 'Message from another pane');
    });

    test('desktop parity for the other custom notice types', () {
      expect(
        incomingLabel(
          'remote-pi:mesh-message',
          '[agent-network] message from "/tmp@William›Main›FB_Ads" (id=x):\nbody',
        ),
        'Message from Main / FB Ads',
      );
      expect(
        incomingLabel(
          'herdr-thread',
          '#1 2026-10-30 [worker Mincha skill] result: x',
        ),
        'Update from worker Mincha skill',
      );
      expect(
        incomingLabel('herdr-fleet', '#2 2026-10-30 [main Dagim] progress: x'),
        'Update from main Dagim',
      );
      expect(
        incomingLabel('herdr-fleet', '#1 [a] x\n#2 [b] y'),
        'Updates from client panes',
      );
      expect(
        incomingLabel('herdr-thread', 'nothing'),
        'Updates from this workspace',
      );
      expect(
        incomingLabel('herdr-worker-inbox', 'Saved results ready'),
        'Worker results received',
      );
      expect(
        incomingLabel('pi-voice-transcript', 'x', attribution: 'Voice pane'),
        'Voice handoff from Voice pane',
      );
      expect(incomingLabel('pi-voice-transcript', 'x'), 'Voice handoff');
    });

    test('an agent-network tool event is a notice, not a step', () {
      final mesh = _tool(
        'agent-network',
        id: 'mesh_1',
        args: {'from': '/tmp@William›Main›FB_Ads', 'message': 'FULL_PRIVATE'},
        result: {'from': '/tmp@William›Main›FB_Ads', 'message': 'FULL_PRIVATE'},
      );
      final items = foldQuiet([mesh, _tool('bash', id: 'b')], working: false);
      expect(
        items.whereType<QuietNotice>().single.label,
        'Message from Main / FB Ads',
      );
      expect(items.whereType<QuietGroup>().single.steps.map((s) => s.id), [
        'b',
      ]);
      expect(resultText(mesh.result), 'FULL_PRIVATE');
    });
  });

  group('foldQuiet', () {
    final t0 = DateTime(2026, 10, 30, 12, 0, 0);
    test(
      'a normal run folds into one timed row whose count matches its steps',
      () {
        final msgs = <ChatMessage>[
          UserMsg(id: 'u', ts: t0, text: 'go'),
          _tool(
            'read',
            id: 'a',
            ts: t0.add(const Duration(seconds: 1)),
            args: {'path': 'x.md'},
          ),
          _tool(
            'bash',
            id: 'b',
            ts: t0.add(const Duration(seconds: 5)),
            args: {'command': 'npm test'},
          ),
          _tool(
            'bash',
            id: 'c',
            ts: t0.add(const Duration(seconds: 50)),
            args: {'command': 'bad'},
            error: 'Error: unknown option\nprivate diagnostic detail',
          ),
          _tool(
            'bash',
            id: 'd',
            ts: t0.add(const Duration(seconds: 60)),
            args: {'command': 'good'},
          ),
          AssistantMsg(
            id: 'r',
            ts: t0.add(const Duration(minutes: 2, seconds: 5)),
            text: 'done',
          ),
        ];
        final before = List<ChatMessage>.of(msgs);
        final items = foldQuiet(msgs, working: false);
        expect(items.map((i) => i.runtimeType), [
          QuietPass,
          QuietGroup,
          QuietPass,
        ]);
        final g = items[1] as QuietGroup;
        expect(g.label, 'Worked for 2m 4s · 4 steps');
        expect(g.views.map((v) => v.label), [
          'Read x.md',
          'Run tests',
          'Could not run the command (option not accepted)',
          'Run command',
        ]);
        expect(g.views[2].failed, isTrue);
        expect(
          g.views.any((v) => v.label.contains('private diagnostic')),
          isFalse,
        );
        // Raw messages unchanged.
        for (var i = 0; i < msgs.length; i++) {
          expect(identical(msgs[i], before[i]), isTrue);
        }
        expect(
          (msgs[3] as ToolEvent).error,
          contains('private diagnostic detail'),
        );
      },
    );

    test('historical sessions without timestamps show a count only', () {
      final items = foldQuiet([
        const UserMsg(id: 'u', text: 'go'),
        _tool('read', id: 'a', ts: DateTime.fromMillisecondsSinceEpoch(0)),
        _tool('read', id: 'b'),
        AssistantMsg(
          id: 'r',
          ts: DateTime.fromMillisecondsSinceEpoch(0),
          text: 'ok',
        ),
      ], working: false);
      expect((items[1] as QuietGroup).label, '2 steps');
      final one = foldQuiet([_tool('read', id: 'a')], working: false);
      expect((one.single as QuietGroup).label, '1 step');
    });

    test(
      'the live trailing run is the status line, not a row; done when the reply lands',
      () {
        final live = [
          UserMsg(id: 'u', ts: t0, text: 'go'),
          _tool(
            'bash',
            id: 'a',
            ts: t0,
            args: {'command': 'npm test'},
            status: ToolEventStatus.pending,
          ),
        ];
        expect(foldQuiet(live, working: true).whereType<QuietGroup>(), isEmpty);
        expect(liveStatusLabel(live), 'Running tests');
        expect(liveStatusLabel([live.first]), 'Thinking');
        expect(
          liveStatusLabel([live.first, _tool('bash', id: 'a', ts: t0)]),
          'Working',
        );
        // Cancelled mid-run (not working, no reply): the row still appears.
        expect(
          foldQuiet(live, working: false).whereType<QuietGroup>().single.label,
          '1 step',
        );
      },
    );

    test(
      'approval holds and drafts stay out of the count and keep their place',
      () {
        final items = foldQuiet([
          _tool('read', id: 'a', ts: t0),
          _tool(
            'custom',
            id: 'hold',
            ts: t0,
            error: 'Approval required: confirm before sending',
          ),
          _tool(
            'custom',
            id: 'draft',
            ts: t0,
            result: 'EMAIL DRAFT\nExact body',
          ),
          AssistantMsg(
            id: 'r',
            ts: t0.add(const Duration(seconds: 3)),
            text: 'waiting',
          ),
        ], working: false);
        expect(items.map((i) => i.runtimeType), [
          QuietGroup,
          QuietProminent,
          QuietProminent,
          QuietPass,
        ]);
        expect((items[0] as QuietGroup).label, 'Worked for 3s · 1 step');
        expect((items[1] as QuietProminent).view.draft, isFalse);
        expect((items[2] as QuietProminent).view.draft, isTrue);
      },
    );

    test('image paths in output are listed, Mac paths only, deduplicated', () {
      final paths = imagePaths(
        'Saved /tmp/rp/shot.png and file:///Users/z/a b.jpeg again /tmp/rp/shot.png; https://x.y/z.png',
      );
      expect(paths, ['/tmp/rp/shot.png', '/Users/z/a b.jpeg']);
    });
  });

  test(
    'image blocks: marker lines become preview URLs and stay out of the text',
    () {
      const raw =
          '[remote-pi image 2: pi-tool-image:call%7C1/1]\n'
          '[remote-pi image 3: pi-tool-image:call%7C1/2]';
      expect(toolImageUrls(raw), [
        'pi-tool-image:call%7C1/1',
        'pi-tool-image:call%7C1/2',
      ]);
      expect(resultText(raw), '');
      expect(
        resultText('saved\n[remote-pi image 1: pi-tool-image:a/0]'),
        'saved',
      );
      expect(toolImageUrls('[remote-pi image 1: https://evil/x]'), isEmpty);
    },
  );
}
