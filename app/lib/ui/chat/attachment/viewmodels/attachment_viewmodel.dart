import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/images/pasteboard_service.dart';
import 'package:app/domain/contracts/file_transfer.dart';
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
  AttachmentViewModel(this._picker, this._actions, [this._pasteboard])
    : super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  final IImagePickerService _picker;
  final IActionsRepository _actions;
  final IPasteboardService? _pasteboard;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed) for the host page.
  Stream<AttachHint> get hints => _hints.stream;

  /// Anything attached (images and/or files); the composer treats both alike.
  bool get hasImage => state is AttachmentAttached;
  bool get hasFiles =>
      state is AttachmentAttached && (state as AttachmentAttached).files.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(_picker.pickFromCamera);
  Future<void> pickFromGallery() => _pick(_picker.pickFromGallery);

  /// Weiss Labs: an image pasted straight into the composer.
  Future<void> attachBytes(Uint8List bytes, String mime) =>
      _pick(() => _picker.fromBytes(bytes, mime));

  /// Plan/74 — pick (gallery) or record (camera) a video. Sent as a chunked
  /// upload, never inline, so it does not count against [maxTotalBytes].
  Future<void> pickVideo(ImageSourceKind source) =>
      _pickFile(() => _picker.pickVideo(source));

  /// Plan/74 — a file handed over by the Share extension or the pasteboard.
  Future<void> attachFile(PendingFile file) => _pickFile(() async => file);

  /// Plan/74 — turn copied images/videos/files into real attachments.
  /// Returns false (and hints) when the pasteboard holds nothing attachable,
  /// so the caller can fall back to a plain text paste.
  Future<bool> pasteFromClipboard() async {
    final items = await _pasteboard?.readAttachments() ?? const <PendingFile>[];
    if (items.isEmpty) {
      if (!_hints.isClosed) _hints.add(AttachHint.nothingToPaste);
      return false;
    }
    for (final item in items) {
      if (item.mime.startsWith('image/')) {
        Uint8List bytes;
        try {
          bytes = await File(item.path).readAsBytes();
        } on FileSystemException {
          continue;
        }
        await attachBytes(bytes, item.mime);
      } else {
        await attachFile(item);
      }
    }
    return true;
  }

  // Weiss Labs: several images per message; a new pick adds to the list.
  List<PickedImage> get _attached => switch (state) {
    AttachmentAttached(:final images) => images,
    _ => _held,
  };
  List<PendingFile> get _attachedFiles => switch (state) {
    AttachmentAttached(:final files) => files,
    _ => _heldFiles,
  };
  // Attachments kept while a further pick is in flight.
  List<PickedImage> _held = const [];
  List<PendingFile> _heldFiles = const [];

  void _emitImages(List<PickedImage> images, bool? vision) =>
      _emitAll(images, _attachedFiles, vision);

  void _emitAll(List<PickedImage> images, List<PendingFile> files, bool? vision) {
    _held = const [];
    _heldFiles = const [];
    emit(images.isEmpty && files.isEmpty
        ? AttachmentEmpty(visionSupported: vision)
        : AttachmentAttached(
            images: List.unmodifiable(images),
            files: List.unmodifiable(files),
            visionSupported: vision,
          ));
  }

  /// Plan/74 — the Mac refuses anything larger; refuse here first.
  static const maxFileBytes = 200 * 1024 * 1024;

  Future<void> _pickFile(Future<PendingFile?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    final images = _attached, before = _attachedFiles;
    _held = images;
    _heldFiles = before;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final file = await pick();
      if (file != null && (file.size <= 0 || file.size > maxFileBytes)) {
        _emitAll(images, before, vision);
        if (!_hints.isClosed) _hints.add(AttachHint.fileTooLarge);
        return;
      }
      _emitAll(images, file == null ? before : [...before, file], vision);
    } on ImagePermissionDeniedException {
      _emitAll(images, before, vision);
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      _emitAll(images, before, vision);
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Discard one attached file (the "X" on its chip).
  void removeFile(int index) {
    final s = state;
    if (s is! AttachmentAttached || index < 0 || index >= s.files.length) {
      return;
    }
    _emitAll(s.images, [...s.files]..removeAt(index), s.visionSupported);
  }

  /// Hand every attached file to the upload path and keep the images.
  List<PendingFile> takeFilesForSend() {
    final s = state;
    if (s is! AttachmentAttached || s.files.isEmpty) return const [];
    _emitAll(s.images, const [], s.visionSupported);
    return s.files;
  }

  /// The relay drops frames over 4 MiB; base64 adds a third, so keep all
  /// images under ~2.6 MB raw together.
  static const maxTotalBytes = 2_600_000;

  Future<void> _pick(Future<PickedImage?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    final before = _attached;
    _held = before;
    _heldFiles = _attachedFiles;
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

  /// Hand every attached image to the send path as base64 and keep the files.
  List<MessageImage> takeImagesForSend() {
    final s = state;
    if (s is! AttachmentAttached || s.images.isEmpty) return const [];
    _emitAll(const [], s.files, s.visionSupported);
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
      AttachmentAttached(:final images, :final files) => AttachmentAttached(
        images: images,
        files: files,
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
