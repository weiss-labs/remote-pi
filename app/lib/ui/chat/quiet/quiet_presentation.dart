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

// Live activity labels. The SAME rules live in the Mac extension
// (~/.pi/agent/extensions/quiet-mode.ts `liveSummary`); keep them identical
// and run the shared fixtures in test/ui/chat/fixtures/activity-labels.json.
// Order: the assistant's own "about to" sentence, then a recognized
// operation, then "Checking task details". Never a raw command, path or secret.
const _unknown = 'Checking task details';
const _doubled = {
  'run', 'rerun', 'get', 'set', 'reset', 'put', 'stop', 'plan', 'ship', 'cut',
  'swap', 'drop', 'skip', 'grab', 'scan', 'map', 'tap', 'log', 'commit',
  'submit', 'begin', 'dig', 'pin', 'prep', 'wrap', 'trim', 'tag', 'zip',
  'debug', 'jot', 'sum', 'chat', 'rig', //
};
const _notVerbs = {
  'be', 'have', 'know', 'need', 'want', 'try', 'go', 'do', 'see', 'say',
  'think', 'ask', 'wait', 'keep', //
};
const _ingNouns = {
  'thing', 'something', 'nothing', 'anything', 'everything', 'morning',
  'evening', 'string', 'ceiling', 'during', 'king', 'ring', 'spring',
  'bring', 'sing', 'wing', 'sting', 'swing', //
};
final _captureRe = RegExp(r"^[\p{L}\p{N} ._'-]{1,30}$", unicode: true);
String? _capture(Object? value) {
  final text = _clean(value);
  return _captureRe.hasMatch(text) ? text : null;
}

String? _fileName(Object? value) {
  final parts = (value ?? '')
      .toString()
      .replaceAll(RegExp(r'''^['"]|['"]$'''), '')
      .split('/')
      .where((p) => p.isNotEmpty);
  return _capture(parts.isEmpty ? null : parts.last);
}

String _gerund(String verb) {
  final v = verb.toLowerCase();
  if (_doubled.contains(v)) return '$v${v[v.length - 1]}ing';
  if (v.endsWith('ie')) return '${v.substring(0, v.length - 2)}ying';
  if (RegExp(r'[^aeoy]e$').hasMatch(v)) {
    return '${v.substring(0, v.length - 1)}ing';
  }
  return '${v}ing';
}

/// The assistant's short "about to" sentence as a present-participle label,
/// or null when it is not one.
String? intentLabel(Object? text) {
  final lines = sanitize((text ?? '').toString())
      .replaceAll(RegExp('[‘’]'), "'")
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  final line = lines.isEmpty ? '' : lines.last;
  var sentence = line.split(RegExp(r'[.!?]\s+')).last.trim();
  if (sentence.isEmpty || sentence.endsWith('?')) return null;
  sentence = sentence
      .replaceAll(RegExp(r'[\s:.!…]+$'), '')
      .replaceAll(
        RegExp(r'\s+(?:now|next|first|then|too)$', caseSensitive: false),
        '',
      );
  final match = RegExp(
    r"^(?:(?:ok|okay|now|next|first|then|so|alright|great|good|right)\b[,]?\s+)*(i'll|i will|i'm going to|i am going to|let me|let's|let us|i need to|going to|i'm|i am)?\s*(.*)$",
    caseSensitive: false,
  ).firstMatch(sentence)!;
  final modal = match.group(1)?.toLowerCase();
  final words = match
      .group(2)!
      .replaceAll(
        RegExp(
          r'^(?:(?:now|also|quickly|first|then|just|briefly|next|still|actually)\s+)+',
          caseSensitive: false,
        ),
        '',
      )
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.length < 2) return null;
  final first = words.first.toLowerCase();
  // "I'll check X" names an upcoming action; otherwise only an -ing phrase does.
  final future = modal != null && modal != "i'm" && modal != 'i am';
  if (future
      ? !RegExp(r'^[a-z]{2,}$').hasMatch(first) ||
            _notVerbs.contains(first) ||
            first.endsWith('ing')
      : !RegExp(r'^[a-z]{3,}ing$').hasMatch(first) ||
            _ingNouns.contains(first)) {
    return null;
  }
  final verb = future ? _gerund(first) : first;
  final label = [
    verb[0].toUpperCase() + verb.substring(1),
    ...words.skip(1),
  ].join(' ');
  if (label.length > 40 ||
      !RegExp(r"^[\p{L}\p{N} ,'&.+-]+$", unicode: true).hasMatch(label) ||
      label.contains('..')) {
    return null;
  }
  // Long or mixed letter-digit words look like tokens or IDs, not intent.
  if (words.any(
    (w) =>
        w.length >= 25 ||
        (w.length >= 12 &&
            RegExp(r'\d').hasMatch(w) &&
            RegExp(r'[a-z]', caseSensitive: false).hasMatch(w)),
  )) {
    return null;
  }
  return label;
}

