# Native iOS notifications

This app uses APNs directly through the private relay. There is no Firebase dependency. Android reports notifications as unavailable.

## Permission and privacy

Settings contains an explicit Allow notifications switch. Nothing requests permission at boot. iOS authorization and APNs registration status are read silently; enabling the switch requests alert, badge and sound authorization. Input needed, credential or sign-in needed, task finished and task failed are selected by default. Input needed and credential needed are labeled high priority. Existing saved category selections gain credential needed once during migration; later explicit opt-outs persist. Tests failed, review ready, update available and connection lost are opt-in. Pane names are off by default. The app never puts chat content, tool arguments or client information into registration requests.

Preferences, last permission state, a device-local random ID, grant expiry and a bounded tap deduplication history persist in the existing secure storage. The APNs token stays in memory and is refreshed by the native registration callback. It is not logged. APNs may rotate tokens, and every paired connection/reconnect re-registers current settings. Settings changed while another paired Mac is offline apply when that Mac connects.

## Protocol

The app sends `notify_register` to the active paired Pi, never directly to the relay. Fields are `id`, `device_id`, `token`, `environment`, `categories`, `show_pane_name`, `expires_at`, `signature`. The existing Owner Ed25519 key used by the paired socket signs UTF-8 bytes:

```
remote-pi-notify-device-v1\n
```

The prefix ends with one actual newline, immediately followed by compact JSON of this ordered array:

```
[canonicalPiBase64, canonicalOwnerBase64, device_id, token, environment, categories, show_pane_name, expires_at]
```

Grants expire seven days after registration. Expiry is persisted monotonically so disable/re-enable in one second cannot replay a revoked grant. The backend must validate both the phone signature and its own paired-Pi countersignature, as implemented by the backend worker. Disabled or OS-denied permission sends `notify_unregister {id, device_id}`. Both operations wait for `notification_registration {in_reply_to, ok, error?}`. A successful socket write is not success. Timeout, rejection and reconnect remain observable and retry. `apns_disabled` (and legacy `apns_unconfigured`) displays an unavailable-service state, never successful registration. No credentials means no successful registration claim.

The eighth category is `credential_needed`. It uses the same signed category array and validated generic tap path. The app does not detect credential failures, collect passwords, unlock desktop 1Password or transport secrets. Actual credential detection and high-priority delivery are backend responsibilities; support for the category alone does not establish automatic detector coverage.

The app intentionally does not send phone-global `notify_presence`. The native notification delegate suppresses only a foreground alert whose peer AND room match the currently visible chat. Other rooms remain eligible. Focus and OS settings can still prevent delivery.

## Taps

`remote_pi` must contain `v:1`, a recognized `kind`, `peer`, and `event_id`. Native code queues cold taps until Dart subscribes. Dart waits for router boot, verifies the peer against current pairing storage, and deduplicates. The room must match the paired QR room or an actual relay-announced/cached room for that peer. Validation directly awaits persisted room hydration on cold start. Unknown, stale or missing rooms safely clear selection and go to Home without creating a session; known rooms open the normal chat. Any payload route or action is ignored. Phone opens a fresh chat; tablet selects its existing detail pane. Revoked/unpaired targets are refused.

## Signing and release

`Runner.entitlements` contains `aps-environment = $(APNS_ENVIRONMENT)`. Debug uses `development` (wire `sandbox`); Profile and Release use `production`, including TestFlight. The same build setting is exposed in Info.plist so token registration uses the matching environment. Existing developer team and provisioning profile names were not changed.

Before a signed release, the main agent must enable Push Notifications on `ai.weisslabs.remotepi` and refresh the distribution provisioning profile to include `aps-environment`. Main also provisions the APNs key on the private relay. A no-codesign build cannot prove entitlement/profile compatibility or APNs delivery.

## Checks

From `app/`:

```
flutter analyze --no-pub
flutter test --no-pub
swiftc ios/Runner/NotificationPresentationPolicy.swift test/native/main.swift -o /tmp/notification-policy-tests
/tmp/notification-policy-tests
flutter build ios --no-codesign --no-pub
```

Focused Dart tests cover startup permission behavior, default privacy, settings persistence, signed grants, explicit unregister, correlated ACKs, timeout/reconnect/rotation, cold/warm payload parsing, deduplication and unpaired refusal. The widget test verifies interactive toggles and minimum 44-point rows. Native policy tests cover matching room, other room, other peer, background, absent visible chat and malformed payload.

Real-phone cold/warm delivery, Focus behavior, production APNs credentials and the integrated paired-Pi/relay flow still need release verification by main. No deployment or TestFlight upload is performed by this worker.
