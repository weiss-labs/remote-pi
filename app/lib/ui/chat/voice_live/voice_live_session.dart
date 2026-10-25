import 'package:flutter/foundation.dart';

abstract class VoiceLiveSession implements Listenable {
  VoiceLivePhase
  get phase; // connecting, listening, thinking, speaking, working, ended, error
  String? get endedReason;
  List<VoiceLiveItem>
  get items; // speaker bubbles (Zach/Voice, streaming deltas), typed, backend status, notices
  VoiceApproval?
  get pendingApproval; // exact tool + args, or a draft card (to/subject/body/attachments)
  double get micLevel; // 0..1
  double get voiceLevel; // 0..1 (assistant playback)
  bool get muted;
  Duration get elapsed;
  double get costUsd;
  bool get costFinal;
  Future<void> start();
  Future<void> stop();
  void setMuted(bool v);
  Future<void> sendText(String t);
  Future<void> approve(String id, bool allow);
  Future<void> draftSeen(String id, String hash);
  Future<void> cancelWork();
}

enum VoiceLivePhase {
  connecting,
  listening,
  thinking,
  speaking,
  working,
  ended,
  error,
}

enum VoiceLiveItemKind { transcript, typed, backend, notice }

@immutable
class VoiceLiveItem {
  const VoiceLiveItem({
    required this.id,
    required this.speaker,
    required this.text,
    this.kind = VoiceLiveItemKind.transcript,
  });
  final String id;
  final String speaker;
  final String text;
  final VoiceLiveItemKind kind;
}

@immutable
class VoiceApproval {
  const VoiceApproval({
    required this.id,
    required this.toolName,
    required this.args,
    this.draft,
  });
  final String id;
  final String toolName;
  final Map<String, Object?> args;
  final VoiceDraft? draft;
}

@immutable
class VoiceDraft {
  const VoiceDraft({
    required this.hash,
    required this.to,
    this.cc = const [],
    required this.subject,
    required this.body,
    this.attachments = const [],
  });
  final String hash;
  final List<String> to;
  final List<String> cc;
  final String subject;
  final String body;
  final List<String> attachments;
}
