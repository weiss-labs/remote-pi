# Private linked artifact previews

The paired phone requests an on-demand preview from its selected pane. This is a viewing capability only. It does not authorize a send, attest that an attachment was reviewed, upload to a public service, prompt a model, run a shell command, or fetch HTTP content.

## Authorization and source authority

Every open, chunk and close requires the exact currently attached channel plus a durable paired-owner lookup, using the same checks as native commands. A body-supplied peer, path, room or owner has no authority. Replies go only to the requesting channel, never the broadcast timeline.

Only an exact `file://` URL present in an assistant text block on the current SDK `ctx.sessionManager.getBranch()` ancestry is eligible. User messages, tool results, thinking, custom messages, summaries and inactive branches do not grant access. Missing authoritative SDK history fails closed. The extension does not fall back to its replay buffer or caller-supplied history. Links must be URL-encoded where necessary; ambiguous Markdown punctuation is not guessed.

Paths must resolve under the canonical real paths of `~/Documents/programs`, `~/Downloads`, OS `tmpdir()` or `/tmp`. Both original and resolved paths reject hidden segments, credential/config/git/env/key locations and common secret basenames regardless of suffix. Remote URL hosts, query strings and fragments are rejected. Root escapes, hidden symlink destinations and multiply-linked files are rejected. Symlinks only qualify when the canonical target also meets every check.

The source must be a regular single-linked file of at most 20 MiB with a matching PDF, PNG, JPEG, GIF or WebP extension and signature. Signature validation is not a malware scan or a promise that a structurally signed image/PDF is benign. SVG, HTML, executable content and other file types are not supported.

The extension opens a pinned read-only no-follow/nonblocking descriptor, checks inode/device/size/mtime/ctime and canonical path agreement, hashes bounded chunks, then rechecks pairing, active branch and session generation. Every chunk verifies the same pinned descriptor and source stamp before and after reading. A detected mutation, replacement, cancellation, expiry, revoked owner or session switch fails without returning bytes. The phone must independently verify total size and final SHA-256 before native preview.

## Wire contract

Requests and replies are ordinary private inner room messages. All requests have unique bounded ASCII `id` values.

```typescript
{ type: 'artifact_open', id, url }
{ type: 'artifact_opened', in_reply_to: id, transfer_id,
  name, mime, size, sha256 } // lowercase SHA-256 hex
{ type: 'artifact_chunk', id, transfer_id, offset }
{ type: 'artifact_chunk', in_reply_to: id, transfer_id,
  offset, data, eof } // standard base64, at most 192 KiB decoded
{ type: 'artifact_close', id, transfer_id }
{ type: 'artifact_error', in_reply_to: id,
  code: 'unavailable', message: 'fixed safe message' }
```

Successful close has no reply. Close is cancellation, not a chat action. Invalid offsets or changed sources invalidate the transfer. All failures use bounded fixed errors, without raw paths, operating-system messages or content. Neither bytes nor URLs are logged or persisted by this subsystem.

Handles expire after 120 seconds without extending on reads. There are at most four handles per owner, 32 globally, two pending requests per owner and 16 globally. Each handle permits only one read at a time. A stale channel cannot adopt another channel's transfer. Owner detach, relay loss/stop, session start/tree change/shutdown close affected handles and invalidate pending work. In-flight opening descriptors close in their bounded cancellation path.

## Verification and rollout

`src/artifacts.test.ts` uses only newly created temporary files and an in-memory real SDK session tree. It covers positive PDF/hash/chunks, image signatures, user/tool/nonlinked/inactive-branch denial, URL/path/root/hidden/secret/MIME/size negatives, symlink/hardlink escape, owner/channel/revocation boundaries, offsets, change detection, handle/in-flight limits, expiry, cancellation and session invalidation. No user files or real APNs are used for preview tests.

The extension and relay worker does not deploy or reload. Main owns integration with the phone, the focused review and authorized release. Native iOS preview/cache lifetime and real-device proof remain app/release responsibilities.
