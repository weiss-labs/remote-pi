// Plan/30 — AttachmentViewModel: pick / remove / take + vision gating,
// against fake picker + actions repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/images/pasteboard_service.dart';
import 'package:app/data/share/share_inbox.dart';
import 'package:app/domain/contracts/file_transfer.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? next = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );
  bool denyCamera = false;
  bool fail = false;

  @override
  Future<PickedImage?> pickFromCamera() async {
    if (denyCamera) throw const ImagePermissionDeniedException();
    if (fail) throw Exception('boom');
    return next;
  }

  @override
  Future<PickedImage?> fromBytes(Uint8List bytes, String mime) async => next;
  @override
  Future<PickedImage?> pickFromGallery() async {
    if (fail) throw Exception('boom');
    return next;
  }

  PendingFile? nextFile;
  @override
  Future<PendingFile?> pickVideo(ImageSourceKind source) async {
    if (denyCamera && source == ImageSourceKind.camera) {
      throw const ImagePermissionDeniedException();
    }
    return nextFile;
  }
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  ActiveRoomMeta meta = const ActiveRoomMeta();
  final _metaCtrl = StreamController<ActiveRoomMeta>.broadcast();
  bool offline = false;

  void pushMeta(ActiveRoomMeta m) {
    meta = m;
    _metaCtrl.add(m);
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    if (offline) throw const ActionFailure('offline');
    return catalogue;
  }

  @override
  ActiveRoomMeta get activeRoomMeta => meta;

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _metaCtrl.stream;

  @override
  void dispose() => _metaCtrl.close();

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _model({required bool vision, String name = 'M'}) => WireModel(
  id: 'id-$name',
  name: name,
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  plan74FileTests();
  test('pickFromGallery attaches an image; removeImage clears it', () async {
    final vm = AttachmentViewModel(_FakePicker(), _FakeActions());
    await vm.pickFromGallery();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasImage, isTrue);

    vm.removeImage();
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.hasImage, isFalse);
    vm.dispose();
  });

  test(
    'Weiss Labs: a photo that would overflow the relay frame is refused',
    () async {
      final picker = _FakePicker();
      final vm = AttachmentViewModel(picker, _FakeActions());
      final hints = <AttachHint>[];
      final sub = vm.hints.listen(hints.add);
      picker.next = PickedImage(
        bytes: Uint8List(AttachmentViewModel.maxTotalBytes),
        mime: 'image/jpeg',
      );
      await vm.pickFromGallery();
      picker.next = PickedImage(bytes: Uint8List(10), mime: 'image/jpeg');
      await vm.pickFromGallery();
      await Future<void>.delayed(Duration.zero);
      expect((vm.state as AttachmentAttached).images, hasLength(1));
      expect(hints, [AttachHint.tooLarge]);
      await sub.cancel();
      vm.dispose();
    },
  );

  test('takeImageForSend returns base64 MessageImage and resets', () async {
    final picker = _FakePicker()
      ..next = PickedImage(
        bytes: Uint8List.fromList([10, 20, 30]),
        mime: 'image/jpeg',
      );
    final vm = AttachmentViewModel(picker, _FakeActions());
    await vm.pickFromGallery();

    final msg = vm.takeImageForSend();
    expect(msg, isNotNull);
    expect(msg!.mime, 'image/jpeg');
    expect(base64Decode(msg.data), [10, 20, 30]);
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeImageForSend(), isNull); // nothing left
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(picker, _FakeActions());
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFromCamera();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.cameraPermissionDenied]);
    await sub.cancel();
    vm.dispose();
  });

  test('vision=false from catalogue blocks the attach affordance', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero); // let init resolve vision

    expect(vm.state.visionSupported, isFalse);
    expect(vm.state.attachBlockedByVision, isTrue);
    vm.dispose();
  });

  test('vision=true does not block', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isTrue);
    expect(vm.state.attachBlockedByVision, isFalse);
    vm.dispose();
  });

  test('offline catalogue leaves vision unknown (does not block)', () async {
    final actions = _FakeActions()..offline = true;
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isNull);
    expect(vm.state.attachBlockedByVision, isFalse);
    vm.dispose();
  });

  test('a model change re-resolves vision', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);
    expect(vm.state.visionSupported, isTrue);

    // Pi switched to a text-only model.
    actions.catalogue = ModelsCatalogue(
      models: [_model(vision: false, name: 'TextOnly')],
      current: _model(vision: false, name: 'TextOnly'),
    );
    actions.pushMeta(const ActiveRoomMeta(model: 'TextOnly'));
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isFalse);
    vm.dispose();
  });
}

// Plan/74 — videos and pasted/shared files ride beside the inline images.
class _FakePasteboard implements IPasteboardService {
  List<PendingFile> items = const [];
  @override
  Future<bool> hasAttachments() async => items.isNotEmpty;
  @override
  Future<List<PendingFile>> readAttachments() async => items;
}

