# Video, pasted and shared attachments (plan 74)

Photos keep the plan/30 path: compressed on the phone and sent inline so the
model sees them natively. Everything else (videos, pasted videos/files, items
from the iOS Share sheet) is a **chunked upload to a private file on the Mac**
and reaches the pane as an ordinary user message that names the local path,
file name, type, size and duration. No claim is made that a model watched the
video; reading, frame extraction or transcription is the agent's explicit step.

## Composer

- Attach sheet: Camera, Photo Library, **Record Video**, **Video Library**,
  **Paste from Clipboard**. Videos come from `image_picker`'s `pickVideo`
  (the system picker, no library permission) and are not re-encoded.
- Files show as a chip (icon, name, size, X). Images still show thumbnails.
  Images and files can be mixed; on send, the inline-image message (with the
  caption) goes first, then each file as its own upload. A send is valid with
  only files attached. Commands (`/…`) refuse while anything is attached.
- Paste: the native iOS edit menu keeps its Paste (copied photos already
  arrive through keyboard content insertion). A **Paste File** item and the
  sheet's **Paste from Clipboard** read real pasteboard items through
  `ai.weisslabs.remotepi/pasteboard`: images become inline images, movies and
  files become chips. Plain text and URLs are never turned into attachments;
  with nothing attachable the composer says so and the text paste stands.
- Sending while the pane is working uses the existing steer path (the Mac
  also infers steer from its own `working` flag).
- One upload at a time. A strip above the composer shows name, percent and a
  cancel button. Cancel, a pane switch, a closed channel or a Mac refusal
  fail the upload with a snackbar; nothing is re-routed to another pane.

## Transfer (`file_*`, phone → Mac)

The mirror of `artifact_*`. Client types live in `protocol.dart` as
`FileRequest`/`FileReply`; the Mac side is `pi-extension/src/attachments.ts`.

1. The phone hashes the whole file (SHA-256, streamed) and sends
   `file_open {id,name,mime,size,sha256,duration_ms?,text?,streaming_behavior?}`.
   The Mac checks size (≤ 200 MiB), checksum shape, MIME shape, one transfer
   per owner (four total), creates `~/.pi/remote/attachments/<uuid>.part`
   with mode 0600 inside a 0700 directory, and replies
   `file_opened {transfer_id}`.
2. `file_chunk {transfer_id, offset, data}` (base64, ≤ 192 KiB raw) must be
   strictly sequential; the Mac appends, updates the running hash and replies
   `file_ack {offset}` with the next expected offset. Any other offset, an
   oversized chunk, a foreign sender/owner, a session change or ten idle
   minutes drops the transfer and deletes the partial file.
3. `file_close {id = message id}` requires the full size and a matching
   hash, renames the file to `<8 hex>-<safe name>`, then hands the path to the
   pane: `_wakeAgent` with the caption plus the attachment note, echoed to
   every owner as a `user_message` with that id. Reply `file_done {path}`.
   If the agent cannot be woken the file is deleted and `file_error` is sent.
4. `file_cancel` deletes the partial file.

The app captures channel, peer and room when the send starts and re-checks
them before every frame (`FileTransferRepository`). `requiresSourceRoom`
covers `file_*`, so each frame carries its source room like artifacts.
Finished files are swept after 24 h; abandoned `.part` files after 10 min.
Names are stripped of separators, control characters and leading dots.

## Share extension (iOS)

`ShareExtension` target, bundle `ai.weisslabs.remotepi.share`, App Group
`group.ai.weisslabs.remotepi`. It accepts images, movies and files (up to
ten). The picker lists panes from `panes.json` in the App Group container,
which `HomeViewModel` republishes on every Home update: pinned first, then
workspaces in the dragged order, panes by recency, with the same tab and pane
names Home shows (numeric Herdr tabs skipped). Open Remote Pi once after
install so the list exists.

Picking a pane copies each item into `inbox/<uuid>/<name>` and writes
`inbox/<uuid>.json` bound to that peer/room. The extension then asks iOS to
open `remotepi://share` (best-effort responder-chain `openURL:`; there is no
public API for an extension to launch its app) and shows "Queued for
<workspace › tab › pane>". The app drains the queue on every foreground,
including cold start: it selects and opens that pane, waits up to 20 s for it
to be live, uploads with the same transfer, deletes the entry, and shows a
snackbar with the outcome. An unpaired Mac, an offline pane or a refused
upload drops the entry with its reason; it is never sent elsewhere. Entries
older than seven days are discarded. If the app does not open automatically
the item simply sends the next time Remote Pi is opened; the extension's
message says so. No caption step by design.

## Signing

`Runner.entitlements` and `ShareExtension.entitlements` both declare the App
Group. Release/Profile sign manually with "Remote Pi WL Share Direct Push";
`ExportOptions.testflight.plist` maps the extension to "Remote Pi WL Share
App Store Push" and `ship-testflight.sh` refuses an IPA without the appex.
`scripts/ios-profiles.mjs` recreates and installs all four profiles after a
capability change. The App Group itself had to be created and attached to both
bundle IDs outside this API (done 2026-10-28 via fastlane spaceship): the
public App Store Connect API has no App Groups resource and Xcode's
provisioning service does not accept the team API key. `ios/add_share_extension.rb` is the idempotent project edit that added
the target (requires the xcodeproj gem bundled with CocoaPods).

## Not covered

Android has no pasteboard/share bridge (the Dart side degrades to "nothing to
paste" and an empty share queue). Video thumbnails are not generated on the
phone. The Mac does not transcode or inspect the file beyond size and hash.