/// Top-level commands, quote-aware; text after a pipe is a filter, not the
/// operation.
List<String> _commands(String command) {
  final out = <String>[];
  var current = StringBuffer();
  var quote = '';
  var piped = false;
  void push() {
    final text = current.toString().trim();
    if (!piped && text.isNotEmpty) out.add(text);
    current = StringBuffer();
  }

  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    final next = i + 1 < command.length ? command[i + 1] : '';
    if (quote.isNotEmpty) {
      if (c == r'\' && quote == '"') {
        current.write(c + next);
        i++;
        continue;
      }
      if (c == quote) quote = '';
      current.write(c);
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      current.write(c);
      continue;
    }
    if (c == r'\') {
      current.write(c + next);
      i++;
      continue;
    }
    if ((c == '&' && next == '&') || (c == '|' && next == '|')) {
      push();
      piped = false;
      i++;
      continue;
    }
    if (c == ';' || c == '\n') {
      push();
      piped = false;
      continue;
    }
    if (c == '|') {
      push();
      piped = true;
      continue;
    }
    current.write(c);
  }
  push();
  return out;
}

typedef _Rule = (
  RegExp,
  Object,
); // label: String or String? Function(RegExpMatch)
const _script = r'^(?:(?:bash|sh|zsh|node|python3?|npx|tsx|bun)\s+)?(?:\S*/)?';
final List<_Rule> _rules = [
  (
    RegExp(
      r'''^node\s+(?:\S*\/)?thread\.js\s+(["'])([\p{L}][\p{L} .-]{0,38})\1(?:\s|$)''',
      unicode: true,
    ),
    (RegExpMatch m) => "Reading ${m.group(2)!.trim()}'s messages",
  ),
  (RegExp('${_script}ship-testflight\\.sh\\b'), 'Uploading to TestFlight'),
  (RegExp('${_script}build-release\\.sh\\b'), 'Installing the Mac extension'),
  (RegExp('${_script}draft\\.py\\b'), 'Preparing the email draft'),
  (RegExp('${_script}panel\\.py\\b'), 'Preparing the email preview'),
  (
    RegExp(r'^python3?\s+\S*worker\.py\b.*\sfinish\b'),
    'Submitting the work handoff',
  ),
  (
    RegExp(r'^python3?\s+\S*worker\.py\b.*\sthread\s+note\b'),
    'Posting an update to the main pane',
  ),
  (RegExp(r'^flutter\s+test\b'), 'Running the app tests'),
  (
    RegExp(
      r'^(?:dart\s+test|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test(?::\S+)?|npx\s+(?:vitest|jest|playwright\s+test)|vitest|jest|pytest|python3?\s+-m\s+(?:pytest|unittest)|cargo\s+(?:test|nextest)|go\s+test|swift\s+test|xcodebuild\s+test|make\s+test)(?:\s|$)',
    ),
    'Running the tests',
  ),
  (
    RegExp(
      r'^(?:node|python3?|bash|sh|npx\s+tsx|tsx)\s+(?:\S*\/)?[\w-]*test[\w.-]*\.(?:mjs|js|ts|py|sh)(?:\s|$)',
    ),
    'Running the tests',
  ),
  (
    RegExp(
      r'^(?:flutter\s+analyze|dart\s+analyze|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:lint|typecheck|check)|npx\s+(?:eslint|tsc)|eslint|tsc\s+--noEmit|cargo\s+(?:clippy|check)|ruff|mypy|swiftlint|dart\s+format|biome)(?:\s|$)',
    ),
    'Checking the code',
  ),
  (RegExp(r'^flutter\s+build\s+ios\b'), 'Building the iOS app'),
  (RegExp(r'^flutter\s+build\b'), 'Building the app'),
  (
    RegExp(
      r'^(?:(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?build|cargo\s+build|xcodebuild|swift\s+build|go\s+build|make|tsc|npx\s+tsc|next\s+build|vite\s+build)(?:\s|$)',
    ),
    'Building the project',
  ),
  (
    RegExp(
      r'^(?:(?:npm|pnpm|yarn|bun)\s+(?:install|i|add|ci)|pip3?\s+install|python3?\s+-m\s+pip\s+install|brew\s+install|(?:flutter|dart)\s+pub\s+(?:get|upgrade|add)|cargo\s+add|pod\s+install|uv\s+(?:sync|add|pip\s+install))(?:\s|$)',
    ),
    'Installing dependencies',
  ),
  (RegExp(r'^git\s+(?:-C\s+\S+\s+)?push\b'), 'Pushing code to GitHub'),
  (RegExp(r'^git\s+(?:-C\s+\S+\s+)?commit\b'), 'Saving a commit'),
  (
    RegExp(r'^git\s+(?:-C\s+\S+\s+)?(?:pull|fetch)\b'),
    'Getting the latest code',
  ),
  (
    RegExp(r'^git\s+(?:-C\s+\S+\s+)?(?:status|diff)\b'),
    'Checking the code changes',
  ),
  (
    RegExp(r'^git\s+(?:-C\s+\S+\s+)?(?:log|show|blame|describe|shortlog)\b'),
    'Checking the code history',
  ),
  (
    RegExp(r'^git\s+(?:-C\s+\S+\s+)?(?:checkout|switch)\b'),
    'Switching branches',
  ),
  (
    RegExp(r'^git\s+(?:-C\s+\S+\s+)?(?:merge|rebase|cherry-pick)\b'),
    'Merging code changes',
  ),
  (RegExp(r'^git\s+(?:-C\s+\S+\s+)?add\b'), 'Staging code changes'),
  (RegExp(r'^git\s+(?:-C\s+\S+\s+)?clone\b'), 'Downloading the code'),
  (
    RegExp(
      r'^git\s+(?:-C\s+\S+\s+)?(?:branch|rev-parse|remote|ls-files|worktree\s+list|stash\s+list|config\s+--get)\b',
    ),
    'Checking the repository',
  ),
  (RegExp(r'^gh\s+pr\s+create\b'), 'Opening a pull request'),
  (RegExp(r'^gh\s+pr\s+merge\b'), 'Merging the pull request'),
  (RegExp(r'^gh\s+release\s+create\b'), 'Publishing a GitHub release'),
  (RegExp(r'^gh\b'), 'Checking GitHub'),
  (
    RegExp(
      r'''^curl\b.*\/(?:health|healthz|status|ping|ready|readyz|version)(?:[\s'"?/]|$)''',
    ),
    'Checking the server',
  ),
  (
    RegExp(
      r'''^(?:curl|wget|http|xh)\b[^|]*?https?:\/\/(?:[^\s/@'"]*@)?([a-z0-9.-]+)''',
      caseSensitive: false,
    ),
    (RegExpMatch m) {
      final host = _capture(m.group(1));
      return host != null ? 'Contacting $host' : 'Contacting a web service';
    },
  ),
  (
    RegExp(
      r'^(?:docker(?:-compose)?\s+(?:ps|compose\s+ps|logs|stats|inspect|images)|systemctl\s+(?:status|is-active|list-units|list-timers)|journalctl|uptime|pm2\s+(?:status|list|ls|logs)|service\s+\S+\s+status|crontab\s+-l|ps\s|ps$)',
    ),
    'Checking the server',
  ),
  (RegExp(r'^(?:df|du|free)(?:\s|$)'), 'Checking disk space'),
  (
    RegExp(
      r'''^(?:cat|head|tail|less|bat|nl|wc|sed\s+-n\s+\S+|jq\s+\S+|plutil\s+-p)\s+(?:-\S+\s+)*(?:\d+\s+)?(["']?[^\s'"|;&<>]+["']?)\s*$''',
    ),
    (RegExpMatch m) {
      final file = _fileName(m.group(1));
      return file != null ? 'Reading $file' : 'Reading files';
    },
  ),
  (RegExp(r'^(?:cat|head|tail|less|bat|nl|wc)\s'), 'Reading files'),
  (
    RegExp(r'^(?:rg|grep|egrep|fgrep|ag|ack|git\s+grep)(?:\s|$)'),
    'Searching the code',
  ),
  (RegExp(r'^(?:find|fd|mdfind|locate)(?:\s|$)'), 'Looking for files'),
  (
    RegExp(r'^(?:ls|tree|stat|file|realpath|pwd)(?:\s|$)'),
    'Looking through files',
  ),
  (RegExp(r'^(?:diff|cmp)(?:\s|$)'), 'Comparing files'),
  (RegExp(r'^scp(?:\s|$)'), 'Copying files to the server'),
  (RegExp(r'^(?:cp|rsync|ditto)(?:\s|$)'), 'Copying files'),
  (RegExp(r'^mv(?:\s|$)'), 'Moving files'),
  (RegExp(r'^(?:rm|trash)(?:\s|$)'), 'Removing files'),
  (RegExp(r'^gws\s+gmail\b.*\bsend\b'), 'Sending the email'),
  (RegExp(r'^gws\s+gmail\b'), 'Checking email'),
  (RegExp(r'^gws\s+calendar\b'), 'Checking the calendar'),
  (RegExp(r'^gws\s+drive\b'), 'Checking Google Drive'),
  (RegExp(r'^gws\b'), 'Using Google Workspace'),
  (RegExp(r'^op\s+(?:read|item|inject|run)\b'), 'Getting a saved credential'),
  (
    RegExp(r'^(?:which|type|command\s+-v)\s|^\S+\s+--version$'),
    'Checking installed tools',
  ),
  (RegExp(r'^launchctl\b'), 'Checking background services'),
  (RegExp(r'^(?:sqlite3|psql|mysql)\b'), 'Checking the database'),
  (RegExp(r'^ffmpeg\b'), 'Processing media'),
  (RegExp(r'^yt-dlp\b'), 'Downloading media'),
  (RegExp(r'^osascript\b'), 'Using an app on the Mac'),
  (RegExp(r'^pbcopy\b'), 'Copying to the clipboard'),
];
final _skip = RegExp(
  r'^(?:cd|export|set|source|\.|unset|echo|printf|true|false|:|mkdir|sleep|trap|local|wait)(?:\s|$)',
);

