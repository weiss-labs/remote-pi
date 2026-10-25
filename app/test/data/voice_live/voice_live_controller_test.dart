import 'dart:async';

import 'package:app/data/voice_live/voice_live_controller.dart';
import 'package:app/data/voice_live/voice_live_transport.dart';
import 'package:app/data/voice_live/voice_media.dart';
import 'package:app/domain/contracts/voice_live_session.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTransport implements VoiceRpcTransport {
  VoiceFailure? openError;
  final calls = <(String, Map<String, dynamic>)>[];
  final heartbeats = <VoiceRpcReply>[];
  VoiceRpcReply session = const VoiceRpcReply(200, {
    'transport': {'type': 'webrtc', 'sdp': 'v=0 answer'},
  });
  int closes = 0;
  VoiceRpcReply approveReply = const VoiceRpcReply(200, {'ok': true});

  @override
  Future<VoiceOpenResult> open() async {
    if (openError != null) throw openError!;
    return const VoiceOpenResult(
      label: 'ZachOS › voice mode',
      ratePerMinute: 0.05,
    );
  }

  @override
  Future<VoiceRpcReply> rpc(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    calls.add((path, body));
    return switch (path) {
      '/session' => session,
      '/heartbeat' => _beat(),
      '/text' => const VoiceRpcReply(200, {'id': 't1'}),
      '/approve' => approveReply,
      _ => const VoiceRpcReply(200, {'ok': true}),
    };
  }

  // Like the real server: every heartbeat carries the full state; events
  // are only delivered once.
  Map<String, dynamic> _state = {'phase': 'live'};
  VoiceRpcReply _beat() {
    if (heartbeats.isEmpty) {
      return VoiceRpcReply(200, {..._state, 'events': const []});
    }
    final r = heartbeats.removeAt(0);
    if (r.ok) _state = {...r.map}..remove('events');
    return r;
  }

  @override
  Future<void> close() async => closes++;

  List<String> get paths => calls.map((c) => c.$1).toList();
}

class FakeMedia implements VoiceMedia {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final fails = StreamController<String>.broadcast();
  String? answer;
  bool closed = false, micEnabled = true;
  double voice = 0;

  @override
  Future<String> createOffer() async => 'v=0 offer';
  @override
  Future<void> setAnswer(String sdp) async => answer = sdp;
  @override
  Stream<Map<String, dynamic>> get providerEvents => events.stream;
  @override
  Stream<String> get failures => fails.stream;
  @override
  void setMicEnabled(bool enabled) => micEnabled = enabled;
  @override
  Future<({double mic, double voice})> levels() async =>
      (mic: 0.0, voice: voice);
  @override
  Future<void> close() async => closed = true;
}

