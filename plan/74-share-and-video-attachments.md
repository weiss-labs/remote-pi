# Plan 74: iPhone video, clipboard and Share-sheet attachments

Status: implemented on branch `share-video` (app + pi-extension; no relay change).
Not shipped. Release approval is separate. Design and signing notes in
`app/ATTACHMENTS.md`; wire in `PROTOCOL.md` ("Arquivos do celular pro Mac").
Decided: video from library AND in-app recording; Share sends immediately,
no caption step. App Group `group.ai.weisslabs.remotepi` exists on both bundle IDs (2026-10-28);
profiles regenerated with `node scripts/ios-profiles.mjs`; signed archive +
TestFlight-style export proven locally (no upload).
Source: Zach voice request 2026-10-28 (relayed from the old remote_pi_app pane).
"Papaya" / "remove pay" in the dictation mean Remote Pi.

## Requirements
1. **Video attachments from the iPhone.** Pick a video and send it right away,
   including while the agent is working (same steer path as photos today).
2. **Paste real attachments.** Copied images, videos or files pasted into the
   composer become actual attachments in the thread, not just pasted text.
3. **iOS Share extension.** From Photos, Files, or the screenshot preview,
   choose Share → Remote Pi, pick the workspace/thread, and the item is sent
   there as an attachment without opening the thread first.

## Constraints
- Video and large files need a bounded, chunked transfer to a private local
  file on the Mac (like artifact_chunk, in the other direction). Do not stuff
  them into the existing small inline image JSON frames.
- The model gets an honest handoff: a file path plus type/size/duration. Don't
  claim the model natively watches video; frame extraction or transcription
  is a separate, explicit step.
- A copied URL is not file bytes. Only real pasteboard file/image/video data
  becomes an attachment.
- Size caps, cancel, and stale-room protection the same way as artifact
  previews: bound to peer/room at tap, never re-routed.

## Open questions (ask only if they block)
- Video: library picker only, or also record in-app?
- Share extension: send immediately after picking the thread, or allow an
  optional caption first?
