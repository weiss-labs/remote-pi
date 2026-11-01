# Plan 76: phone location for nearby requests (fleet #155)

Status: planned, not built. Build and release each need Zach's go.

## Goal
"Find me a minyan" (and similar nearby asks) uses where Zach actually is,
without asking him each time. Not tracking: one fresh fix per explicit request.

## Shape (smallest that works)
1. **Mac tool `request_location({purpose})`** in the Remote Pi extension. The
   pane calls it only for a nearby request. It sends a signed
   `location_request {id, purpose, mac_epk, expires_at}` to the paired phone
   and waits up to 20 s.
2. **Phone reply is encrypted.** The paired channel is NOT end-to-end
   encrypted (`PlainPeerChannel` / `ws_transport.dart` only base64 the JSON;
   the relay can read it). So the reply reuses the private-credential crypto
   (`src/credentials/crypto.ts`, `app/lib/data/credentials/credential_crypto.dart`):
   phone verifies the Mac-signed request, then sends
   `location_response {in_reply_to, phone_epk, nonce, ciphertext, sig}` where
   the plaintext is `{lat, lng, accuracy_m, captured_at}` or
   `{error: off|denied|unavailable|stale}`, X25519+HKDF to AES-256-GCM with the
   request as AAD, phone-signed. Bound to request id, room, session and phone
   key; late, replayed or foreign replies are refused. The relay sees only
   ciphertext.
3. **Tool result** to the model: coordinates, accuracy, capture time and age,
   e.g. "Phone location 40.6205,-73.9811 ±12 m, 8 s old". On any error it
   says so and names the fallback honestly: "Using home (5811 20th Ave), not
   live location."
4. **Phone setting** "Share location when a pane asks", default OFF. Turning it
   on triggers the normal iOS "While Using the App" prompt. Off, denied, or app
   in the background → `error`, never a guess. No "Always" permission, no
   background location, nothing stored on the phone.
5. **Native CoreLocation** through the existing method-channel pattern in
   AppDelegate (`requestLocation`, one fix); no new Flutter dependency.
   Info.plist gets `NSLocationWhenInUseUsageDescription`.
6. **mincha skill**: `mincha.py --at LAT,LNG` searches GoDaven around that
   point (default stays home); SKILL.md tells the pane to call
   `request_location` for nearby asks and to label a home fallback.

## Not doing
IP geolocation (too coarse for walking distance), any third-party lookup,
location history, background tracking, automatic OS setting changes, sending
maps or directions to anyone.

## Honest limits
- Ordinary chat messages over the relay are not end-to-end encrypted today
  (existing state, separate from this plan). Location, like credentials, is.
- Works when Remote Pi is open on the phone (the usual case when Zach asks
  from it). Asked from the Mac keyboard with the phone asleep → "unavailable",
  home fallback, labeled.
- The coordinates the tool returns are saved in that pane's session log like
  any tool result.
