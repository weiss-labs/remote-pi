# 71 — Pi Voice on the phone (GPT-Live over the relay)

Status: design, October 25, 2026. Zach: "I want the voice to sound exactly like [Pi Voice]. I want it using the live model, as sophisticated and strong as we're doing it here, using the relay."

## Principle: the phone is a second window for the same Pi Voice

Pi Voice on the Mac is already split in two:

- **Brain (Mac, in the pane's Pi process):** `~/Documents/programs/pi-voice` — `src/server.mjs` + `extension.ts`. Holds the OpenAI key (1Password, memory only), creates the GPT-Live session, attaches the server-side **sideband** (`/v1/live/sessions/{id}/attach`), turns provider-verified speech into Pi requests, runs the approval/draft rules, publishes events, bills, hands off to the Pi chat.
- **Window (thin UI):** `ui/app.js` in a native WebView. It does three things: (1) WebRTC audio with OpenAI, using an SDP offer that the brain exchanges for it (`POST /session {sdp}` → answer SDP; the key never reaches the window); (2) polls `POST /heartbeat {after}` for events; (3) sends user actions (`/text`, `/approve`, `/draft-seen`, `/cancel-work`, `/stop`, …).

The phone replaces only the window. Same brain, same model, same voice, same approvals, same handoff. There is no second, weaker implementation to drift.

```
iPhone (Remote Pi WL)                    Relay (VPS)          Mac pane (Pi)
┌──────────────────────┐   voice_rpc     ┌────────┐          ┌───────────────────────────┐
│ Voice screen (Astra) │ ──────────────► │ room   │ ───────► │ remote-pi ext: VoiceBridge │
│ VoiceSession (data)  │ ◄────────────── │ frames │ ◄─────── │   → 127.0.0.1 Pi Voice API │
│ flutter_webrtc       │                 └────────┘          │ Pi Voice brain + sideband  │
└─────────┬────────────┘                                     └─────────────┬─────────────┘
          │  DTLS-SRTP audio, direct (not through the relay)               │ sideband WS
          └──────────────────────────► OpenAI GPT-Live ◄────────────────────┘
```

Audio goes phone ↔ OpenAI directly, so latency is the same as the Mac window. The relay carries only small control frames: SDP once, then one heartbeat a second plus actions.

## Mac side

### A. pi-voice: a "remote window" start mode (small, additive)

- Factor the `/voice` open path into `openVoice(ctx, frontend)` where `frontend` is `'native'` (today: spawn the signed app with `bootstrap.json`) or `'remote'` (don't spawn; return `{origin, token}` to the caller).
- Expose it in-process: `globalThis.__piVoice = { openRemote(): Promise<{origin, token, label}>, stop(reason), isActive() }`. The ctx comes from the latest `session_start` / command context the extension already pins. The same preconditions apply: pane idle, nothing queued, only one voice session per pane. If the Mac window is already live, the phone gets `busy` and never silently takes it over.
- Everything else is unchanged: brain, key loading, sideband, bypass setting, approvals, the 15-second heartbeat watchdog (the phone dropping off ends the paid session), cost, handoff and recovery.
- Release follows pi-voice's own path: `npm run check` then `bash scripts/install.sh`, then `/reload` per pane.

### B. remote-pi extension: VoiceBridge (forwarder, no logic)

New app→extension messages on the pane's existing room channel:

| Message | Reply | Notes |
|---|---|---|
| `voice_open {}` | `voice_opened {label, ratePerMinute}` or `voice_error {code: busy|not_idle|key_locked|unavailable, text}` | calls `__piVoice.openRemote()` |
| `voice_rpc {id, path, body}` | `voice_rpc_result {id, status, body}` | forwards to `POST {origin}{path}` with `Authorization: Bearer token`, `Origin: origin`, JSON |
| `voice_close {}` | `voice_rpc_result` of `/stop` | also sent by the app on leave/background |

- Path allowlist (deny by default): `/info`, `/session`, `/heartbeat`, `/text`, `/approve`, `/draft-seen`, `/cancel-work`, `/stop`, `/attachment` (draft attachment previews only, size-capped for the relay). Not exposed: `/screen` (no desktop control from the phone in v1), `/preferences` (Mac mic devices), `/events` (window fallback), `/model`, `/models`, `/voice-preview`, `/attachment-open`, `/capture-result`.
- Only the paired, authenticated owner peer of that room can call it (the same gate as `user_message`). Token and origin never leave the Mac.
- One in-flight `/session` at a time; per-path body caps match the server's (`/session` ≤ 60 KB SDP).

### C. Relay

No relay change. These are ordinary room frames like `user_message`. Payloads are TLS to our own relay. Media is DTLS-SRTP end to end with OpenAI and never transits the relay.

## Phone side

### D. Data layer (Claude builds): `lib/data/voice_live/`

- `VoiceLiveTransport` — RPC over the active room: `open()`, `rpc(path, body)` with ids and timeouts, `close()`.
- `VoiceLiveSession` — the state machine the UI binds to:
  - `start()`: `voice_open` → configure iOS AVAudioSession (playAndRecord, voiceChat, speaker by default, Bluetooth/AirPods allowed) → `flutter_webrtc` peer with mic track and `oai-events` data channel → offer → `rpc('/session', {sdp})` → set answer → play remote track.
  - 1 Hz heartbeat loop: `rpc('/heartbeat', {after: cursor})` → typed events (`transcript`, `typed`, `backend`, `approval`, `approval_resolved`, `notice`, drafts) + state (`phase`, `backendStatus`, `voiceCostUSD`, `elapsedSeconds`, `pendingApprovals`).
  - Actions: `sendText`, `approve(id, allow|deny)` (only from a genuine button tap), `draftSeen(id, hash)` (only after the full draft card has actually rendered on screen), `cancelWork`, `mute(bool)` (local track enable; billing continues, same as Mac), `stop()`.
  - Mic level stream and remote (assistant) audio level stream for the orb.
  - Ends cleanly on: user stop, app backgrounded without the audio background mode, relay loss (the brain's watchdog also stops it within 15 s), pane offline, provider error. It always tells the user why.
- Dependencies: `flutter_webrtc`, plus an iOS `UIBackgroundModes: audio` entry so a call survives screen lock (AirPods at the gym). Mic usage string already exists.

### E. Contract for the UI (Astra designs against this)

```dart
abstract class VoiceLiveSession implements Listenable {
  VoiceLivePhase get phase;      // connecting, listening, thinking, speaking, working, ended, error
  String? get endedReason;
  List<VoiceLiveItem> get items; // speaker bubbles (Zach/Voice, streaming deltas), typed, backend status, notices
  VoiceApproval? get pendingApproval;   // exact tool + args, or a draft card (to/subject/body/attachments)
  double get micLevel;           // 0..1
  double get voiceLevel;         // 0..1 (assistant playback)
  bool get muted;
  Duration get elapsed;
  double get costUsd; bool get costFinal;
  Future<void> start(); Future<void> stop();
  void setMuted(bool v); Future<void> sendText(String t);
  Future<void> approve(String id, bool allow); Future<void> draftSeen(String id, String hash);
  Future<void> cancelWork();
}
```

The UI must render draft and approval cards in full (scrollable, never truncated). It may call `draftSeen` only once the whole card has been on screen, which is Pi Voice's visibility rule. "Send it" spoken by voice still goes through the brain's exact-draft rules; the phone adds no shortcut.

## Safety carried over unchanged

- Exact-text send, payment and destructive approvals: the brain plus the pane's normal hooks decide. The phone only displays and forwards genuine taps.
- Bypass: follows the Mac's `/voice bypass` setting. The phone does not change it.
- No auto-reconnect or replay of a paid session (Pi Voice rule). Reconnect is a new session started explicitly by the user.
- Cost: GPT-Live at $0.05/min, shown live; the final subtotal comes from provider usage.
- Screen control from the phone: off in v1.

## Build order and proof

1. pi-voice remote mode with unit tests using a fake provider; `npm run check`.
2. VoiceBridge in the remote-pi extension with vitest: allowlist, auth gate, forwarding and error mapping.
3. App `voice_live` data layer with a fake transport and fake peer: state machine tests.
4. Astra's UI on the contract (review gallery).
5. Live smoke test. This is metered, about $0.05/min, and needs Zach present: a 2-minute call from the phone to a scratch pane, a harmless read request, one approval card, stop. Then check: cost in the handoff, transcript in the Pi chat, session closed on the provider.

Not in v1: screen sharing from the phone, picking a voice from the phone (uses the Mac preference), a GPT-Live engine without the Mac (cloud sessions with the Mac off).
