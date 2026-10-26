import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/30 — drives image attachment for the composer.
///
/// Owns the picked-image preview state and tracks whether the active model
/// accepts images (`vision`). Vision is resolved from the model catalogue the
/// app already fetches for the quick-actions picker (plan 28): cached in
/// [IActionsRepository], re-resolved whenever the active model changes.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker, this._actions)
    : super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  final IImagePickerService _picker;
  final IActionsRepository _actions;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed) for the host page.
  Stream<AttachHint> get hints => _hints.stream;

  bool get hasImage => state is AttachmentAttached;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(_picker.pickFromCamera);
  Future<void> pickFromGallery() => _pick(_picker.pickFromGallery);

  /// Weiss Labs: an image pasted straight into the composer.
  Future<void> attachBytes(Uint8List bytes, String mime) =>
      _pick(() => _picker.fromBytes(bytes, mime));

  // Weiss Labs: several images per message; a new pick adds to the list.
  List<PickedImage> get _attached => switch (state) {
    AttachmentAttached(:final images) => images,
    _ => _held,
  };
  // Images kept while a further pick is in flight.
  List<PickedImage> _held = const [];

  void _emitImages(List<PickedImage> images, bool? vision) {
    _held = const [];
    emit(images.isEmpty
        ? AttachmentEmpty(visionSupported: vision)
        : AttachmentAttached(images: List.unmodifiable(images), visionSupported: vision));
  }

  /// The relay drops frames over 4 MiB; base64 adds a third, so keep all
  /// images under ~2.6 MB raw together.
  static const maxTotalBytes = 2_600_000;

  Future<void> _pick(Future<PickedImage?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    final before = _attached;
    _held = before;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final img = await pick();
      if (img != null &&
          before.fold(0, (n, i) => n + i.bytes.length) + img.bytes.length > maxTotalBytes) {
        _emitImages(before, vision);
        if (!_hints.isClosed) _hints.add(AttachHint.tooLarge);
        return;
      }
      _emitImages(img == null ? before : [...before, img], vision);
    } on ImagePermissionDeniedException {
      _emitImages(before, vision);
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      _emitImages(before, vision);
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Discard one attached image (the "X" on its preview), or all of them.
  void removeImage([int? index]) {
    final s = state;
    if (s is! AttachmentAttached) return;
    final next = [...s.images];
    if (index == null) {
      next.clear();
    } else if (index >= 0 && index < next.length) {
      next.removeAt(index);
    }
    _emitImages(next, s.visionSupported);
  }

  /// Hand every attached image to the send path as base64 and reset to empty.
  List<MessageImage> takeImagesForSend() {
    final s = state;
    if (s is! AttachmentAttached) return const [];
    _emitImages(const [], s.visionSupported);
    return [
      for (final i in s.images) MessageImage(data: base64Encode(i.bytes), mime: i.mime),
    ];
  }

  /// First attached image only (kept for older callers/tests).
  MessageImage? takeImageForSend() {
    final all = takeImagesForSend();
    return all.isEmpty ? null : all.first;
  }

  // ---------------------------------------------------------------------------
  // Vision tracking (#9)
  // ---------------------------------------------------------------------------

  Future<void> _refreshVision() async {
    if (_resolvingVision) return;
    _resolvingVision = true;
    try {
      // Cached per (peer, room) by the repo; only the round-trip after a real
      // model change actually hits the Pi.
      final catalogue = await _actions.listModels();
      _setVision(_resolveVision(catalogue));
    } catch (_) {
      // Offline / no catalogue yet → leave vision unknown (don't gate).
    } finally {
      _resolvingVision = false;
    }
  }

  bool? _resolveVision(ModelsCatalogue catalogue) {
    final current = catalogue.current;
    if (current != null) return current.vision;
    // No explicit current — match the active room's model name.
    final name = _actions.activeRoomMeta.model;
    if (name != null) {
      for (final m in catalogue.models) {
        if (m.name == name) return m.vision;
      }
    }
    return null;
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking() => AttachmentPicking(visionSupported: vision),
      AttachmentAttached(:final images) => AttachmentAttached(
        images: images,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _metaSub?.cancel();
    _hints.close();
    super.dispose();
  }
}
