/// Presentation-only recognition. The source remains the copy/export authority.
class DraftPanel {
  final String source;
  final String? title;
  final String content;
  const DraftPanel(this.source, this.title, this.content);

  static DraftPanel? parse(String language, String source) {
    if (language.isNotEmpty && language.trim().toLowerCase() != 'text') {
      return null;
    }
    final lines = source.trim().split('\n');
    final titles = RegExp(r'^(EMAIL|WHATSAPP|IMESSAGE|SMS) DRAFT$');
    bool border(String line) =>
        RegExp(r'^[┌┐└┘├┤┬┴┼─]+$').hasMatch(line.trim());
    String? inner(String line) {
      final t = line.trim();
      if (!t.startsWith('│') || !t.endsWith('│') || t.length < 2) return null;
      final value = t.substring(1, t.length - 1);
      return (value.startsWith(' ') ? value.substring(1) : value).trimRight();
    }

    if (!lines.any((line) => titles.hasMatch(inner(line) ?? ''))) return null;
    // Incomplete/mixed panels retain every character and soft-wrap instead.
    if (lines.length < 3 ||
        !lines.first.trim().startsWith('┌') ||
        !lines.last.trim().startsWith('└') ||
        lines.any((line) => !border(line) && inner(line) == null)) {
      return DraftPanel(source, null, source);
    }
    final rows = <String>[];
    var headers = false;
    for (final line in lines) {
      if (border(line)) {
        if (line.contains('┬')) headers = true;
        if (line.contains('┴')) {
          headers = false;
          rows.add('');
        }
        continue;
      }
      final value = inner(line)!;
      if (headers) {
        final cells = value.split('│');
        if (cells.length != 2 ||
            !const {
              'To',
              'Cc',
              'From',
              'Subject',
              'Attach',
              '',
            }.contains(cells.first.trim())) {
          return DraftPanel(source, null, source);
        }
        final label = cells.first.trim();
        rows.add('${label.isEmpty ? '' : '$label: '}${cells.last.trim()}');
      } else {
        rows.add(value);
      }
    }
    if (rows.isEmpty || !titles.hasMatch(rows.first)) {
      return DraftPanel(source, null, source);
    }
    return DraftPanel(source, rows.first, rows.skip(1).join('\n'));
  }
}
