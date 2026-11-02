/// Presentation-only recognition of the box-drawn EMAIL / WHATSAPP / IMESSAGE
/// DRAFT panels the desk generators print. The source remains the copy/export
/// authority: nothing here is ever sent, and every character of the panel
/// stays visible on the card (fields, body, footer, or the full source when
/// the structure is unknown).
library;

enum DraftChannel { email, whatsapp, imessage, sms }

class DraftField {
  final String label;

  /// May contain `\n` when the panel listed several values (one address per
  /// row) under the same label.
  final String value;
  const DraftField(this.label, this.value);

  /// True when the whole value is machine identity (JIDs, LIDs, sender ids),
  /// so the card can demote it to a small muted line.
  bool get isMachine => DraftPanel.machineIdOnly(value);

  @override
  String toString() => '$label: $value';
}

class DraftPanel {
  /// Exact fenced source, unchanged. Copy always copies this.
  final String source;

  /// The full title row, e.g. `WHATSAPP DRAFT (GROUP)`.
  final String title;
  final DraftChannel channel;

  /// Header rows in panel order. Empty on fallback.
  final List<DraftField> fields;

  /// Body text with the generator's 60-column soft wrap undone; real line
  /// breaks (short lines, blank lines, list items) are kept. On fallback this
  /// is the full source.
  final String body;

  /// Unboxed lines after the panel (preview id, send notes, links).
  final List<String> footer;

  /// True when the structure was not understood and [body] is the raw source.
  final bool fallback;

  const DraftPanel({
    required this.source,
    required this.title,
    required this.channel,
    required this.fields,
    required this.body,
    required this.footer,
    required this.fallback,
  });

  /// Title trimmed of the channel word: `(GROUP)`, `1 of 2`, `· REVISED`.
  String get titleSuffix {
    final rest = title.replaceFirst(_titleRe, '').trim();
    return rest.replaceFirst(RegExp(r'^[·:\-–—]\s*'), '').trim();
  }

  /// The recipient row (To / Thread / To/From), if any.
  DraftField? get recipient {
    for (final f in fields) {
      if (const {'To', 'Thread', 'To/From'}.contains(f.label)) return f;
    }
    return null;
  }

  static final _titleRe = RegExp(r'^(EMAIL|WHATSAPP|IMESSAGE|SMS) DRAFTS?\b');
  static final _border = RegExp(r'^[┌┐└┘├┤┬┴┼─]+$');
  static final _machineId = RegExp(
    r'\(?"?[0-9][0-9:\-]*@(?:lid|g\.us|s\.whatsapp\.net)"?\)?',
  );
  static final _listItem = RegExp(r'^\s*(?:\d+[.)]|[-•*–])\s');
  static final _titleField = RegExp(r'^([A-Za-z][A-Za-z /]{0,11}):\s+(.*)$');

  static bool machineIdOnly(String value) {
    final rest = value.replaceAll(_machineId, '').trim();
    return value.contains(_machineId) && rest.isEmpty;
  }

