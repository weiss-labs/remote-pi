// Plan/74 — Share-extension hand-off queue and pasteboard item mapping.
import 'package:app/data/images/pasteboard_service.dart';
import 'package:app/data/share/share_inbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSharedItems', () {
    test('keeps well-formed entries, in the order given, with mime fallback', () {
      final items = parseSharedItems([
        {
          'id': 'a',
          'peer': 'peer-1',
          'room': 'room-1',
          'label': 'ZachOS › main',
          'name': 'clip.mov',
          'mime': 'video/quicktime',
          'size': 10,
          'path': '/g/inbox/a/clip.mov',
          'duration_ms': 1500,
        },
        {
          'id': 'b',
          'peer': 'peer-1',
          'room': 'room-2',
          'name': 'notes.pdf',
          'size': 5,
          'path': '/g/inbox/b/notes.pdf',
        },
      ]);
      expect(items.map((i) => i.id), ['a', 'b']);
      expect(items[0].label, 'ZachOS › main');
      expect(items[0].file.durationMs, 1500);
      expect(items[0].file.isVideo, isTrue);
      expect(items[1].file.mime, 'application/pdf');
      expect(items[1].room, 'room-2');
    });

    test('never routes an entry missing its pane, path or size', () {
      expect(
        parseSharedItems([
          {'id': 'x', 'room': 'r', 'path': '/p', 'size': 1},
          {'id': 'x', 'peer': 'p', 'path': '/p', 'size': 1},
          {'id': 'x', 'peer': 'p', 'room': 'r', 'size': 1},
          {'id': 'x', 'peer': 'p', 'room': 'r', 'path': '/p', 'size': 0},
          {'peer': 'p', 'room': 'r', 'path': '/p', 'size': 1},
          'junk',
          null,
        ]),
        isEmpty,
      );
      expect(parseSharedItems(null), isEmpty);
    });
  });

  group('parsePasteboardItems', () {
    test('maps files and infers mime from the name', () {
      final items = parsePasteboardItems([
        {'path': '/t/a/photo.png', 'name': 'photo.png', 'size': 3},
        {'path': '/t/b/x.mp4', 'name': 'x.mp4', 'mime': 'video/mp4', 'size': 9},
        {'path': '/t/c/blob', 'size': 1},
        {'path': '', 'name': 'nope', 'size': 1},
        {'path': '/t/d/empty.txt', 'size': 0},
      ]);
      expect(items.map((i) => i.mime), [
        'image/png',
        'video/mp4',
        'application/octet-stream',
      ]);
      expect(items[2].name, 'blob');
    });
  });

  group('NativeShareInbox', () {
    const channel = MethodChannel('test-share-inbox');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'takeQueued') {
              return [
                {
                  'id': 'q1',
                  'peer': 'p',
                  'room': 'r',
                  'name': 'v.mov',
                  'size': 2,
                  'path': '/g/inbox/q1/v.mov',
                },
              ];
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('takeQueued, complete and publishPanes go over the channel', () async {
      final inbox = NativeShareInbox(channel);
      final items = await inbox.takeQueued();
      expect(items.single.id, 'q1');
      await inbox.complete('q1');
      await inbox.publishPanes(const [
        SharedPane(
          peer: 'p',
          room: 'r',
          workspace: 'ZachOS',
          tab: 'Agents',
          pane: 'main',
          device: 'Mac',
          online: true,
        ),
      ]);
      expect(calls.map((c) => c.method), [
        'takeQueued',
        'complete',
        'publishPanes',
      ]);
      expect(calls[1].arguments, {'id': 'q1'});
      expect(
        (calls[2].arguments as Map)['panes'],
        [
          {
            'peer': 'p',
            'room': 'r',
            'workspace': 'ZachOS',
            'tab': 'Agents',
            'pane': 'main',
            'device': 'Mac',
            'online': true,
          },
        ],
      );
    });

    test('a platform without the bridge yields nothing and never throws', () async {
      final inbox = NativeShareInbox(const MethodChannel('missing-share'));
      expect(await inbox.takeQueued(), isEmpty);
      await inbox.complete('x');
      await inbox.publishPanes(const []);
    });
  });
}
