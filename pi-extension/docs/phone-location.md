# Phone location for nearby asks (`request_location`, plan 76)

One fresh fix from the paired phone for an explicit nearby ask ("find me a
minyan"). Not tracking: no history, no background location, nothing stored on
the phone. The phone answers only when the user turned on **Settings →
Location → Share location when a pane asks** (default off; turning it on asks
iOS for While-Using permission and stays off unless granted).

## Tool

`request_location({ purpose })` (purpose ≤240, shown nowhere sensitive). One
pending request per pane, 20 s timeout, abort and session change safe
(`session_start` / `session_tree` / `session_shutdown`).

- Success: `Phone location ±N m, captured HH:MM:SS (N s old). Coordinates saved
  to PATH (private, deleted after 15 min)` (Mac local time). The model never
  sees the coordinates.
- Error (tool fails): names the reason (`off`, `denied`, `background`,
  `unavailable` = no fix, `stale` = fix older than 120 s, `not_open` = no phone
  connected or no answer in 20 s) and tells the model to use the home location
  labeled "from home, live location unavailable (<reason>)".

The paired chat channel is relay-readable, so the coordinates never enter the
model's context: anything the model sees it could echo (split across stream
chunks, as tool arguments, …). The tool writes `lat,lng` to
`~/.pi/remote/location/loc-<32 hex>` (directory 0700, file 0600, O_EXCL,
deleted after 15 min, when the session ends, and by a sweep of expired files at
startup and before each write) and returns only the path, which the consuming script
reads (`mincha.py --at-file PATH`, which prints "your phone location", never the
numbers). Limits: anyone running as the Mac user can read the file during its
TTL; GoDaven receives the coordinates for its search, and the shul addresses it
returns reveal the neighborhood to the relay-readable chat.

## Wire (inside the normal paired channel)

```jsonc
// Pi → phone (no coordinates)
{ "type": "location_request", "id", "mac_key", "room", "session", "expires_at", "purpose", "mac_epk", "sig" }
{ "type": "location_result", "in_reply_to", "id", "ok", "error?" }
// phone → Pi
{ "type": "location_response", "id", "request_id", "phone_key", "phone_epk", "nonce", "ciphertext", "sig" }
```

Plaintext: `{lat, lng, accuracy_m, captured_at}` or `{error: off|denied|background|unavailable}`.
`session_sync` replays a still-pending request; the phone ignores a repeat id.

## Crypto

Exactly the credential handoff construction (`docs/private-credentials.md`)
with its own domain strings, so a credential request or reply can never
verify, derive or decrypt as a location one (tested both ways):

- request: `"remote-pi-location-request-v1\n" + JSON([mac_key, room, session, id, expires_at, purpose, mac_epk])`, Mac Ed25519
- key: HKDF-SHA256(X25519, salt `remote-pi-location-v1-salt`, info `"remote-pi-location-v1-key\n" + JSON([mac_epk, phone_epk, id])`)
- AES-256-GCM with the canonical request as AAD
- response: `"remote-pi-location-response-v1\n" + JSON([sha256(request), id, phone_key, mac_epk, phone_epk, nonce, ciphertext])`, phone Owner Ed25519

The phone re-checks the setting, foreground state and permission after the
fix (and natively before returning it), checks setting and foreground once
more right before sending (an encrypted error replaces the fix if either
changed), and remembers answered request ids
app-wide until expiry so a replay is never answered twice.

The Mac accepts only from the durably paired phone on its active channel, for
the single pending request of the current session generation, before expiry,
rechecking authority after decryption. Vectors: `src/location/vectors.json` =
`app/test/data/location/vectors.json`.

## Real-device only

CoreLocation permission prompt, `requestLocation` fix quality/timing, and the
foreground check run only on a phone; unit tests fake them.