  /// Splits a recipient value into the human line and the machine ids, e.g.
  /// `Verified phone +1555 (123@lid)` → (`Verified phone +1555`, [`123@lid`]).
  static (String, List<String>) splitMachineIds(String value) {
    final ids = <String>[];
    final lines = <String>[];
    // One recipient per line (email lists several); keep those boundaries.
    for (final line in value.split('\n')) {
      ids.addAll(
        _machineId
            .allMatches(line)
            .map((m) => m.group(0)!.replaceAll(RegExp(r'[()"]'), '')),
      );
      final primary = line
          .replaceAll(_machineId, '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(RegExp(r'\s*[|·]\s*$'), '')
          .trim();
      if (primary.isNotEmpty) lines.add(primary);
    }
    if (lines.isEmpty && ids.isNotEmpty) lines.add(ids.removeAt(0));
    return (lines.join('\n'), ids);
  }

  static DraftPanel? parse(String language, String source) {
    if (language.isNotEmpty && language.trim().toLowerCase() != 'text') {
      return null;
    }
    final lines = source.trim().split('\n');
    String? inner(String line) {
      final t = line.trim();
      if (!t.startsWith('│') || !t.endsWith('│') || t.length < 2) return null;
      final value = t.substring(1, t.length - 1);
      return (value.startsWith(' ') ? value.substring(1) : value).trimRight();
    }

    DraftChannel? channel;
    String? title;
    for (final line in lines) {
      final m = _titleRe.firstMatch(inner(line) ?? '');
      if (m != null) {
        title = inner(line)!;
        channel = DraftChannel.values.byName(m.group(1)!.toLowerCase());
        break;
      }
    }
    if (channel == null) return null;
    DraftPanel raw() => DraftPanel(
      source: source,
      title: title!,
      channel: channel!,
      fields: const [],
      body: source,
      footer: const [],
      fallback: true,
    );
    final end = lines.lastIndexWhere((l) => l.trim().startsWith('└'));
    // Incomplete/mixed panels retain every character and soft-wrap instead.
    if (end < 2 || !lines.first.trim().startsWith('┌')) return raw();
    final box = lines.sublist(0, end + 1);
    if (box.any((l) => !_border.hasMatch(l.trim()) && inner(l) == null)) {
      return raw();
    }
    final footer = lines
        .skip(end + 1)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final width = lines.first.trim().length - 4; // inner text columns

    // Split into sections at ├ borders; remember whether each has a ┬ top.
    final sections = <List<String>>[[]];
    final headerSection = <bool>[false];
    for (final line in box) {
      final t = line.trim();
      if (_border.hasMatch(t)) {
        if (t.startsWith('├')) {
          sections.add([]);
          headerSection.add(t.contains('┬'));
        }
        continue;
      }
      sections.last.add(inner(line)!);
    }
    final fields = <DraftField>[];
    final bodyParts = <String>[];
    for (var i = 0; i < sections.length; i++) {
      final rows = sections[i];
      if (i == 0) {
        // Title section: title row, then optional hand-drawn `Label: value`.
        if (rows.isEmpty || rows.first != title) return raw();
        for (final row in rows.skip(1)) {
          final m = _titleField.firstMatch(row);
          if (m == null) return raw();
          fields.add(DraftField(m.group(1)!, m.group(2)!.trim()));
        }
      } else if (headerSection[i]) {
        for (final row in rows) {
          final cut = row.indexOf('│');
          if (cut < 0) return raw();
          final label = row.substring(0, cut).trim();
          final value = row.substring(cut + 1).trim();
          if (label.isEmpty) {
            if (fields.isEmpty) return raw();
            final prev = fields.removeLast();
            final lastLine = prev.value.split('\n').last;
            // Inner row = label cell + '│' + ' ' + value cell.
            final valueWidth = width - cut - 2;
            // panel.py lists addresses and attachments one per row, unwrapped;
            // only Subject wraps. The WhatsApp/iMessage senders wrap every row.
            final wraps =
                channel != DraftChannel.email || prev.label == 'Subject';
            fields.add(
              DraftField(
                prev.label,
                wraps && _wrapped(lastLine, value, valueWidth)
                    ? '${prev.value} $value'
                    : '${prev.value}\n$value',
              ),
            );
          } else {
            fields.add(DraftField(label, value));
          }
        }
      } else {
        bodyParts.add(_unwrap(rows, width));
      }
    }
    return DraftPanel(
      source: source,
      title: title!,
      channel: channel,
      fields: fields,
      body: bodyParts.join('\n\n'),
      footer: footer,
      fallback: false,
    );
  }

  /// Inverse of greedy word wrap: the generator only broke a line when the
  /// next word did not fit, so a break where it *would* have fit is real.
  // ponytail: a long word split mid-word by break_long_words=True re-joins
  // with a space; iMessage only, rare, and the copy source is untouched.
  static bool _wrapped(String current, String next, int width) {
    final a = current.trimRight();
    final b = next.trimLeft();
    if (a.isEmpty || b.isEmpty || _listItem.hasMatch(b)) return false;
    final firstWord = b.split(RegExp(r'\s')).first;
    // Python's textwrap counts code points, so emoji must count as one.
    return a.runes.length + 1 + firstWord.runes.length > width;
  }

  static String _unwrap(List<String> rows, int width) {
    final out = <String>[];
    String? prev; // the previous physical row, not the joined paragraph
    for (final row in rows) {
      if (prev != null && _wrapped(prev, row, width)) {
        out[out.length - 1] = '${out.last.trimRight()} ${row.trimLeft()}';
      } else {
        out.add(row);
      }
      prev = row;
    }
    return out.join('\n');
  }
}
