# Pi Voice phone window

This UI uses the plan 71 `VoiceLiveSession` contract. The abstract class is unchanged in behavior; the accompanying immutable item, approval and draft models define the shared adapter shape.

Zach's direct correction supersedes the earlier ayu redesign. Match the actual Mac Pi Voice, not a new mobile visual language. `pi_voice_theme.dart` ports the dark CSS variables and system typography from `pi-voice/ui/style.css`. `VoiceCloud` ports `app.js`'s 80px cobalt-and-white clipped cloud paths. The transcript is top-anchored, with gray user bubbles and plain assistant text. The cloud sits above the bottom composer.

## Host integration

- Supply `ChatPage.onStartVoiceLive` (passed through to `InputBar`). It is a distinct empty-composer control beside dictation. Offline/working/typing/recording states cannot launch it.
- On that explicit user tap, create the data-layer session, present `VoiceLivePage(session: ..., paneName: ..., keepAwake: ...)` and call `start()` once. The page does not start a metered session on mount.
- The required `keepAwake(bool)` callback is the host's platform adapter. UI enables it while live and releases it after ended/error/dispose. This branch adds no native plugin or dependency.
- The host owns/disposes the session. The data layer owns WebRTC, background handling, relay failure, provider billing, and stop cleanup. No phone-side speech engine is present.
- Populate complete `VoiceApproval` tool name/args and, when applicable, full `VoiceDraft` fields and content hash. Do not truncate in the adapter. A changed draft must have a changed hash.
- `draftSeen` is called only after contiguous viewport coverage through the end of the scrollable content. Jumping over content does not count. Sending stays disabled until the acknowledgment succeeds. Pending calls deduplicate across heartbeat rebuilds. Changed id/hash invalidates review. The brain remains the authority for exact-draft approval.
- Back navigation and the phone's left-edge swipe ask before ending; explicit stop leaves the ended reason and restart control visible. No automatic restart occurs.

The phone contract does not expose desktop screen-sharing, work-model/voice pickers or mic-device selectors. Those controls are intentionally absent rather than fabricated. The cloud hides while the software keyboard is open so the composer remains usable on a small phone.

## Verification

`flutter test --no-pub test/ui/chat/voice_live` covers contiguous draft visibility, disabled send before acknowledgment, approval taps, same-hash heartbeat replacement during acknowledgment, composer gating, typed input, mute, cancel, stop/restart, wake lifecycle, back-edge confirmation and small-phone keyboard layout.

`RP_REVIEW_DIR=/tmp/rp-astra/review flutter test --no-pub test/ui/chat/voice_live/voice_gallery_test.dart` exports synthetic widget previews. macOS review runs load real SF Pro from the system and bundled SF Mono for tool args and the Herdr composer. No provider connection or paid call is made.
