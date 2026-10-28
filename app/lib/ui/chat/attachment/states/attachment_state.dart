import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/contracts/file_transfer.dart';

/// Plan/30 — composer attachment state.
///
/// Models the one-image pick lifecycle (empty → picking → attached) and
/// carries [visionSupported] so the attach button can grey out for a
/// text-only model (#9). `visionSupported` is tri-state: `true`/`false` once
/// the model catalogue is known, `null` while unknown (don't gate yet).
sealed class AttachmentState {
  const AttachmentState({required this.visionSupported});

  /// Whether the active model accepts images. `null` = not yet known.
  final bool? visionSupported;

  /// Convenience: gate the attach affordance only when we *know* it's false.
  bool get attachBlockedByVision => visionSupported == false;
}

/// No image attached; composer behaves as text/voice.
final class AttachmentEmpty extends AttachmentState {
  const AttachmentEmpty({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentEmpty && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// A pick is in flight (camera/gallery sheet → compression).
final class AttachmentPicking extends AttachmentState {
  const AttachmentPicking({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentPicking && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// One or more images and/or files (plan/74: videos, pasted or shared files)
/// are attached and previewed in the composer.
final class AttachmentAttached extends AttachmentState {
  const AttachmentAttached({
    this.images = const [],
    this.files = const [],
    super.visionSupported,
  }) : assert(images.length > 0 || files.length > 0);

  final List<PickedImage> images;
  final List<PendingFile> files;
  PickedImage get image => images.first;

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      identical(other.images, images) &&
      identical(other.files, files) &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(
    identityHashCode(images),
    identityHashCode(files),
    visionSupported,
  );
}

/// One-shot hints the composer asks the host page to surface (snackbar /
/// settings deep-link), mirroring the voice [VoiceHint] pattern.
enum AttachHint {
  /// Camera permission denied — guide to system Settings (#10).
  cameraPermissionDenied,

  /// Pick/compress failed for some other reason.
  pickFailed,

  /// Adding this image would push the message past what the relay accepts.
  tooLarge,

  /// Plan/74 — a video/file over the 200 MiB upload cap.
  fileTooLarge,

  /// Plan/74 — the pasteboard held nothing attachable (text stays text).
  nothingToPaste,
}
