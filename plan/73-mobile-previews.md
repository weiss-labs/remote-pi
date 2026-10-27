# 73 — Mobile draft/attachment previews and input-question alerts

User approved 2026-10-27 after testing build13. Regular dictation remains Apple's SYSTEM recognition; no cloud transcription provider or new transcription charges.

## Requested changes

- Notification: actual pane name + a short actual question/action prompt, not just 'A pane needs your input'. Explicit private-preview preference; credentials remain generic.
- Font packaging: build13 is VALID, but Apple's email ITMS-91182 warns about SF-Mono Light/Regular/Medium/Bold OTF copies. Remove all bundled Apple font bytes and use OS font references, preserve monospace appearance. Do not download/extract font data at runtime as a workaround.
- Mobile drafts: render recognized Unicode email/message preview panels as wrapping cards instead of horizontally clipped desktop code blocks. Original cached message and approval text stay unchanged. Ambiguous panels fall back to wrapped text, never inferred headers/content.
- Attachments: file:// links refer to Mac paths, not phone paths. Retrieve assistant-linked PDF/image artifacts through the authenticated paired-pane channel and preview locally with native Quick Look. Images already in phone messages should also open/zoom.

## Security/compatibility boundary

- Artifact access is not a general filesystem API: authoritative assistant-linked URL on current active session branch; paired owner; validated regular file + realpath/allowed roots + forbidden secret/hidden locations + type signature; bounded snapshot/chunks, source-bound replies and lifecycle cleanup. Unsupported files fail honestly. No public document upload or external preview service.
- Explicit question previews use a backwards-compatible v2 bilateral grant. v1 is unchanged and never opts into question text. v2 canonical array is peer,phone,device_id,token,environment,categories,show_pane_name,show_question_preview,expires_at under remote-pi-notify-device-v2 newline domain. Fresh flag OFF until user opts in; requires names too. SQLite migration default0; queue rechecks current consent. Prompt content stays memory-only and out of logs/DB.
- Questions only from explicit notify_user(question) or actual structured UI questions. Credential-needed always generic; no raw outputs/tool args/approval bodies. Sanitization is conservative best effort, not proof no arbitrary secret could appear.
- Viewing a file or a mobile draft never sends/approves any outbound message.

## Ownership and delivery

- mobile-preview-app worktree: Astra, app/** only (cards, native viewer, bounded artifact client, fonts, preview preferences).
- mobile-preview-backend worktree: Sol, pi-extension/** + relay/** only (file authorization/transfer, question event + grant v2).
- Main: root scripts/audit-ios-fonts.py, integration, focused read-only review, staged relay + extension, signed IPA audit, TestFlight14. No installation/deployment by workers. Close them only after saved result is read/acknowledged.
- Font regression guard scans actual IPA/App font names (not Apple's validator). Existing build13 audit correctly fails with four SFMono files. Mac FontValidator is3.0.2, too old for TN3214's3.5 -appleFonts procedure; don't claim that check ran.

Acceptance: read complete draft on320/390/440 widths without horizontal clipping; tap linked PDFs/images opens native preview; wrong owner/session/unlinked/secret/symlink/oversize/stale transfers rejected; old clients retain private generic alerts; opt-out cancels queued preview; no Apple font files in final shipped IPA; system mic untouched. Physical device preview/push behavior still requires actual user testing after release.
