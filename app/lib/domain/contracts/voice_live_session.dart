import 'package:flutter/foundation.dart';

/// Weiss Labs, plan 71 — Pi Voice on the phone.
///
/// The phone is a second window for the Mac's Pi Voice: GPT-Live audio goes
/// phone ↔ OpenAI over WebRTC, and the Pi Voice brain on the Mac (sideband,
/// Pi requests, approvals, drafts, cost, handoff) is reached over the relay.
/// The UI binds only to this contract; `data/voice_live` implements it.
enum VoiceLivePhase {
  idle,
  connecting,
  listening,
  thinking,
  speaking,

  /// Pi is executing a request the voice delegated.
  working,
  ended,
  error,
}

enum VoiceLiveItemKind { zach, voice, typed, backend, notice }

@immutable
class VoiceLiveItem {
  const VoiceLiveItem({
    required this.id,
    required this.kind,
    required this.text,
    this.status,
    this.pending = false,
  });

  final String id;
  final VoiceLiveItemKind kind;
  final String text;

  /// Backend items: queued, working, done, failed, cancelled.
  final String? status;

  /// Typed message not yet confirmed by the Mac.
  final bool pending;

  VoiceLiveItem copyWith({String? text, String? status, bool? pending}) =>
      VoiceLiveItem(
        id: id,
        kind: kind,
        text: text ?? this.text,
        status: status ?? this.status,
        pending: pending ?? this.pending,
      );
}

/// A tool Pi wants to run that needs an explicit "Allow once".
@immutable
class VoiceToolApproval {
  const VoiceToolApproval({
    required this.id,
    required this.tool,
    required this.args,
    required this.title,
  });

  final String id;
  final String tool;

  /// Exact arguments, pretty-printed JSON. Render in full, never truncated.
  final String args;
  final String title;
}

@immutable
class VoiceDraftAttachment {
  const VoiceDraftAttachment({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
  });
  final String id;
  final String name;
  final int size;
  final String mime;
}

/// An email/WhatsApp/iMessage draft (or payment approval) Pi prepared.
@immutable
class VoiceDraft {
  const VoiceDraft({
    required this.id,
    required this.hash,
    required this.title,
    required this.raw,
    required this.eligible,
    required this.seen,
    this.error,
    this.attachments = const [],
  });

  final String id;
  final String hash;

  /// e.g. "EMAIL DRAFT", "WHATSAPP DRAFT", "... APPROVAL".
  final String title;

  /// The complete card text. Render in full, never truncated.
  final String raw;
  final bool eligible;
  final bool seen;
  final String? error;
  final List<VoiceDraftAttachment> attachments;

  bool get isApproval => title.endsWith('APPROVAL');
}

abstract class VoiceLiveSession implements Listenable {
  VoiceLivePhase get phase;

  /// Why the call ended or failed, in plain words.
  String? get endedReason;

  /// Pane name the Mac reports (Herdr path).
  String get label;
  List<VoiceLiveItem> get items;
  VoiceToolApproval? get pendingApproval;
  VoiceDraft? get draft;

  /// 0..1 levels for the orb.
  double get micLevel;
  double get voiceLevel;
  bool get muted;
  Duration get elapsed;

  /// GPT-Live cost. Estimated while live; final once the provider confirms.
  double get costUsd;
  bool get costFinal;
  double get ratePerMinute;

  Future<void> start();
  Future<void> stop();
  void setMuted(bool muted);
  Future<void> sendText(String text);

  /// Only from a genuine tap on the approval card.
  Future<void> approve(String id, bool allow);

  /// Call once the complete draft card (and its attachments) is on screen.
  Future<void> draftSeen(String id, String hash);

  /// "Send this exact draft" / "Approve" button: passes the canonical
  /// instruction to Pi Voice, whose exact-draft rules still decide.
  Future<void> confirmDraft();
  Future<void> cancelWork();

  /// Bytes of a draft attachment for its preview (image/PDF/text).
  Future<({Uint8List bytes, String mime})> attachment(
    String draftId,
    String attachmentId,
  );
}