/// A recognized shell operation as plain English; "Checking task details"
/// when nothing matches.
String commandLabel(Object? command) {
  var slept = false;
  for (var part in _commands((command ?? '').toString())) {
    part = part
        .replaceFirst(
          RegExp(r'''^(?:[A-Za-z_]\w*=(?:'[^']*'|"[^"]*"|\S*)\s+)+'''),
          '',
        )
        .replaceFirst(
          RegExp(r'^(?:(?:sudo|time|env|exec|command|nohup)\s+)+'),
          '',
        )
        .trim();
    final remote = RegExp(
      r'''^ssh(?:\s+-\w+(?:\s+(?!['"])\S+)?)*\s+[\w@.-]+(?:\s+(['"])([\s\S]*)\1)?\s*$''',
    ).firstMatch(part);
    if (remote != null) {
      if (remote.group(2) == null) return 'Connecting to the server';
      final inner = commandLabel(remote.group(2));
      return inner == _unknown ? 'Working on the server' : inner;
    }
    if (_skip.hasMatch(part)) {
      if (RegExp(r'^sleep\b').hasMatch(part)) slept = true;
      continue;
    }
    for (final (pattern, label) in _rules) {
      final m = pattern.firstMatch(part);
      if (m == null) continue;
      final text = label is String
          ? label
          : (label as String? Function(RegExpMatch))(m);
      if (text != null) return text;
    }
    // The real operation is this command; later ones have not started.
    return _unknown;
  }
  return slept ? 'Waiting' : _unknown;
}

