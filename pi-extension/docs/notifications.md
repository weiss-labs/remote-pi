# Native APNs notifications

## Authorization and privacy

Relay key authentication proves possession of a key, not pairing. A registration needs BOTH the paired phone's Ed25519 signature and the target Mac's countersignature over the same domain-separated grant. The Pi only signs for the sender of an attached channel that still exists in durable pairing storage. The relay requires the authenticated connection key to equal that grant's target Mac. Body-supplied target identities never select authority. Neither mesh co-membership nor arbitrary relay key possession grants notification access.

Grant bytes are UTF-8 of `remote-pi-notify-device-v1\n` followed by compact JSON of this ordered array, with no spaces:

```text
[mac_public_key,phone_public_key,device_id,token,environment,categories,show_pane_name,expires_at]
```

Keys and signatures use padded standard base64. Categories retain their wire order. Expiry is an integer Unix timestamp in seconds, greater than now and no more than 30 days ahead. Use a 29-day default and monotonically increasing expiry per Mac/device for every preference/token change or re-enable, including same-second changes. The relay rejects older grants and revoked equal-expiry grants. A phone must renew before expiry while connected to its paired Mac.

Registrations, category preferences, expiry and revocation tombstones survive relay restart in a separate SQLite DB. The DB and its backup must be treated as secret because APNs tokens are present. It contains no message, tool argument or agent-output bodies. Generic event deduplication/rate metadata is bounded and pruned. Pending notifications are memory-only, not a message archive. A restart drops pending pushes rather than delivering old work. No tokens, signatures, key contents or push payloads are logged.

Lock-screen bodies are fixed generic category messages. Pane names are included only when the signed device preference `show_pane_name` is true, and only when a producer supplies a bounded label. Queued sends recheck current registration, token, environment, preferences, foreground state and expiry. Revocation cannot recall an APNs request already in flight or a notification already delivered.

## Paired-room wire contract

The phone sends ordinary inner room messages to the paired Pi, never a direct relay registration. All carry a bounded unique `id`.

```typescript
{ type: 'notify_register', id, device_id, token,
  environment: 'production' | 'sandbox',
  categories: ['input_needed', 'task_finished', 'task_failed'],
  show_pane_name: false, expires_at, signature: phoneSignatureBase64 }
{ type: 'notify_unregister', id, device_id }
{ type: 'notify_presence', id, device_id, foreground: true, room }
```

A register frame must contain a genuine phone signature of the grant bytes above. `room` in presence is advisory and ignored by the Pi: the authenticated Pi connection's actual room is authoritative. Send foreground presence on room entry, background/leave presence with `foreground:false`, and refresh foreground presence at least every 60 seconds. Suppression expires after 120 seconds so a killed phone cannot suppress notifications indefinitely.

The paired Pi countersigns and sends relay control `register_notification_device {id,grant:{peer,phone,device_id,token,environment,categories,show_pane_name,expires_at,signature,pi_signature}}`. Unregister and presence controls derive `phone` from the attached paired channel, never from user input. Relay replies and the phone-facing replies use:

```typescript
{ type: 'notification_registration', in_reply_to: originalRequestId,
  ok: boolean, error?: 'apns_disabled' /* or bounded error code */ }
```

No token is echoed. Success acknowledges registration/event acceptance, not delivery. Missing configuration returns `apns_disabled`; an old relay that lacks these controls times out honestly. Protocol routing must recognize this server message. Tap routing must require the canonical peer to be currently paired and validate the room against that peer's rooms; an incoming push must never execute a command or create a pairing.

Push custom data is `remote_pi:{v:1,peer,room,event_id,kind}`. `peer` is the canonical target Mac relay key, not a display label or mesh address. For release notifications the room is the device's last registered paired room, not the release command's temporary connection room. A stale/nonexistent room needs a safe app fallback.

## Categories and event production

`input_needed` has highest importance, a dedicated bounded queue independent of ordinary retry backoff, APNs priority 10 and `time-sensitive` interruption level. iOS permissions, entitlements, Focus and user settings still control presentation. It cannot bypass those controls.

Defaults are phone-owned: input_needed, task_finished and task_failed ON; tests_failed, review_ready, update_available and connection_lost opt-in. Registration sends the complete desired category array, including an empty array to disable all.

Observed events are agent run start/end, terminal assistant/provider `stopReason:error`, and interactive prompts actually forwarded by the existing extension UI bridge (not notify/dismissal frames). A failed, aborted or input-blocked run does not also announce success. `agent_end` is a low-level run boundary, not a guarantee that no queued continuation exists. These hooks do not claim to classify arbitrary questions, test output or every native extension dialog.

