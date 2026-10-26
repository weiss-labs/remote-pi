import 'dart:async';
import 'dart:convert';

import 'package:app/data/voice_live/voice_live_transport.dart';
import 'package:app/data/voice_live/voice_media.dart';
import 'package:app/domain/contracts/voice_live_session.dart';
import 'package:flutter/foundation.dart';

/// Plan 71 — a Pi Voice call from the phone. Mirrors what Pi Voice's own
/// window does (ui/app.js): SDP through `/session`, a 1 Hz `/heartbeat`, and
/// user actions. Everything that matters (key, sideband, Pi requests,
/// approval and draft rules, cost, handoff) stays on the Mac.
class VoiceLiveController extends ChangeNotifier implements VoiceLiveSession {
  VoiceLiveController(
    this._transport,
    this._mediaFactory, {
    Duration heartbeat = const Duration(seconds: 1),
    Duration levels = const Duration(milliseconds: 120),
    Duration readyTimeout = const Duration(seconds: 15),
    DateTime Function() now = DateTime.now,
  }) : _heartbeatEvery = heartbeat,
       _levelsEvery = levels,
       _readyTimeout = readyTimeout,
       _now = now;

  final VoiceRpcTransport _transport;
  final VoiceMedia Function() _mediaFactory;
  final Duration _heartbeatEvery, _levelsEvery, _readyTimeout;
  final DateTime Function() _now;

  VoiceMedia? _media;
  Timer? _beat, _levelTimer, _readyTimer;
  final List<StreamSubscription<Object?>> _subs = [];
  bool _opened = false, _ready = false, _finishing = false, _beating = false;
  // Bumped by every start and finish; a startup step that resumes after a
  // Stop sees a different run and backs out instead of opening the mic or
  // a paid session.
  int _run = 0;
  int _cursor = 0, _beatFailures = 0;
  final Set<String> _seenTranscript = {};
  final Map<String, int> _typedIndex = {};
  bool _backendBusy = false;
  DateTime _lastVoice = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastZach = DateTime.fromMillisecondsSinceEpoch(0);

  VoiceLivePhase _phase = VoiceLivePhase.idle;
  String? _endedReason;
  String _label = '';
  final List<VoiceLiveItem> _items = [];
  VoiceToolApproval? _approval;
  VoiceDraft? _draft;
  double _mic = 0, _voice = 0;
  bool _muted = false;
  Duration _elapsed = Duration.zero;
  double _cost = 0, _rate = 0.05;
  bool _costFinal = false;

  @override
  VoiceLivePhase get phase => _phase;
  @override
  String? get endedReason => _endedReason;
  @override
  String get label => _label;
  @override
  List<VoiceLiveItem> get items => List.unmodifiable(_items);
  @override
  VoiceToolApproval? get pendingApproval => _approval;
  @override
  VoiceDraft? get draft => _draft;
  @override
  double get micLevel => _muted ? 0 : _mic;
  @override
  double get voiceLevel => _voice;
  @override
  bool get muted => _muted;
  @override
  Duration get elapsed => _elapsed;
  @override
  double get costUsd => _cost;
  @override
  bool get costFinal => _costFinal;
  @override
  double get ratePerMinute => _rate;

  bool get _live =>
      _opened &&
      !_finishing &&
      _phase != VoiceLivePhase.ended &&
      _phase != VoiceLivePhase.error;

  // --- lifecycle -------------------------------------------------------------

  @override
  Future<void> start() async {
    if (_phase != VoiceLivePhase.idle &&
        _phase != VoiceLivePhase.ended &&
        _phase != VoiceLivePhase.error) {
      return;
    }
    _reset();
    final run = ++_run;
    _set(VoiceLivePhase.connecting);
    try {
      final opened = await _transport.open();
      if (run != _run) {
        // Stopped while the Mac was opening: end that Mac session too.
        await _transport.close();
        return;
      }
      _opened = true;
      _label = opened.label;
      _rate = opened.ratePerMinute;
      final media = _media = _mediaFactory();
      _subs.add(media.providerEvents.listen(_onProviderEvent));
      _subs.add(media.failures.listen((r) => _finish(r, error: true)));
      final offer = await media.createOffer();
      if (run != _run) return; // _finish already closed media + session
      media.setMicEnabled(!_muted); // a mute tapped while connecting holds
      final reply = await _transport.rpc('/session', {'sdp': offer});
      if (run != _run) return;
      if (!reply.ok) {
        await _finish(reply.error, error: true);
        return;
      }
      final answer = (reply.map['transport'] as Map?)?['sdp'];
      if (answer is! String) {
        await _finish('Unexpected answer from Pi Voice.', error: true);
        return;
      }
      await media.setAnswer(answer);
      if (run != _run) return;
      _readyTimer = Timer(_readyTimeout, () {
        if (!_ready) _finish('Voice did not become ready', error: true);
      });
      _beat = Timer.periodic(_heartbeatEvery, (_) => _heartbeat());
      _levelTimer = Timer.periodic(_levelsEvery, (_) => _sampleLevels());
      unawaited(_heartbeat());
    } on VoiceFailure catch (e) {
      if (run == _run) await _finish(_openMessage(e), error: true);
    } catch (e) {
      if (run != _run) return;
      await _finish(
        _opened
            ? 'Connection failed. $e'
            : 'Microphone or connection unavailable. $e',
        error: true,
      );
    }
  }