String? _host(Object? url) {
  if (url is! String) return null;
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? null : host;
}

/// Present-tense status while a step runs, e.g. "Reading file.md".
/// [intent] is the assistant's visible text immediately before the call.
String liveSummary(String name, dynamic args, [Object? intent]) {
  final said = intent == null ? null : intentLabel(intent);
  if (said != null) return said;
  final a = args is Map ? args : const {};
  final tool = bareTool(name);
  bool re(String pattern, String value, {bool ci = false}) =>
      RegExp(pattern, caseSensitive: !ci).hasMatch(value);
  if (re(r'screenshot|capture_screen', tool)) return 'Taking a screenshot';
  if (tool == 'bash') return commandLabel(a['command']);
  if (tool == 'read' || tool == 'write' || tool == 'edit') {
    final file = _fileName(
      sanitize((a['path'] ?? a['file_path'] ?? '').toString()),
    );
    final verb = const {
      'read': 'Reading',
      'write': 'Writing',
      'edit': 'Editing',
    }[tool];
    return '$verb ${file ?? 'a file'}';
  }
  if (re(r'^(?:grep|rg)$', tool, ci: true)) return 'Searching the code';
  if (re(r'^(?:glob|find|ls)$', tool, ci: true)) return 'Looking for files';
  if (re('whatsapp', name) && re('read|thread|list|search', tool)) {
    return 'Reading WhatsApp messages';
  }
  if (re(r'^(?:chrome_navigate|navigate_browser|launch_browser)$', tool) &&
      a['url'] is String) {
    final host = _host(a['url']);
    if (host != null) {
      if (re(r'^(?:[a-z0-9-]+\.)?dagim(?:-ops)?\.', host, ci: true)) {
        return 'Opening Dagim';
      }
      if (_capture(host) != null) return 'Opening $host';
    }
    return 'Using the browser';
  }
  if (re(
    r'^(?:chrome_snapshot|chrome_find|chrome_inspect|evaluate_browser|chrome_evaluate)$',
    tool,
  )) {
    return 'Checking the page';
  }
  if (re(
    r'^(?:chrome_(?:click|fill|type|key|scroll|drag|hover|tap|upload_file))$',
    tool,
  )) {
    return 'Using the page controls';
  }
  if (re(r'^chrome_|browser', tool)) return 'Using the browser';
  if (re(
    r'^(?:observe_ui|find_roots|inspect_ui|search_ui|expand_ui|read_text)$',
    tool,
  )) {
    return 'Looking at the screen';
  }
  if (re(r'^(?:act_ui|wait_for)$', tool)) return 'Using an app on the Mac';
  if (re('search', tool)) {
    return re('firecrawl|exa|web|brave|tavily|parallel', name)
        ? 'Searching the web'
        : 'Searching for information';
  }
  final urlHost = _capture(_host(a['url']));
  if (urlHost != null) return 'Reading $urlHost';
  if (tool == 'codemode') return 'Working through several steps';
  if (tool == 'agent_send' || tool == 'agent_request') {
    return 'Messaging another pane';
  }
  if (tool == 'list_peers') return 'Finding available workers';
  if (tool == 'notify_user') return 'Notifying Zach';
  if (tool == 'request_credential') return 'Requesting a credential';
  final words = _clean(tool.replaceAll(RegExp(r'[_-]+'), ' ')).toLowerCase();
  return words.isNotEmpty && RegExp(r'^[a-z0-9 ]{1,28}$').hasMatch(words)
      ? 'Using $words'
      : _unknown;
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

// Routine cross-pane traffic (ack/progress/receipt) folds into the work group;
// approvals, questions, blocked, failed and finished/result reports stay one
// visible line. The SAME rules are in the Mac extension `noticeView`; shared
// fixtures in test/ui/chat/fixtures/notice-views.json.
const _noticeKinds = {
  'needs_approval': 'Approval needed',
  'approval': 'Approval needed',
  'question': 'Question',
  'blocked': 'Blocked',
  'failed': 'Failed',
  'failure': 'Failed',
  'error': 'Failed',
  'done': 'Done',
  'success': 'Done',
  'complete': 'Done',
  'completed': 'Done',
  'handoff': 'Done',
  'result': 'Result',
};
const _routineKinds = {
  'ack', 'progress', 'decision', 'instruction', 'user', 'received', 'receipt',
  'status', 'ping', 'heartbeat', 'in_progress', 'started', 'working', 'note',
  'info', //
};

/// First sentence of [text], at most ~60 characters.
String noticeGist(Object? text) {
  final s = _clean(sanitize((text ?? '').toString())).replaceFirst(
    RegExp(
      r'^(?:done|finished|completed?|ok(?:ay)?|result)\s*[.:!-]\s+',
      caseSensitive: false,
    ),
    '',
  );
  final sentence = (RegExp(r'^(.+?[.!?])(?=\s|$)').firstMatch(s)?.group(1) ?? s)
      .replaceFirst(RegExp(r'[.!]+$'), '');
  if (sentence.length <= 60) return sentence;
  final cut = sentence.substring(0, 60);
  final space = cut.lastIndexOf(' ');
  return '${space > 20 ? cut.substring(0, space) : cut}…';
}

String _noticeLine(String kind, String sender, String gist) =>
    '$kind${sender.isNotEmpty ? ' · $sender' : ''}${gist.isNotEmpty ? ': $gist' : ''}';

/// How an incoming notice presents in quiet mode. `routine` → fold into the
/// work group; `label` null → keep the existing one-line label.
class NoticeView {
  final bool routine;
  final String? label;
  const NoticeView(this.routine, this.label);
}

NoticeView noticeView(String type, String text, [String sender = '']) {
  if (type == 'herdr-thread' || type == 'herdr-fleet') {
    final entries =
        RegExp(
              r'^#\d+\s+\S+\s+\[([^\]]+)\]\s+([a-z_]+)\b[^:\n]*:[ \t]*(.*)$',
              multiLine: true,
            )
            .allMatches(text)
            .map(
              (m) => (
                sender: _clean(
                  m.group(1),
                ).replaceAll(RegExp(r'\bw\d+:p\w+\b'), '').trim(),
                kind: m.group(2)!,
                text: m.group(3)!,
              ),
            )
            .toList();
    if (entries.isEmpty) return const NoticeView(false, null);
    final important = entries
        .where(
          (e) =>
              _noticeKinds.containsKey(e.kind) ||
              !_routineKinds.contains(e.kind),
        )
        .toList();
    if (important.isEmpty) return const NoticeView(true, null);
    final first = important.first;
    return NoticeView(
      false,
      _noticeLine(
            _noticeKinds[first.kind] ?? 'Update',
            first.sender,
            noticeGist(first.text),
          ) +
          (important.length > 1 ? ' (+${important.length - 1} more)' : ''),
    );
  }
  if (type == 'herdr-worker-inbox') {
    final statuses = RegExp(
      r'^Job\s+\S+\s+hash\s+\S+\s+status\s+([a-z_]+)',
      multiLine: true,
    ).allMatches(text).map((m) => m.group(1)!).toList();
    if (statuses.isEmpty) return const NoticeView(false, null);
    final counts = <String, int>{};
    for (final s in statuses) {
      if (s != 'success') counts[s] = (counts[s] ?? 0) + 1;
    }
    final head = statuses.length == 1
        ? 'Worker result'
        : '${statuses.length} worker results';
    return NoticeView(
      false,
      counts.isEmpty
          ? '$head ready'
          : '$head: ${counts.entries.map((e) => '${e.value} ${e.key.replaceAll('_', ' ')}').join(', ')}',
    );
  }
  if (type == 'remote-pi:mesh-message') {
    final body = text
        .replaceFirst(
          RegExp(r'\n*\((?:This is a reply|If a reply is expected)[\s\S]*$'),
          '',
        )
        .trim();
    Object? data;
    try {
      final start = body.indexOf('{');
      if (start >= 0) data = jsonDecode(body.substring(start));
    } catch (_) {
      // Untyped text.
    }
    String field(Object? value) => value is String ? value.toLowerCase() : '';
    final map = data is Map ? data : null;
    final fields = map == null
        ? const <String>[]
        : [field(map['kind']), field(map['type']), field(map['status'])];
    // A surfaced kind (blocked, approval, done…) beats a routine one in any field.
    final signal =
        fields.where(_noticeKinds.containsKey).firstOrNull ??
        fields.where(_routineKinds.contains).firstOrNull;
    // Structured payloads show only a human field, never raw JSON.
    final human = map == null
        ? null
        : [
            'summary',
            'note',
            'message',
            'text',
          ].map((k) => map[k]).whereType<String>().firstOrNull;
    final gist = noticeGist(map != null ? human ?? '' : body);
    if (signal != null) {
      final kind = _noticeKinds[signal];
      return kind != null
          ? NoticeView(false, _noticeLine(kind, sender, gist))
          : const NoticeView(true, null);
    }
    // Conservative text rules on the human text: anything that might need Zach stays visible.
    final said = human ?? body;
    bool has(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(said);
    final kind =
        has(
          r"\b(?:needs? (?:your |zach'?s )?approval|approval (?:needed|required)|awaiting (?:your )?approval)\b",
        )
        ? 'Approval needed'
        : has(r'\bblocked\b')
        ? 'Blocked'
        : has(r'\b(?:failed|failure)\b')
        ? 'Failed'
        : has(r'''\?(?:[\s"'\)\]}]|$)''')
        ? 'Question'
        : has(r'^(?:done|finished|completed?|shipped|result)\b')
        ? 'Done'
        : null;
    return kind != null
        ? NoticeView(false, _noticeLine(kind, sender, gist))
        : const NoticeView(true, null);
  }
  return const NoticeView(false, null);
}

/// Sender of a mesh address: its last two pane segments ("Main / FB Ads").
String meshSender(String? address) {
  final segments = (address ?? '')
      .split('@')
      .last
      .split('›')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) return '';
  return _clean(
    segments
        .sublist(segments.length > 2 ? segments.length - 2 : 0)
        .join(' / ')
        .replaceAll('_', ' '),
  );
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
      // The assistant text segment right before this call, as on the Mac.
      final before = messages.length > 1 ? messages[messages.length - 2] : null;
      return liveSummary(
        last.tool,
        last.args,
        before is AssistantMsg ? before.text : null,
      );
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
