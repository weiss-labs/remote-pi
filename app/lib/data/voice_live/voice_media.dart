import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Plan 71 — the phone's audio leg of a Pi Voice call: mic up, GPT-Live voice
/// down, directly with OpenAI over WebRTC (DTLS-SRTP). The SDP answer comes
/// from the Mac's Pi Voice via the relay, so no key ever touches the phone.
abstract class VoiceMedia {
  /// Mic + peer + `oai-events` data channel; returns the complete offer SDP
  /// (ICE gathered, no trickle), the same way Pi Voice's window does.
  Future<String> createOffer();
  Future<void> setAnswer(String sdp);

  /// Provider events from the data channel (session.started, transcript
  /// deltas, session.closed, error).
  Stream<Map<String, dynamic>> get providerEvents;

  /// Fires once if the audio link drops.
  Stream<String> get failures;
  void setMicEnabled(bool enabled);

  /// 0..1 input (mic) and output (GPT-Live) levels for the orb.
  Future<({double mic, double voice})> levels();
  Future<void> close();
}

class WebRtcVoiceMedia implements VoiceMedia {
  RTCPeerConnection? _peer;
  MediaStream? _mic;
  RTCDataChannel? _channel;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _failures = StreamController<String>.broadcast();
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get providerEvents => _events.stream;
  @override
  Stream<String> get failures => _failures.stream;

  void _fail(String reason) {
    if (_closed || _failures.isClosed) return;
    _failures.add(reason);
  }

  @override
  Future<String> createOffer() async {
    // Echo-cancelled voice chat; AirPods/Bluetooth allowed, speaker otherwise.
    await Helper.setAppleAudioConfiguration(
      AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playAndRecord,
        appleAudioCategoryOptions: {
          AppleAudioCategoryOption.allowBluetooth,
          AppleAudioCategoryOption.allowBluetoothA2DP,
          AppleAudioCategoryOption.defaultToSpeaker,
        },
        appleAudioMode: AppleAudioMode.voiceChat,
      ),
    );
    _mic = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    final peer = _peer = await createPeerConnection({});
    for (final track in _mic!.getAudioTracks()) {
      await peer.addTrack(track, _mic!);
    }
    // Remote audio plays through the native audio unit automatically.
    peer.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _fail('Audio connection lost');
      }
    };
    final channel = _channel = await peer.createDataChannel(
      'oai-events',
      RTCDataChannelInit(),
    );
    channel.onMessage = (m) {
      try {
        final e = jsonDecode(m.text);
        if (e is Map<String, dynamic> && !_events.isClosed) _events.add(e);
      } catch (_) {
        _fail('Invalid voice event');
      }
    };
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _fail('Voice disconnected');
      }
    };

    final gathered = Completer<void>();
    peer.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await peer.createOffer({'offerToReceiveAudio': true});
    await peer.setLocalDescription(offer);
    if (peer.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Audio connection timed out.'),
      );
    }
    final local = await peer.getLocalDescription();
    if (local?.sdp == null) throw StateError('No audio offer');
    return local!.sdp!;
  }

  @override
  Future<void> setAnswer(String sdp) async {
    await _peer?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  void setMicEnabled(bool enabled) {
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  @override
  Future<({double mic, double voice})> levels() async {
    final peer = _peer;
    if (peer == null) return (mic: 0.0, voice: 0.0);
    var mic = 0.0, voice = 0.0;
    try {
      for (final r in await peer.getStats()) {
        final level = (r.values['audioLevel'] as num?)?.toDouble();
        if (level == null) continue;
        if (r.type == 'media-source') mic = level;
        if (r.type == 'inbound-rtp' && r.values['kind'] == 'audio') {
          voice = level;
        }
      }
    } catch (_) {}
    return (mic: mic.clamp(0.0, 1.0), voice: voice.clamp(0.0, 1.0));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel?.close();
    } catch (_) {}
    for (final t in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _mic?.dispose();
    await _peer?.close();
    await _events.close();
    await _failures.close();
  }
}
