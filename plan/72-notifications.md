# 72 — Weiss Labs notifications (2026-10-26)

Zach approved all seven types, especially when a pane needs his input. This supersedes the no-push MVP restriction and upstream plan 36's Firebase/publisher dependency for this private fork.

## Scope

| Kind | Default | Trigger |
|---|---|---|
| input_needed | on, priority | actual question/choice UI or explicit agent blocked/input event |
| task_finished | on | completed agent loop, not individual tools/LLM turns |
| task_failed | on | terminal failure/stop, not retrying failures |
| tests_failed | optional | verified test/build failure or explicit event |
| review_ready | optional | explicit ready-to-review event |
| update_available | optional | verified TestFlight release |
| connection_lost | optional | connection lost during work/call, not every idle disconnect |

No heuristic should pretend every natural-language question or command result is semantically understood. Where SDK signals are absent use an explicit bounded notification tool and document coverage.

## Delivery

Native APNs for own bundle ai.weisslabs.remotepi, production environment for TestFlight; existing own VPS relay delivers. Do not add Firebase or send client content to upstream publisher. Durable device token + preferences; permission requested via user action; token rotation and unregistration; foreground current-room suppression; generic private lock-screen body; tap routes only to an existing paired peer/room. No push carries raw assistant text, tool args, draft bodies or secrets. Dedup and rate limiting are essential.

Relay Ed25519 login is not proof of pairing. Registration/delivery authorization must bind actual paired owner, target Mac, device token and environment, with revocation. Backend worker owns concrete signed-grant protocol and coordinates app worker before final integration. Tests must demonstrate non-owner cannot register/notify someone else's device.

## Implementation ownership

- App worktree `../remote-pi-notify-app`, branch notify-app, Astra medium: native iOS token/tap bridge, settings, Dart registration/notifications, routing tests.
- Backend worktree `../remote-pi-notify-backend`, branch notify-backend, Sol high: extension event production and relay APNs delivery, secure registration, tests.
- Main: Apple capability/profile and APNs key setup, independent integration/security review, deploy existing relay (preserve pairing DB), extension immutable release, TestFlight, live phone smoke verification.
- Workers commit locally only; no push/deploy/reload. Main does not promise notifications are live before APNs acceptance and real device verification.

## Provisioning status

- Enabled PUSH_NOTIFICATIONS on bundle id KNT5P73A8N through ASC API, confirmed capability KNT5P73A8N_PUSH_NOTIFICATIONS.
- Apple Developer keys page currently requires Zach login. Need dedicated APNs credential, stored in Business 1Password and root-only VPS config; never use an ASC upload key as an APNs key by assumption.
- Must regenerate the App Store profile to include aps-environment after worker entitlements are ready. Do not delete a currently installed signing profile before replacement succeeds.

## Release verification

Unit/integration tests for authorization, token rotation, revocation, dedup, failure classes, deep-link safety and payload privacy. Live APNs smoke with safe synthetic labels and exact device: foreground, background/locked, tap, permission denied. Apple delivery can be suppressed by Focus/user settings or networking; APNs accepted is not proof the phone displayed a banner. Record measured limitations. Existing vps-health must watch notification dependencies; no extra unmonitored server.