void plan74FileTests() {
  const clip = PendingFile(
    path: '/tmp/clip.mov',
    name: 'clip.mov',
    mime: 'video/quicktime',
    size: 1234,
    durationMs: 3000,
  );

  test(
    'pickVideo attaches a file chip; images and files are taken separately',
    () async {
      final picker = _FakePicker()..nextFile = clip;
      final vm = AttachmentViewModel(picker, _FakeActions());
      await vm.pickVideo(ImageSourceKind.gallery);
      expect(vm.hasImage, isTrue);
      expect(vm.hasFiles, isTrue);
      await vm.pickFromGallery();
      final s = vm.state as AttachmentAttached;
      expect(s.images, hasLength(1));
      expect(s.files, [clip]);

      expect(vm.takeImagesForSend(), hasLength(1));
      expect((vm.state as AttachmentAttached).files, [clip]);
      expect(vm.takeFilesForSend(), [clip]);
      expect(vm.state, isA<AttachmentEmpty>());
      expect(vm.takeFilesForSend(), isEmpty);
      vm.dispose();
    },
  );

  test('removeFile drops one chip; removeImage keeps files', () async {
    final picker = _FakePicker()..nextFile = clip;
    final vm = AttachmentViewModel(picker, _FakeActions());
    await vm.pickVideo(ImageSourceKind.gallery);
    await vm.pickVideo(ImageSourceKind.camera);
    await vm.pickFromGallery();
    vm.removeImage();
    expect((vm.state as AttachmentAttached).files, hasLength(2));
    vm.removeFile(5); // out of range: no-op
    vm.removeFile(0);
    expect((vm.state as AttachmentAttached).files, hasLength(1));
    vm.removeFile(0);
    expect(vm.state, isA<AttachmentEmpty>());
    vm.dispose();
  });

  test(
    'a file over the 200 MiB cap and a denied camera hint, nothing attached',
    () async {
      final picker = _FakePicker()
        ..nextFile = const PendingFile(
          path: '/tmp/huge.mov',
          name: 'huge.mov',
          mime: 'video/quicktime',
          size: AttachmentViewModel.maxFileBytes + 1,
        );
      final vm = AttachmentViewModel(picker, _FakeActions());
      final hints = <AttachHint>[];
      final sub = vm.hints.listen(hints.add);
      await vm.pickVideo(ImageSourceKind.gallery);
      picker.denyCamera = true;
      await vm.pickVideo(ImageSourceKind.camera);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<AttachmentEmpty>());
      expect(hints, [
        AttachHint.fileTooLarge,
        AttachHint.cameraPermissionDenied,
      ]);
      await sub.cancel();
      vm.dispose();
    },
  );

  test(
    'pasteFromClipboard: images become inline, files become chips, text yields a hint',
    () async {
      final dir = await Directory.systemTemp.createTemp('rp-paste');
      addTearDown(() => dir.delete(recursive: true));
      final png = File('${dir.path}/shot.png')..writeAsBytesSync([1, 2, 3]);
      final pasteboard = _FakePasteboard()
        ..items = [
          PendingFile(
            path: png.path,
            name: 'shot.png',
            mime: 'image/png',
            size: 3,
          ),
          clip,
        ];
      final vm = AttachmentViewModel(_FakePicker(), _FakeActions(), pasteboard);
      expect(await vm.pasteFromClipboard(), isTrue);
      final s = vm.state as AttachmentAttached;
      expect(s.images, hasLength(1));
      expect(s.files, [clip]);

      pasteboard.items = const [];
      final hints = <AttachHint>[];
      final sub = vm.hints.listen(hints.add);
      expect(await vm.pasteFromClipboard(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(hints, [AttachHint.nothingToPaste]);
      expect((vm.state as AttachmentAttached).files, [clip]); // unchanged
      await sub.cancel();
      vm.dispose();
    },
  );

  test(
    'without a pasteboard bridge paste reports nothing and stays text',
    () async {
      final vm = AttachmentViewModel(_FakePicker(), _FakeActions());
      expect(await vm.pasteFromClipboard(), isFalse);
      expect(vm.state, isA<AttachmentEmpty>());
      vm.dispose();
    },
  );

  test(
    'Share sheet: a shared file waits for its own pane, then attaches unsent',
    () async {
      final drafts = ShareDrafts();
      final actions = _FakeActions()
        ..meta = const ActiveRoomMeta(peerEpk: 'epkA', roomId: 'other');
      final vm = AttachmentViewModel(_FakePicker(), actions, null, drafts);
      const clip = PendingFile(
        path: '/tmp/clip.mov',
        name: 'clip.mov',
        mime: 'video/quicktime',
        size: 10,
      );
      drafts.add('epkA', 'main', clip);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<AttachmentEmpty>(), reason: 'another pane is open');

      actions.pushMeta(const ActiveRoomMeta(peerEpk: 'epkA', roomId: 'main'));
      await Future<void>.delayed(Duration.zero);
      expect((vm.state as AttachmentAttached).files.single.name, 'clip.mov');
      expect(drafts.take('epkA', 'main'), isEmpty, reason: 'claimed once');
      vm.dispose();
    },
  );
}
