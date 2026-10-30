// Plan/75 — quiet mode wording. A port of the desktop extension's
// `summary`, `liveSummary`, `presentation` and `incomingLabel`
// (~/.pi/agent/extensions/quiet-mode.ts) so the phone and the Mac say the
// same things about the same step. Pure Dart: no Flutter, no I/O, never
// mutates the ToolEvent it reads.

import 'dart:convert';

import 'package:app/domain/session_state.dart';

/// How one tool step presents in quiet mode.
///
/// `draft`      → an exact-text approval/draft panel: ALWAYS shown in full.
/// `prominent`  → a human action (approval / sign-in / blocked): one visible
///                line, not folded into the step count.
/// `failed`     → shown with a cross and plain-English wording.
class QuietView {
  final bool draft;
  final bool prominent;
  final bool failed;
  final String label;
  const QuietView({
    required this.draft,
    required this.prominent,
    required this.failed,
    required this.label,
  });
}

String _clean(Object? value) => (value ?? '')
    .toString()
    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _basename(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Strip terminal escape/control sequences before any text is shown.
String sanitize(String text) => text
    .replaceAll(
      RegExp(
        r'(?:\x1b[\]PX^_]|[\x90\x98\x9d-\x9f])[\s\S]*?(?:\x07|\x1b\\|\x9c|$)',
      ),
      '',
    )
    .replaceAll(RegExp(r'(?:\x1b\[|\x9b)[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'\x1b[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');

/// Pretty JSON for arguments and details; never throws.
String prettyJson(Object? value) {
  try {
    return sanitize(const JsonEncoder.withIndent('  ').convert(value));
  } catch (_) {
    return sanitize(value.toString());
  }
}

/// Bare tool name without the `mcp__server__` prefix.
String bareTool(String name) =>
    name.replaceFirst(RegExp(r'^mcp__'), '').split('__').last;

/// Short completed-step label, e.g. "Read file.md", "Run tests".
String summary(String name, dynamic args) {
  final a = args is Map ? args : const {};
  final tool = bareTool(name);
  final file = _clean(
    _basename((a['path'] ?? a['file_path'] ?? 'file').toString()),
  );
  switch (tool) {
    case 'read':
      return 'Read $file';
    case 'write':
      return 'Write $file';
    case 'edit':
      return 'Edit $file';
    case 'bash':
      final command = (a['command'] ?? '').toString().trim();
      if (RegExp(
        r'^(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test\b|^pytest\b|^python3?\s+-m\s+pytest\b|^flutter\s+test\b',
      ).hasMatch(command)) {
        return 'Run tests';
      }
      if (RegExp(r'^(?:rg|grep|find)\b').hasMatch(command)) {
        return 'Search files';
      }
      if (RegExp(r'^ls\b').hasMatch(command)) return 'List files';
      if (RegExp(r'^git\s+(status|diff|log)\b').hasMatch(command)) {
        return 'Check Git';
      }
      return 'Run command';
    case 'codemode':
      return 'Run tool script';
    case 'agent_send':
      return 'Contact ${_clean(a['to'] ?? 'worker').split('@').last}';
    case 'list_peers':
      return 'Find available workers';
    case 'notify_user':
      return 'Notify Zach';
    case 'request_credential':
      return 'Request credential';
  }
  final url = a['url'];
  if (url is String) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isNotEmpty) {
      return '${RegExp(r'navigate|launch').hasMatch(tool) ? 'Open' : 'Read'} $host';
    }
  }
  final label = _clean(tool.replaceAll('_', ' '));
  return label.isEmpty ? 'Tool' : label[0].toUpperCase() + label.substring(1);
}

/// Present-tense status while a step runs, e.g. "Reading file.md".
String liveSummary(String name, dynamic args) {
  final label = summary(name, args);
  if (name.contains('screenshot')) return 'Taking a screenshot';
  if (name.contains('whatsapp')) return 'Reading WhatsApp messages';
  if (name.contains('search')) return 'Searching for information';
  const verbs = {
    'Read': 'Reading',
    'Write': 'Writing',
    'Edit': 'Editing',
    'Run': 'Running',
    'Search': 'Searching',
    'List': 'Listing',
    'Check': 'Checking',
    'Contact': 'Contacting',
    'Find': 'Finding',
    'Notify': 'Notifying',
    'Open': 'Opening',
    'Request': 'Requesting',
  };
  final parts = label.split(' ');
  final verb = verbs[parts.first];
  return verb == null
      ? 'Using ${label.toLowerCase()}'
      : [verb, ...parts.skip(1)].join(' ');
}

final _draftPanel = RegExp(
  r'^[^\p{L}\p{N}\n]*(?:(?:EMAIL|WHATSAPP|IMESSAGE|SMS) DRAFT|(?:[A-Z][A-Z0-9 ]{0,60} )?APPROVAL)\b',
  multiLine: true,
  unicode: true,
);

/// True when any string inside [value] starts a draft/approval panel heading.
bool hasDraftPanel(Object? value, [int depth = 0]) {
  if (depth > 16) return false;
  if (value is String) return _draftPanel.hasMatch(sanitize(value));
  if (value is Map) return value.values.any((v) => hasDraftPanel(v, depth + 1));
  if (value is Iterable) return value.any((v) => hasDraftPanel(v, depth + 1));
  return false;
}

bool _statusFailure(Object? value) {
  if (value is! Map) return false;
  final exit = num.tryParse('${value['exit_code'] ?? value['exitCode'] ?? 0}');
  final errors = value['errors'];
  return value['isError'] == true ||
      value['blocked'] == true ||
      value['success'] == false ||
      value['ok'] == false ||
      (exit != null && exit != 0) ||
      (value['error'] != null &&
          value['error'] != false &&
          value['error'] != '') ||
      (errors is List && errors.isNotEmpty) ||
      RegExp(r'^(?:error|failed|failure)$').hasMatch('${value['status']}');
}

/// Full text of a result as the phone received it (text, or JSON for maps).
String resultText(dynamic result) {
  if (result == null) return '';
  if (result is String) {
    return sanitize(result.replaceAll(_toolImageLine, '').trimRight());
  }
  if (result is Map && result['message'] is String && result['from'] != null) {
    return sanitize(result['message'] as String);
  }
  return prettyJson(result);
}

/// Decide how one tool step presents. Mirrors desktop `presentation()`:
/// draft panels stay full, human actions become one prominent line,
/// failures get a plain-English reason only when the output supports it.
QuietView presentation(ToolEvent tool) {
  final name = tool.tool;
  final isError = tool.status == ToolEventStatus.failed || tool.error != null;
  final text = [resultText(tool.result), sanitize(tool.error ?? '')].join('\n');
  final draft =
      hasDraftPanel(tool.args) ||
      hasDraftPanel(tool.result) ||
      hasDraftPanel(tool.error);

  String? action;
  if (name != 'read' || isError) {
    if (RegExp(
      r'/chrome authorize|chrome control is locked',
      caseSensitive: false,
    ).hasMatch(text)) {
      action = 'Chrome is locked on the Mac. Open this step\'s preview.';
    } else if (RegExp(
      r'\b(?:approval required|needs? (?:your )?approval|permission required|confirmation required|confirm before)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      action = 'Approval needed. Open this step\'s preview.';
    } else if (RegExp(
      r'\b(?:sign.in required|log.in required|credentials? required)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      action = 'Sign-in needed. Open this step\'s preview.';
    } else if (RegExp(
      r'blocked by (?:the )?(?:send|release|approval).*guard|(?:send|release) guard.*(?:blocked|held)',
      caseSensitive: false,
    ).hasMatch(text)) {
      action = 'Action blocked. Open this step\'s preview.';
    }
  }

  var structuredFailure = false;
  if (name != 'read') {
    if (tool.result is Map) structuredFailure = _statusFailure(tool.result);
    if (tool.result is String) {
      try {
        structuredFailure = _statusFailure(jsonDecode(tool.result as String));
      } catch (_) {
        // Ordinary output is not structured status.
      }
    }
  }
  final failed =
      isError ||
      structuredFailure ||
      (name != 'read' &&
          RegExp(
            r'Command exited with code [1-9]|exit code[:\s]+[1-9]',
            caseSensitive: false,
          ).hasMatch(text));

  if (draft) {
    return QuietView(
      draft: true,
      prominent: true,
      failed: failed,
      label: 'Needs your approval, shown in full',
    );
  }
  if (action != null) {
    return QuietView(
      draft: false,
      prominent: true,
      failed: true,
      label: action,
    );
  }
  if (!failed) {
    return QuietView(
      draft: false,
      prominent: false,
      failed: false,
      label: summary(name, tool.args),
    );
  }

  var tried = summary(name, tool.args).toLowerCase();
  if (name == 'bash') {
    tried = tried == 'run command' ? 'run the command' : tried;
  } else if (RegExp(r'chrome_|browser').hasMatch(name)) {
    tried = 'use the browser';
  } else if (RegExp(
    r'^(?:observe|act|search|inspect|expand)_ui$',
  ).hasMatch(name)) {
    tried = 'use the app';
  } else if (RegExp(r'firecrawl|search').hasMatch(name)) {
    tried = 'complete the search';
  } else if (name == 'codemode') {
    tried = 'run the tool script';
  } else if (name == 'agent_send') {
    tried = 'reach the other pane';
  } else if (!RegExp(
    r'^(?:read|write|edit|run|search|list|check|contact|find|notify|open|request)\b',
  ).hasMatch(tried)) {
    tried = 'complete this step';
  }

  var reason = 'the tool reported a failure';
  bool has(String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(text);
  if (has(r'\b(?:ENOENT|no such file|file not found)\b')) {
    reason = 'file not found';
  } else if (has(
    r'element.*not found|target.*not found|no matching (?:element|control)',
  )) {
    reason = 'target not found';
  } else if (has(
    r'unknown option|unrecognized option|illegal option|invalid (?:option|argument)',
  )) {
    reason = 'option not accepted';
  } else if (has(r'timed out|timeout|ETIMEDOUT')) {
    reason = 'timed out';
  } else if (has(r'ECONNREFUSED|connection refused')) {
    reason = 'connection refused';
  } else if (has(r'ENOTFOUND|could not resolve')) {
    reason = 'address not found';
  } else if (has(r'permission denied|access denied|forbidden|\b403\b')) {
    reason = 'access denied';
  } else if (has(r'unauthorized|\b401\b')) {
    reason = 'sign-in not accepted';
  } else if (has(r'rate.limit|\b429\b')) {
    reason = 'service rate limit';
  } else if (has(r'\b50[0234]\b|internal server error')) {
    reason = 'service error';
  } else if (has(r'cancelled|canceled|aborted')) {
    reason = 'cancelled';
  }
  return QuietView(
    draft: false,
    prominent: false,
    failed: true,
    label: 'Could not $tried ($reason)',
  );
}

/// The Mac forwards a mesh message to the phone as a matched
/// `agent-network` tool pair with `args.from` = the sender's pane address.
bool isIncomingMessage(ToolEvent tool) =>
    tool.tool == 'agent-network' && tool.args is Map;

/// One-line label for an incoming pane message. [address] is the mesh
/// address (`/cwd@Workspace›Tab›Pane`): the last two path segments name the
/// sender, underscores become spaces ("Message from Main / FB Ads").
String meshLabel(String? address) {
  final segments = (address ?? '')
      .split('@')
      .last
      .split('›')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) return 'Message from another pane';
  final pane = segments
      .sublist(segments.length > 2 ? segments.length - 2 : 0)
      .join(' / ')
      .replaceAll('_', ' ');
  return 'Message from ${_clean(pane)}';
}

/// Desktop parity for the other custom notice types, keyed by Pi customType.
/// The phone transport only forwards mesh messages today; kept so a future
/// forwarded type reads the same on both screens.
String incomingLabel(String type, String text, {String? attribution}) {
  if (type == 'remote-pi:mesh-message') {
    return meshLabel(
      RegExp(r'message from "([^"]+)"').firstMatch(text)?.group(1),
    );
  }
  if (type == 'pi-voice-transcript') {
    final from = _clean(attribution);
    return from.isEmpty ? 'Voice handoff' : 'Voice handoff from $from';
  }
  if (type == 'herdr-worker-inbox') return 'Worker results received';
  final senders = RegExp(r'^#\d+[^\n]*?\[([^\]]+)\]', multiLine: true)
      .allMatches(text)
      .map(
        (m) =>
            _clean(m.group(1)).replaceAll(RegExp(r'\bw\d+:p\w+\b'), '').trim(),
      )
      .toSet();
  if (senders.length == 1) return 'Update from ${senders.first}';
  return type == 'herdr-fleet'
      ? 'Updates from client panes'
      : 'Updates from this workspace';
}

/// Status line text while a run is active, from the newest row.
String liveStatusLabel(List<ChatMessage> messages) {
  if (messages.isEmpty) return 'Thinking';
  final last = messages.last;
  if (last is UserMsg) return 'Thinking';
  if (last is ToolEvent) {
    final pending =
        last.status == ToolEventStatus.pending ||
        last.status == ToolEventStatus.allowed;
    if (pending && !isIncomingMessage(last)) {
      return liveSummary(last.tool, last.args);
    }
  }
  return 'Working';
}

/// The Mac appends one `[remote-pi image N: pi-tool-image:…]` line per image
/// block a tool returned (images never travel inline). Hidden from the text.
final _toolImageLine = RegExp(
  r'^\[remote-pi image \d+: (pi-tool-image:[^\s\]]+)\]\n?',
  multiLine: true,
);

/// Artifact URLs for a result's image blocks, fetched on demand.
List<String> toolImageUrls(dynamic result) => result is String
    ? [for (final m in _toolImageLine.allMatches(result)) m.group(1)!]
    : const [];

/// Mac image paths named in a tool result, for the preview's image list.
/// Only explicitly returned paths; opened through the authenticated artifact
/// transport, never as URLs the phone could read directly.
List<String> imagePaths(String text) {
  final out = <String>{};
  for (final m in RegExp(
    r'''(?:file://)?(/(?:Users|tmp|var|private)/(?:(?!/(?:Users|tmp|var|private)/)[^\n"'<>;:])*?\.(?:png|jpe?g|webp|gif))(?=[\s"',;:)}\]]|$)''',
    caseSensitive: false,
  ).allMatches(text)) {
    out.add(m.group(1)!);
    if (out.length >= 8) break;
  }
  return out.toList();
}