  @override
  Future<void> stop() => _finish('Ended');

  Future<void> _finish(String reason, {bool error = false}) async {
    if (_finishing ||
        _phase == VoiceLivePhase.ended ||
        _phase == VoiceLivePhase.error) {
      return;
    }
    _finishing = true;
    _run++; // any startup step still in flight backs out
    _beat?.cancel();
    _levelTimer?.cancel();
    _readyTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _media?.close();
    _media = null;
    if (_opened) {
      // Always end the paid session on the Mac (its watchdog would too, in 15s).
      await _transport.close();
      _opened = false;
    }
    _mic = _voice = 0;
    _endedReason = reason;
    _finishing = false;
    _set(error ? VoiceLivePhase.error : VoiceLivePhase.ended);
  }

  void _reset() {
    _items.clear();
    _seenTranscript.clear();
    _typedIndex.clear();
    _approval = null;
    _draft = null;
    _cursor = 0;
    _beatFailures = 0;
    _ready = false;
    _backendBusy = false;
    _endedReason = null;
    _cost = 0;
    _costFinal = false;
    _elapsed = Duration.zero;
  }

  static String _openMessage(VoiceFailure e) => switch (e.code) {
    'busy' => 'Pi Voice is already open for this pane on the Mac.',
    'not_idle' => 'Start voice when the pane is idle with nothing queued.',
    'key_locked' => 'Unlock 1Password on the Mac, then try again.',
    'offline' => 'Not connected to the Mac.',
    _ =>
      e.message.isEmpty ? 'Pi Voice is unavailable in this pane.' : e.message,
  };

  // --- provider events (data channel) ----------------------------------------

