import 'dart:typed_data';
// Plan/30 — InputBar image wiring: attach button gating by vision, preview +
// remove, send-with-image. Drives a real AttachmentViewModel + fakes.

import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// 1×1 transparent PNG so Image.memory decodes cleanly in the test env.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _FakePicker implements IImagePickerService {
  PickedImage next = PickedImage(bytes: _pngBytes, mime: 'image/jpeg');
  @override
  Future<PickedImage?> pickFromCamera() async => next;
  @override
  Future<PickedImage?> fromBytes(Uint8List bytes, String mime) async => next;
  @override
  Future<PickedImage?> pickFromGallery() async => next;
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  final _ctrl = StreamController<ActiveRoomMeta>.broadcast();
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      catalogue;
  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();
  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _ctrl.stream;
  @override
  void dispose() => _ctrl.close();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _m(bool vision) => WireModel(
  id: 'id',
  name: 'M',
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  late _FakePicker picker;
  late _FakeActions actions;
  late AttachmentViewModel vm;

  setUp(() {
    picker = _FakePicker();
    actions = _FakeActions();
    vm = AttachmentViewModel(picker, actions);
  });

  tearDown(() => vm.dispose());

  Future<void> pumpBar(
    WidgetTester tester, {
    bool channelOpen = true,
    bool streaming = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: InputBar(
              onSend: (text) {},
              streaming: streaming,
              onCancel: () {},
              attachment: vm,
              onOpenAttach: channelOpen ? () {} : null,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('attach button is present and enabled by default', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.pump();
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('vision=false disables the attach button (#9)', (tester) async {
    actions.catalogue = ModelsCatalogue(
      models: [_m(false)],
      current: _m(false),
    );
    // Recreate after the catalogue is set so the VM resolves vision=false.
    vm = AttachmentViewModel(picker, actions);
    await pumpBar(tester);
    await tester.pump(); // resolve vision
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('offline (null onOpenAttach) disables the attach button', (
    tester,
  ) async {
    await pumpBar(tester, channelOpen: false);
    await tester.pump();
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('picking shows the preview + send icon; X removes it', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.pump();

    await vm.pickFromGallery();
    await tester.pump();

    expect(find.byKey(const Key('attach-preview')), findsOneWidget);
    expect(find.byIcon(LucideIcons.send600), findsOneWidget); // send-mode (#6)
    // Weiss Labs: more images can be added on top.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('input-bar-attach')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('attach-remove')));
    await tester.pump();
    expect(find.byKey(const Key('attach-preview')), findsNothing);
  });

  testWidgets('Weiss Labs: attach works while the pane is working', (tester) async {
    await pumpBar(tester, streaming: true);
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('input-bar-attach'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('Weiss Labs: several images, each removable, all sent', (tester) async {
    await pumpBar(tester);
    await vm.pickFromGallery();
    await vm.pickFromGallery();
    await tester.pump();
    expect(find.byKey(const Key('attach-preview')), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('attach-remove')).first);
    await tester.pump();
    expect(find.byKey(const Key('attach-preview')), findsOneWidget);
    await vm.pickFromGallery();
    expect(vm.takeImagesForSend(), hasLength(2));
    expect(vm.hasImage, isFalse);
  });

  testWidgets(
    'send with an attached image + empty caption dispatches the image',
    (tester) async {
      MessageImage? sent;
      String? sentText;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: InputBar(
                attachment: vm,
                onOpenAttach: () {},
                onSend: (text) {
                  sentText = text;
                  sent = vm.takeImageForSend(); // mirrors chat_page wiring
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await vm.pickFromGallery();
      await tester.pumpAndSettle(); // let the send icon's switcher settle

      await tester.tap(find.byIcon(LucideIcons.send600));
      await tester.pump();

      expect(sentText, '');
      expect(sent, isNotNull);
      expect(sent!.mime, 'image/jpeg');
    },
  );
}
