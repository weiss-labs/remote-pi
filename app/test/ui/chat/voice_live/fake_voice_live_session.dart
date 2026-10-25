import 'package:flutter/foundation.dart';
import 'package:app/ui/chat/voice_live/voice_live_session.dart';

class FakeVoiceLiveSession extends ChangeNotifier implements VoiceLiveSession {
  @override
  VoiceLivePhase phase = VoiceLivePhase.listening;
  @override
  String? endedReason;
  @override
  List<VoiceLiveItem> items = [];
  @override
  VoiceApproval? pendingApproval;
  @override
  double micLevel = .35;
  @override
  double voiceLevel = .7;
  @override
  bool muted = false;
  @override
  Duration elapsed = const Duration(seconds: 83);
  @override
  double costUsd = .069;
  @override
  bool costFinal = false;
  final List<(String, bool)> decisions = [];
  final List<(String, String)> seen = [];
  final List<String> texts = [];
  int starts = 0;
  int cancels = 0;
  @override
  Future<void> start() async {
    starts++;
    phase = VoiceLivePhase.connecting;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    phase = VoiceLivePhase.ended;
    endedReason = 'Stopped';
    costFinal = true;
    notifyListeners();
  }

  @override
  void setMuted(bool v) {
    muted = v;
    notifyListeners();
  }

  @override
  Future<void> sendText(String t) async {
    texts.add(t);
  }

  @override
  Future<void> approve(String id, bool allow) async {
    decisions.add((id, allow));
  }

  @override
  Future<void> draftSeen(String id, String hash) async {
    seen.add((id, hash));
  }

  @override
  Future<void> cancelWork() async {
    cancels++;
  }
}
