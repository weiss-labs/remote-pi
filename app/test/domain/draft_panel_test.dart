import 'dart:io';

import 'package:app/domain/entities/draft_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic panels in the exact row/wrap shapes the desk generators print
/// (panel.py, the WhatsApp and iMessage senders) plus hand-drawn variants.
String fixture(String name) =>
    File('test/ui/chat/fixtures/draft-panels/$name.txt').readAsStringSync();

DraftPanel parse(String name) => DraftPanel.parse('text', fixture(name))!;

/// `[primary, ...machineIds]` so list matchers compare by value.
List<String> split(String value) {
  final (primary, ids) = DraftPanel.splitMachineIds(value);
  return [primary, ...ids];
}

void main() {
  test('every fixture parses, keeps its source and every character', () {
    final dir = Directory('test/ui/chat/fixtures/draft-panels');
    final files = dir.listSync().whereType<File>().toList();
    expect(files.length, greaterThanOrEqualTo(15));
    for (final f in files) {
      final source = f.readAsStringSync();
      final p = DraftPanel.parse('text', source);
      expect(p, isNotNull, reason: f.path);
      expect(p!.source, source, reason: f.path);
      // Every non-space character of the panel text is on the card.
      final shown = [
        p.title,
        ...p.fields.map((x) => '${x.label}${x.value}'),
        p.body,
        ...p.footer,
      ].join().replaceAll(RegExp(r'\s'), '');
      final inner = source
          .split('\n')
          .where((l) => !RegExp(r'^[┌┐└┘├┤┬┴┼─]+$').hasMatch(l.trim()))
          .join(' ');
      for (final word in inner.split(
        RegExp(r'[^\p{L}\p{N}]+', unicode: true),
      )) {
        expect(shown, contains(word), reason: '${f.path}: $word');
      }
      expect(DraftPanel.parse('dart', source), isNull);
    }
    expect(DraftPanel.parse('text', 'regular code'), isNull);
  });

  test('whatsapp direct: fields, demoted ids, unwrapped body', () {
    final p = parse('whatsapp-direct');
    expect(p.channel, DraftChannel.whatsapp);
    expect(p.title, 'WHATSAPP DRAFT');
    expect(p.titleSuffix, '');
    expect(p.fallback, isFalse);
    expect(p.fields.map((f) => f.label), ['To', 'From', 'Phone', 'LID']);
    expect(
      p.recipient!.value,
      'Verified phone +15550001234 (100000000000001@lid)',
    );
    expect(split(p.recipient!.value), [
      'Verified phone +15550001234',
      '100000000000001@lid',
    ]);
    expect(p.fields[1].isMachine, isTrue);
    expect(p.fields[2].isMachine, isFalse);
    expect(p.fields[3].isMachine, isTrue);
    expect(
      p.body,
      'Good catch Sam. That order on your pick list is in the system now as '
      '2802463, same 7 items, for tomorrow.\n\n'
      'What happened is the accounting app turned it down once when it came '
      'in and the program never tried again. I fixed that, now it tries again '
      'on its own. And if an order still isn\'t in, the pick list will say '
      'NOT IN QUICKBOOKS YET at the top so you\'ll know right away.',
    );
  });

  test('continuation rows: wrapped value re-joins, listed values stay lines', () {
    final wa = parse('whatsapp-attachments');
    expect(
      wa.recipient!.value,
      'Verified phone +15550005678 (15550005678@s.whatsapp.net)',
    );
    expect(wa.fields.where((f) => f.label == 'Attach').map((f) => f.value), [
      '1. webkit-390-11-collection-rows.png (64 KB, sha256 9fa9bf2d5410)',
      '2. webkit-390-12-draft-restore.png (51 KB, sha256 80bfcb7280a2)',
    ]);
    expect(wa.body, contains('\n1. Collections: on the order screen'));
    expect(wa.body, contains('per order.\n2. Your work now saves'));
    expect(wa.body, contains('Resume draft.\n\nIf anything'));

    final em = parse('email-full');
    expect(em.channel, DraftChannel.email);
    expect(em.fields.map((f) => f.toString()), [
      'To: Erick Example <erick@example.invalid>\n'
          'Dish Websites <dish@example.invalid>',
      'Cc: Chris Example <chris@example.invalid>\nRyan Example <ryan@example.invalid>',
      'From: zach@example.invalid',
      'Subject: Urgent PHP security update for internet.example.invalid',
      'Attach: GSX-20261004-ADD01-REV1.pdf',
    ]);
    expect(em.body, startsWith('Hi Erick,\n\nPHP released emergency fixes'));
    expect(
      em.body,
      endsWith(
        'Thanks,\nZach\n\nZach Weiss\nFounder & CEO, Weiss Labs\nzach@example.invalid\nhttps://example.invalid',
      ),
    );
  });

  test('group reply: Reply to / Msg id / Tags and a quoted id', () {
    final p = parse('whatsapp-group-reply');
    expect(p.fields.map((f) => f.label), [
      'To',
      'From',
      'Tags',
      'Reply to',
      'Msg id',
    ]);
    expect(
      p.fields[3].value,
      '"[imageMessage: 2026-11-01_171408_Y.s._120360000000000001.jp…" '
      '(Y.s., 2026-11-01 17:14 UTC)',
    );
    expect(split(p.recipient!.value), ['Ops Sales', '120360000000000001@g.us']);
    final tag = parse('whatsapp-group-tag');
    expect(tag.titleSuffix, '(GROUP)');
    expect(split(tag.recipient!.value), [
      '"Ops Sales"',
      '120360000000000001@g.us',
    ]);
    expect(tag.fields[1].value, 'Chaim (100000000000004@lid)');
  });

  test('hand-drawn shapes: title-block fields and multi-section bodies', () {
    final hand = parse('whatsapp-handdrawn');
    expect(hand.fields, hasLength(1));
    expect(hand.recipient!.value, 'Shimon Example | +1 555-420-1594');
    // Hand-wrapped narrower than the box: breaks are kept, nothing is lost.
    expect(
      hand.body,
      startsWith(
        'Fixed, Google sign-in now keeps you on example.com with\nyour admin access.',
      ),
    );
    expect(hand.body, endsWith('through Forgot password.'));

    final multi = parse('whatsapp-multi');
    expect(multi.titleSuffix, 'Example Marketing');
    expect(split(multi.recipient!.value), ['120360000000000005@g.us']);
    expect(multi.body, startsWith('MESSAGE 1\nHey @100000000000006'));
    expect(multi.body, contains('3 signups.\n\nMESSAGE 2\nMy take'));
  });

  test('imessage: thread, attach-only body, numbered steps kept', () {
    final a = parse('imessage-attach-only');
    expect(a.channel, DraftChannel.imessage);
    expect(a.fields.map((f) => f.toString()), [
      'To: +15550001111 (#2073)',
      'Attach: Example - Business ideas council.pdf',
    ]);
    expect(a.body, '(no text, attachments only)');
    final d = parse('imessage-direct');
    expect(d.titleSuffix, '(group)');
    expect(d.recipient!.label, 'Thread');
    expect(
      d.body,
      contains(
        'do this:\n1. Open https://t.me/ExampleScorecardBot\n2. Tap Start\n3. Send',
      ),
    );
  });

  test('email preview title suffix and footer lines inside the fence', () {
    final p = parse('email-preview');
    expect(p.titleSuffix, 'Contents preview');
    expect(p.recipient!.label, 'To/From');
    expect(p.body, contains('\n• Client A: test that labels'));
    final f = parse('email-footer-inside');
    expect(f.body, 'Short body.');
    expect(f.footer, [
      '[Edit & send this email in Gmail](https://mail.example.invalid/#drafts?compose=abc)',
      'Preview id: 0123456789abcdef',
    ]);
  });

  test('unknown structure falls back to the full source', () {
    final p = parse('broken-fallback');
    expect(p.fallback, isTrue);
    expect(p.channel, DraftChannel.whatsapp);
    expect(p.fields, isEmpty);
    expect(p.body, fixture('broken-fallback'));
    final noTitle = fixture(
      'whatsapp-direct',
    ).replaceFirst('WHATSAPP DRAFT', 'SOMETHING ELSE');
    expect(DraftPanel.parse('text', noTitle), isNull);
  });

  test(
    'review boundaries: separate email rows, exact-fit subject, signature',
    () {
      final p = parse('email-boundaries');
      expect(p.fields.map((f) => f.toString()), [
        'To: Alexander Longname-Example <alexander@example.invalid>\n'
            'Bartholomew Longname-Example <bart@example.invalid>',
        'From: zach@example.invalid',
        // 48 + 1 + 2 = 51 > the generator's 50 columns: a wrap, not a break.
        'Subject: ${'A' * 48} bb',
        'Attach: first-attachment-name-30-chars.pdf\n'
            'second-attachment-name-30-char.pdf',
      ]);
      // A wrapped paragraph followed by short lines keeps those breaks.
      expect(
        p.body,
        '${'one ' * 15}one\nThanks,\nZach\n\n'
        'Use [portal](https://example.invalid/private) or '
        'https://example.invalid/a_(b) today.',
      );
    },
  );

  test(
    'code points, not UTF-16 units, decide a wrap; recipients keep lines',
    () {
      final p = parse('whatsapp-unicode');
      // 10 emoji + space + 39 letters = 50 columns in Python: a real break.
      expect(p.body, startsWith('${'🎉' * 10} ${'a' * 39}\nThanks,\nZach\n\n'));
      expect(
        p.body,
        endsWith('See [the doc](https://example.invalid/a_(b)) now.'),
      );
      final (primary, ids) = DraftPanel.splitMachineIds(
        parse('email-boundaries').recipient!.value,
      );
      expect(primary, contains('<alexander@example.invalid>\nBartholomew'));
      expect(ids, isEmpty);
      expect(split('Ops (1@g.us)\nVerified phone +1 (2@lid)'), [
        'Ops\nVerified phone +1',
        '1@g.us',
        '2@lid',
      ]);
    },
  );
}