The explicit `notify_user` agent tool accepts only input_needed, task_finished, task_failed, tests_failed and review_ready. Use input_needed when waiting for approval or an answer, review_ready for finished work awaiting review, and tests_failed only after an actual failed test/build. It takes no free-form content. There is no per-tool-invocation notification or regex guess from arbitrary stdout. Release/update and connection_lost are not agent tool choices.

Connection loss comes from a relay-observed disconnect of a connection explicitly marked active by agent_start or a confirmed remote Pi Voice call. Voice state comes from the bridge session plus Pi Voice isActive(), refreshed on voice RPCs/heartbeats with a 90-second activity lease. Normal agent_end, explicit stop and orderly session shutdown clear activity. A stale duplicate connection does not alert while another active connection remains for that room. An idle disconnect does not alert. A relay outage cannot send its own push. An old voice activity lease expires rather than keeping a stopped call active indefinitely.

Deduplication keeps event identity metadata for 24 hours (maximum 10,000 events), limits each Mac to 30 events per minute, and limits each device/category to one queued push per 30 seconds across rooms. Maxima are 16 devices per Mac, 10,000 devices globally, 20,000 grant/tombstone rows, 64 input pushes and 128 ordinary pushes queued. Each connection accepts at most 120 notification controls per minute and 8 KiB per notification frame. APNs attempts are bounded to three within a two-minute event TTL, with 1 and 2 second backoff and a 10-second HTTP timeout. HTTP/2 is mandatory. JWTs are reused for up to 50 minutes. Invalid APNs token/topic responses delete the matching token/environment; permanent auth/config failures are not retried. Pending events are not durable, and APNs delivery is never guaranteed.

## Relay configuration

Set these in the existing relay service environment, outside source control:

```text
REMOTEPI_APNS_KEY_PATH=/secure/path/AuthKey_APNS.p8
REMOTEPI_APNS_TEAM_ID=<Apple team id>
REMOTEPI_APNS_KEY_ID=<APNs key id>
REMOTEPI_APNS_TOPIC=ai.weisslabs.remotepi
REMOTEPI_NOTIFICATIONS_DB_PATH=/persistent/private/path/notifications.db
REMOTEPI_NOTIFICATION_UPDATE_RECIPIENTS=<canonicalMacKey>:<canonicalZachPhoneKey>
```

The last variable accepts comma-separated exact Mac:phone pairs and defaults to an empty allowlist. Neither an arbitrary Mac nor another paired owner's phone can receive release-hook notifications. The device must also opt in to update_available. Keep the DB volume durable and private. Key files belong in 1Password-backed deployment configuration with mode 0600, never git. An App Store Connect API key is not automatically an APNs-enabled key. TestFlight requires the production APNs environment. Missing any APNs variable disables transport and new registration; an explicitly configured but unreadable/invalid key fails startup rather than pretending delivery works.

Deploy order is relay support first, extension second, then phone build. Existing notification registrations continue after relay restart if the SQLite volume is preserved. Pairing revocation requests are acknowledged before interactive/CLI local pairing removal; if unavailable, those commands retain the pairing and explain the retry requirement. Signed Owner-driven removal reconciles immediately when online, and each subsequent Pi connection reconciles durable paired phones against relay registrations. An offline Mac cannot instantly revoke a cached device; grant expiry bounds that window.

## Successful TestFlight hook

Only the main release script should call this after verifying a real successful TestFlight upload/build, never before:

```sh
remote-pi notify-release <successful-TestFlight-build-id>
```

This connects using readExistingEd25519Keypair, which neither creates nor migrates keys, and submits `notification_release {release_id}`. The relay enforces the explicit Mac:phone allowlist and opted-in preferences. Reusing a release id is deduplicated for 24 hours. The command alone does not independently verify App Store Connect success; the trusted release script owns that condition. An accepted event does not claim that an update is already processed/installable by Apple.

## Verification and rollout limits

Unit tests use fake APNs only. Rust integration tests exercise WebSocket auth, grant rejection and disabled replies. Tests cover bilateral binding, expiry, restart durability, replay after revocation, privacy, foreground suppression, category preferences, retries/invalid tokens, scoped releases and active-only disconnect. TypeScript tests cover phone signature binding, disabled/old relay handling, bounded pending requests, lifecycle and explicit events.

No live notifications, credentials, deployment, reload or restart were performed by this worker. Main still owns signed-device integration review, APNs credential setup, private persistent storage, ship-script integration and a real TestFlight phone test for every category, foreground suppression, notification taps, token rotation, revocation, expiry and Focus/permission denial. Real-device evidence is required before calling this delivered.