  void _onProviderEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'session.started':
        _ready = true;
        _readyTimer?.cancel();
        _derive();
      case 'session.input_transcript.delta' ||
          'session.output_transcript.delta':
        _transcript(
          e['event_id'] as String?,
          (e['type'] as String).contains('input_')
              ? VoiceLiveItemKind.zach
              : VoiceLiveItemKind.voice,
          e['delta'] as String? ?? '',
        );
      case 'session.closed':
        unawaited(_finish('Provider ended the session'));
      case 'error':
        unawaited(
          _finish('Voice provider error. No automatic retry', error: true),
        );
    }
  }

  void _transcript(String? id, VoiceLiveItemKind kind, String delta) {
    if (id != null && !_seenTranscript.add(id)) return;
    if (delta.isEmpty) return;
    if (kind == VoiceLiveItemKind.zach) _lastZach = _now();
    final last = _items.isEmpty ? null : _items.last;
    if (last != null && last.kind == kind) {
      _items[_items.length - 1] = last.copyWith(text: last.text + delta);
    } else {
      _items.add(
        VoiceLiveItem(id: id ?? 'tx-${_items.length}', kind: kind, text: delta),
      );
    }
    _derive(force: true);
  }

  // --- heartbeat (Mac state) -------------------------------------------------

  Future<void> _heartbeat() async {
    if (!_live || _beating) return;
    _beating = true;
    try {
      final r = await _transport.rpc('/heartbeat', {'after': _cursor});
      _beatFailures = 0;
      if (!_live) return;
      if (r.status == 409 || r.status == 410) {
        await _finish(
          r.map['error'] as String? ?? 'Voice session ended on the Mac',
        );
        return;
      }
      if (!r.ok) return;
      _apply(r.map);
    } catch (_) {
      // The Mac's 15 s watchdog ends the paid session if we stay gone.
      if (++_beatFailures >= 5) {
        await _finish('Lost connection to the Mac', error: true);
      }
    } finally {
      _beating = false;
    }
  }

  void _apply(Map<String, dynamic> s) {
    _cursor = (s['cursor'] as num?)?.toInt() ?? _cursor;
    _cost =
        ((s['voiceCostUSD'] as num?) ?? 0).toDouble() +
        ((s['previewCostUSD'] as num?) ?? 0).toDouble();
    _costFinal = s['voiceCostFinal'] == true;
    _elapsed = Duration(
      seconds: (s['elapsedSeconds'] as num?)?.toInt() ?? _elapsed.inSeconds,
    );
    _backendBusy = (s['backendRequests'] as List?)?.isNotEmpty ?? false;
    _approval = _toolApproval(s['pendingApprovals']);
    final prevDraft = _draft, nextDraft = _toDraft(s['draft']);
    // Keep a confirmed review across a heartbeat that left before it landed.
    _draft =
        nextDraft != null &&
            prevDraft != null &&
            prevDraft.seen &&
            !nextDraft.seen &&
            prevDraft.id == nextDraft.id &&
            prevDraft.hash == nextDraft.hash
        ? prevDraft
        : nextDraft;
    for (final e in (s['events'] as List? ?? const [])) {
      if (e is Map<String, dynamic>) _event(e);
    }
    final phase = s['phase'];
    if (phase == 'stopping' || phase == 'stopped') {
      unawaited(
        _finish(
          (s['reason'] as String?)?.isNotEmpty == true
              ? s['reason'] as String
              : 'Voice ended on the Mac',
        ),
      );
      return;
    }
    _derive(force: true);
  }

  void _event(Map<String, dynamic> e) {
    final id = e['id']?.toString();
    switch (e['kind']) {
      case 'transcript':
        _transcript(
          id,
          e['role'] == 'Zach'
              ? VoiceLiveItemKind.zach
              : VoiceLiveItemKind.voice,
          e['delta'] as String? ?? '',
        );
      case 'typed':
        final i = id == null ? null : _typedIndex[id];
        if (i != null) {
          _items[i] = _items[i].copyWith(pending: false);
        } else {
          _items.add(
            VoiceLiveItem(
              id: id ?? 'typed-${_items.length}',
              kind: VoiceLiveItemKind.typed,
              text: e['text'] as String? ?? '',
            ),
          );
          if (id != null) _typedIndex[id] = _items.length - 1;
        }
      case 'backend':
        final i = _items.indexWhere(
          (x) => x.kind == VoiceLiveItemKind.backend && x.id == id,
        );
        final item = VoiceLiveItem(
          id: id ?? 'backend-${_items.length}',
          kind: VoiceLiveItemKind.backend,
          text: e['text'] as String? ?? '',
          status: e['status'] as String?,
        );
        if (i >= 0) {
          _items[i] = item;
        } else {
          _items.add(item);
        }
      case 'notice':
        _notice(e['text'] as String? ?? '');
    }
  }

  void _notice(String text) {
    if (text.isEmpty) return;
    _items.add(
      VoiceLiveItem(
        id: 'notice-${_items.length}-${_now().microsecondsSinceEpoch}',
        kind: VoiceLiveItemKind.notice,
        text: text,
      ),
    );
  }

  static VoiceToolApproval? _toolApproval(Object? list) {
    if (list is! List || list.isEmpty || list.first is! Map) return null;
    final a = list.first as Map;
    return VoiceToolApproval(
      id: a['id'].toString(),
      tool: a['tool']?.toString() ?? '',
      args: const JsonEncoder.withIndent('  ').convert(a['args']),
      title: a['title']?.toString() ?? 'Allow once?',
    );
  }

  static VoiceDraft? _toDraft(Object? d) {
    if (d is! Map) return null;
    return VoiceDraft(
      id: d['id'].toString(),
      hash: d['hash'].toString(),
      title: d['title']?.toString() ?? 'DRAFT',
      raw: d['raw']?.toString() ?? '',
      eligible: d['eligible'] == true,
      seen: d['seen'] == true,
      error: d['error']?.toString(),
      attachments: [
        for (final a in (d['attachments'] as List? ?? const []))
          if (a is Map)
            VoiceDraftAttachment(
              id: a['id'].toString(),
              name: a['name']?.toString() ?? 'attachment',
              size: (a['size'] as num?)?.toInt() ?? 0,
              mime: a['mime']?.toString() ?? 'application/octet-stream',
            ),
      ],
    );
  }

  // --- levels and phase --------------------------------------------------------

  Future<void> _sampleLevels() async {
    final m = _media;
    if (m == null || !_live) return;
    final l = await m.levels();
    if (!_live) return;
    _mic = _smooth(_mic, l.mic);
    _voice = _smooth(_voice, l.voice);
    if (l.voice > 0.02) _lastVoice = _now();
    _derive(force: true);
  }

  static double _smooth(double prev, double next) =>
      prev + (next - prev) * (next > prev ? 0.5 : 0.2);

  void _derive({bool force = false}) {
    if (!_live) return;
    final now = _now();
    final VoiceLivePhase next;
    if (!_ready) {
      next = VoiceLivePhase.connecting;
    } else if (now.difference(_lastVoice) < const Duration(milliseconds: 500)) {
      next = VoiceLivePhase.speaking;
    } else if (_backendBusy) {
      next = VoiceLivePhase.working;
    } else if (_items.isNotEmpty &&
        _items.last.kind == VoiceLiveItemKind.zach &&
        now.difference(_lastZach) < const Duration(seconds: 6)) {
      next = VoiceLivePhase.thinking;
    } else {
      next = VoiceLivePhase.listening;
    }
    if (next != _phase) {
      _phase = next;
      notifyListeners();
    } else if (force) {
      notifyListeners();
    }
  }

  void _set(VoiceLivePhase p) {
    _phase = p;
    notifyListeners();
  }

  // --- actions -----------------------------------------------------------------

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _media?.setMicEnabled(!muted);
    notifyListeners();
  }

  @override
  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || !_live) return;
    _items.add(
      VoiceLiveItem(
        id: 'local-${_items.length}',
        kind: VoiceLiveItemKind.typed,
        text: t,
        pending: true,
      ),
    );
    final i = _items.length - 1;
    notifyListeners();
    try {
      final r = await _transport.rpc('/text', {'text': t});
      if (!r.ok) throw VoiceFailure('rejected', r.error);
      final id = r.map['id']?.toString();
      if (id != null) _typedIndex[id] = i;
      _items[i] = _items[i].copyWith(pending: false);
    } catch (e) {
      // Never resent automatically (Pi Voice rule).
      _items[i] = _items[i].copyWith(pending: false, status: 'unconfirmed');
      _notice('Message delivery unconfirmed. $e');
    }
    notifyListeners();
  }

  /// Throws on refusal so the UI keeps its card and lets Zach retry.
  Future<void> _action(String path, Map<String, dynamic> body) async {
    if (!_live) throw const VoiceFailure('ended', 'The call has ended.');
    final r = await _transport.rpc(path, body);
    if (!r.ok) throw VoiceFailure('rejected', r.error);
  }

  @override
  Future<void> approve(String id, bool allow) =>
      _action('/approve', {'id': id, 'decision': allow ? 'allow' : 'deny'});

  @override
  Future<void> draftSeen(String id, String hash) async {
    final d = _draft;
    if (d == null || d.id != id || d.hash != hash) {
      throw const VoiceFailure(
        'stale',
        'This draft changed. Review the new one.',
      );
    }
    if (d.seen) return;
    await _action('/draft-seen', {'id': id, 'hash': hash});
    final now = _draft;
    if (now != null && now.id == id && now.hash == hash) {
      _draft = VoiceDraft(
        id: now.id,
        hash: now.hash,
        title: now.title,
        raw: now.raw,
        eligible: now.eligible,
        seen: true,
        error: now.error,
        attachments: now.attachments,
      );
      notifyListeners();
    }
  }

  @override
  Future<void> confirmDraft() async {
    final d = _draft;
    if (d == null || !d.eligible || !d.seen) {
      throw const VoiceFailure('not_ready', 'Review the complete draft first.');
    }
    final r = await _transport.rpc('/text', {
      'text': d.isApproval ? 'approve it' : 'send it',
    });
    if (!r.ok) throw VoiceFailure('rejected', r.error);
    final id = r.map['id']?.toString();
    _items.add(
      VoiceLiveItem(
        id: id ?? 'typed-${_items.length}',
        kind: VoiceLiveItemKind.typed,
        text: d.isApproval ? 'approve it' : 'send it',
      ),
    );
    if (id != null) _typedIndex[id] = _items.length - 1;
    notifyListeners();
  }

  @override
  Future<void> cancelWork() async {
    try {
      await _action('/cancel-work', {});
    } catch (e) {
      _notice('$e');
      notifyListeners();
    }
  }

  @override
  Future<({Uint8List bytes, String mime})> attachment(
    String draftId,
    String attachmentId,
  ) async {
    final r = await _transport.rpc('/attachment', {
      'draftId': draftId,
      'id': attachmentId,
    });
    if (!r.ok) throw VoiceFailure('attachment', r.error);
    return (
      bytes: base64Decode(r.map['data'] as String? ?? ''),
      mime: r.map['mime'] as String? ?? 'application/octet-stream',
    );
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // Leaving the screen ends the paid session.
    if (_opened) unawaited(_finish('Closed'));
    _disposed = true;
    super.dispose();
  }
}

/// Plan 71 — one fresh call per Voice screen. The UI asks the injector for
/// this and calls [create]; the session talks to whichever pane is active.
class VoiceLiveFactory {
  VoiceLiveFactory(this._create);
  final VoiceLiveSession Function() _create;
  VoiceLiveSession create() => _create();
}