void main() {
  late FakeTransport t;
  late FakeMedia m;
  late VoiceLiveController c;

  setUp(() {
    t = FakeTransport();
    m = FakeMedia();
    c = VoiceLiveController(
      t,
      () => m,
      heartbeat: const Duration(milliseconds: 20),
      levels: const Duration(milliseconds: 20),
      readyTimeout: const Duration(seconds: 5),
    );
  });

  tearDown(() => c.dispose());

  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test(
    'connects: SDP through /session, answer applied, live after session.started',
    () async {
      await c.start();
      expect(t.calls.first.$1, '/session');
      expect(t.calls.first.$2, {'sdp': 'v=0 offer'});
      expect(m.answer, 'v=0 answer');
      expect(c.phase, VoiceLivePhase.connecting);
      m.events.add({'type': 'session.started'});
      await settle();
      expect(c.phase, VoiceLivePhase.listening);
      expect(c.label, 'ZachOS › voice mode');
    },
  );

  test('Mac refusal (busy) is explained and opens nothing', () async {
    t.openError = const VoiceFailure('busy', 'x');
    await c.start();
    expect(c.phase, VoiceLivePhase.error);
    expect(c.endedReason, contains('already open'));
    expect(t.calls, isEmpty);
    expect(t.closes, 0);
  });

  test(
    'a failed /session still stops the Mac session (no orphan billing)',
    () async {
      t.session = const VoiceRpcReply(500, {
        'error': 'OpenAI session request failed (HTTP 402).',
      });
      await c.start();
      expect(c.phase, VoiceLivePhase.error);
      expect(c.endedReason, contains('402'));
      expect(t.closes, 1);
      expect(m.closed, isTrue);
    },
  );

  test('heartbeat applies cost, Pi work, approval, draft and events', () async {
    t.heartbeats.add(
      const VoiceRpcReply(200, {
        'phase': 'live',
        'cursor': 4,
        'voiceCostUSD': 0.0125,
        'voiceCostFinal': false,
        'elapsedSeconds': 15,
        'backendRequests': [
          {'id': 'r1', 'status': 'working'},
        ],
        'pendingApprovals': [
          {
            'id': 'a1',
            'tool': 'bash',
            'args': {'command': 'ls'},
            'title': 'Allow bash once?',
          },
        ],
        'draft': {
          'id': 'd1',
          'hash': 'h1',
          'title': 'EMAIL DRAFT',
          'raw': 'To: x',
          'eligible': true,
          'seen': false,
          'attachments': [],
        },
        'events': [
          {
            'kind': 'transcript',
            'id': 'e1',
            'role': 'Zach',
            'delta': 'list my files',
          },
          {
            'kind': 'backend',
            'id': 'r1',
            'status': 'working',
            'text': 'Working in Pi',
          },
          {'kind': 'notice', 'text': 'Pi is busy'},
        ],
      }),
    );
    await c.start();
    m.events.add({'type': 'session.started'});
    await settle();
    expect(c.costUsd, 0.0125);
    expect(c.elapsed, const Duration(seconds: 15));
    expect(c.phase, VoiceLivePhase.working);
    expect(c.pendingApproval!.args, contains('"command": "ls"'));
    expect(c.draft!.title, 'EMAIL DRAFT');
    expect(c.items.map((i) => i.kind), [
      VoiceLiveItemKind.zach,
      VoiceLiveItemKind.backend,
      VoiceLiveItemKind.notice,
    ]);
    expect(t.calls.where((x) => x.$1 == '/heartbeat').skip(1).first.$2, {
      'after': 4,
    });
  });

  test(
    'the same transcript from the data channel and the heartbeat shows once',
    () async {
      t.heartbeats.add(
        const VoiceRpcReply(200, {
          'phase': 'live',
          'events': [
            {
              'kind': 'transcript',
              'id': 'e1',
              'role': 'Voice',
              'delta': 'Hi Zach.',
            },
          ],
        }),
      );
      await c.start();
      m.events.add({'type': 'session.started'});
      m.events.add({
        'type': 'session.output_transcript.delta',
        'event_id': 'e1',
        'delta': 'Hi Zach.',
      });
      await settle();
      expect(c.items.single.text, 'Hi Zach.');
    },
  );

  test(
    'draft confirm only after the card was seen, and sends the canonical words',
    () async {
      t.heartbeats.add(
        const VoiceRpcReply(200, {
          'phase': 'live',
          'draft': {
            'id': 'd1',
            'hash': 'h1',
            'title': 'EMAIL DRAFT',
            'raw': 'To: x',
            'eligible': true,
            'seen': false,
          },
        }),
      );
      await c.start();
      await settle();
      await expectLater(c.confirmDraft(), throwsA(isA<VoiceFailure>()));
      expect(t.paths, isNot(contains('/text')));
      await c.draftSeen('d1', 'h1');
      expect(t.calls.where((x) => x.$1 == '/draft-seen').single.$2, {
        'id': 'd1',
        'hash': 'h1',
      });
      // Applied locally right away; a heartbeat already in flight with
      // seen:false must not undo it.
      expect(c.draft!.seen, isTrue);
      await settle();
      expect(c.draft!.seen, isTrue);
      t.heartbeats.add(
        const VoiceRpcReply(200, {
          'phase': 'live',
          'draft': {
            'id': 'd1',
            'hash': 'h1',
            'title': 'EMAIL DRAFT',
            'raw': 'To: x',
            'eligible': true,
            'seen': true,
          },
        }),
      );
      await settle();
      await c.confirmDraft();
      expect(t.calls.where((x) => x.$1 == '/text').single.$2, {
        'text': 'send it',
      });
    },
  );

  test('the Mac ending the session (410) ends the call', () async {
    t.heartbeats.add(
      const VoiceRpcReply(410, {'error': 'Voice session ended on the Mac'}),
    );
    await c.start();
    await settle();
    expect(c.phase, VoiceLivePhase.ended);
    expect(c.endedReason, 'Voice session ended on the Mac');
    expect(m.closed, isTrue);
  });

  test('audio drop ends the call and stops the Mac session', () async {
    await c.start();
    m.fails.add('Audio connection lost');
    await settle();
    expect(c.phase, VoiceLivePhase.error);
    expect(c.endedReason, 'Audio connection lost');
    expect(t.closes, 1);
  });

  test('mute disables the mic track; stop closes everything once', () async {
    await c.start();
    c.setMuted(true);
    expect(m.micEnabled, isFalse);
    await c.stop();
    await c.stop();
    expect(c.phase, VoiceLivePhase.ended);
    expect(t.closes, 1);
    expect(m.closed, isTrue);
  });

  test('Stop while the Mac is opening: no mic, no /session, Mac session closed', () async {
    final gate = Completer<void>();
    final slow = _SlowOpen(gate);
    final mediaMade = <FakeMedia>[];
    final c2 = VoiceLiveController(slow, () => mediaMade.single, heartbeat: const Duration(milliseconds: 20));
    mediaMade.add(FakeMedia());
    final starting = c2.start();
    await c2.stop();
    gate.complete();
    await starting;
    expect(slow.paths, isEmpty);
    expect(slow.closes, 1);
    expect(c2.phase, VoiceLivePhase.ended);
    c2.dispose();
  });

  test('mute tapped while connecting is applied to the new mic', () async {
    final gate = Completer<void>();
    final slow = _SlowOpen(gate);
    final c2 = VoiceLiveController(slow, () => m, heartbeat: const Duration(milliseconds: 20));
    final starting = c2.start();
    c2.setMuted(true);
    gate.complete();
    await starting;
    expect(m.micEnabled, isFalse);
    await c2.stop();
    c2.dispose();
  });

  test('refused approval surfaces as an error (card keeps retry)', () async {
    t.approveReply = const VoiceRpcReply(409, {'error': 'stale approval'});
    await c.start();
    await expectLater(c.approve('a1', true), throwsA(isA<VoiceFailure>()));
  });

  test('speaking follows the GPT-Live output level', () async {
    await c.start();
    m.events.add({'type': 'session.started'});
    m.voice = 0.4;
    await settle();
    expect(c.phase, VoiceLivePhase.speaking);
  });
}

class _SlowOpen extends FakeTransport {
  _SlowOpen(this.gate);
  final Completer<void> gate;
  @override
  Future<VoiceOpenResult> open() async {
    await gate.future;
    return super.open();
  }
}
