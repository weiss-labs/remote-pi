# Private credential handoff (`request_credential`)

When a pane's own credential retrieval (1Password CLI, cached token) is blocked
because nobody is at the Mac, the model calls `request_credential` naming the
exact 1Password item. The paired phone shows a compact masked form, the user
copies that one value from phone 1Password, and it reaches the Mac encrypted.
The value never appears in a tool result, the transcript, a log, an error, a
notification or the relay. It is written to a private temporary file and the
tool returns only the path.

1Password stays the source of truth. This is a short-lived derived credential
supplied by the user from it. It does not change the existing outgoing-send,
payment, release or desktop Touch ID approvals, and it never asks the phone to
approve anything on the Mac.

## Tool

```
request_credential({ label, reference, purpose })
```

- `label` (≤120): what the user recognises, e.g. `Stripe secret key (live)`.
- `reference` (≤240): `1Password → vault → item → field` or `op://vault/item/field`.
- `purpose` (≤240): one sentence.

Refused up front: only 1Password vault-unlock / whole-vault shortcuts (the
1Password account/master password, the 1Password Secret Key or an `A3-…` value,
Emergency Kit, 1Password recovery codes, 1Password service-account tokens,
`OP_SERVICE_ACCOUNT_TOKEN`/`OP_SESSION`). A Stripe or AWS "secret key", a
service password or a bot token is one scoped credential and is allowed; the
"1Password →" prefix of a reference says where it is found, not what it
unlocks. One pending
request per pane; the request expires after 10 minutes. The tool blocks until
the phone supplies, cancels, the request expires, the run is aborted
(`AbortSignal`), or the session changes (`session_start` / `session_shutdown`
/ `session_tree`). A rejected or mistyped value needs another explicit call;
nothing is resent automatically.

Result (on success only): the private file path, the reference, the expiry and
instructions to use it from an authorized subprocess without printing it, e.g.
`VAR="$(cat <path>)" <command>`. Transfer success is not provider validation.

## Delivery file

- Directory `~/.pi/remote/credentials/`, mode `0700` (re-chmodded on every write).
- File `cred-<32 hex>`, created `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`, fsync'd.
- Deleted after 15 minutes, on session shutdown/start/tree change (this
  process's files), and stale `cred-*` files older than the TTL from other
  processes are swept (never read) on every session start. A failed write
  unlinks any partially created file; a symlink at the directory path is
  refused before any chmod.

## Wire (App ↔ Pi, inside the normal paired channel)

```jsonc
// Pi → phone (metadata + public key + signature only)
{ "type": "credential_request", "id", "mac_key", "room", "session", "expires_at",
  "label", "reference", "purpose", "mac_epk", "sig" }
{ "type": "credential_closed", "id", "reason": "fulfilled|cancelled|expired|session_ended|aborted|none" }
{ "type": "credential_result", "in_reply_to", "id", "ok", "error?" }

// phone → Pi
{ "type": "credential_response", "id", "request_id", "phone_key", "phone_epk", "nonce", "ciphertext", "sig" }
{ "type": "credential_cancel", "id", "request_id" }
{ "type": "credential_query", "id" }   // answered with the pending request, or credential_closed{reason:"none", in_reply_to:id}
```

`session_sync` also replays a pending request. The app does not rely on that
broadcast timing: it sends `credential_query` after the chat binds, on every
reconnect and on app resume, and an authoritative `none` correlated to its own
query id clears a stale form (lost fulfilled/ACK). The push itself is
the generic `credential_needed` category with no item details; its `event_id`
is the request id, whereas the legacy generic blocker uses `<run>-credential_needed`.

## Crypto (standard primitives only)

Canonical bytes are a domain line followed by an ordered JSON array, never
object key order. Node (`src/credentials/crypto.ts`) and Dart
(`app/lib/data/credentials/credential_crypto.dart`) share the vectors in
`src/credentials/vectors.json` / `app/test/data/credentials/vectors.json`.

- Request: Mac generates an ephemeral X25519 key pair and Ed25519-signs
  `"remote-pi-credential-request-v1\n" + JSON([mac_key, room, session, id, expires_at, label, reference, purpose, mac_epk])`
  with its paired Pi-key. `session` is a per-session nonce.
- Phone verifies with the paired Mac key and the exact room before showing
  anything, derives `HKDF-SHA256(X25519(phone_ephemeral, mac_epk), salt="remote-pi-credential-v1-salt", info="remote-pi-credential-v1-key\n"+JSON([mac_epk, phone_epk, id]))`
  → 32-byte key, encrypts with AES-256-GCM (random 12-byte nonce, the
  canonical request as associated data, tag appended), and signs
  `"remote-pi-credential-response-v1\n" + JSON([sha256(canonical_request), id, phone_key, mac_epk, phone_epk, nonce, ciphertext])`
  with its Owner key.
- Mac accepts only when: the response arrives on the active channel of a phone
  that is still durably paired, `phone_key` equals that channel identity, the
  request is the single pending one for the current session generation and not
  expired, the signature verifies, and decryption with the request's AAD
  succeeds. Plaintext must be 1 byte to 16 KiB. The same checks run again after
  decryption, before the file write, and once more after the write (owner
  still paired and on this channel, request still pending/unexpired, session
  unchanged); on any lapse the file is deleted and the response refused. The
  tool promise resolves only after that. Replays, altered requests, foreign phones, tampered ciphertext /
  nonce / keys and late responses are refused without touching the file system.

A captured or altered relay payload cannot inject a value (no Owner signature,
wrong AAD) or decrypt one (no Mac ephemeral secret). No response is ever
treated as an outgoing-send approval.

## Transcript hygiene

While a supplied value is live (until its file TTL), the `tool_result` hook
redacts `content` text parts and, independently, every decoded string inside
`details` (recursively; detail-only leaks are caught even when the text is
clean), and the live `tool_execution_end` broadcast is redacted too. Matching
is the exact supplied bytes (never trimmed into a different secret) plus the
form without trailing newlines that `$(cat file)` yields; values of 4+ chars
including six-digit OTPs are covered. Tool arguments are never mutated and no
hook is bypassed.

## Limits (stated honestly)

- Redaction is best effort for accidental leaks only. Arbitrary malicious local
  code or encoded exfiltration of the file is not a supported boundary: anyone
  running as the Mac user can read the file during its TTL.
- File-backed use covers CLI/API credentials. Browser password fills are not
  solved by this path.
- The phone keeps plaintext only in widget memory until submit, cancel, app
  background or dispose (a clipboard read that completes after a background
  wipe is dropped); iOS AutoFill/keyboard behaviour is the platform's.
- Every app-side async step is bound to the Mac key, room and channel it
  started with. A submit whose relay ACK is lost shows an unconfirmed state
  after 25 s; the user can cancel at any time and nothing is resent
  automatically (the Mac may still have received it; it never re-runs).
- Transfer ACK ≠ provider validation.
