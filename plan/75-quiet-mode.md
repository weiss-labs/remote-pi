# Plan 75: quiet mode in the phone app

Status: planned only. Build after the Pi TUI quiet mode ships (source of truth:
Zach OS worker w1:p4Z, `~/.local/state/pi-quiet-mode/`; it will write a short
spec of labels and grouping rules). Release needs Zach's "ship it" (fleet #99).

## Behaviour (same as Pi TUI)
- One animated plain-English status line while the agent works.
- Turn ends with just the reply; its steps fold into one "Worked for Xm, N steps"
  row that expands. Tapping a step opens a preview sheet (command, output, image).
- A failed step is one plain-English line. A message from another pane is one
  line ("Message from William / FB Ads").
- Always shown in full: approvals, drafts, blocked sends, credential requests,
  extension UI questions.

## Where it goes
- Rendering: `app/lib/ui/chat/chat_page.dart` message list (`ListView` over
  `UserMsg / AssistantMsg / ToolEvent / CompactionMsg`, ~line 770). Quiet mode
  is a pure view transform: group consecutive `ToolEvent`s between a user turn
  and the reply into one folded row. The cached transcript is never changed.
- Existing precursor: `Preferences.hideToolCalls` (Settings toggle, filtered at
  chat_page.dart ~line 488). Replace it with `quietMode`, default ON, migrating
  an explicit hideToolCalls=false to quiet OFF.
- Toggle: a visible switch in the chat top bar / quick actions (one tap to full
  output) plus the Settings row.
- Setting scope: one global app setting, phone-local, not synced to the Mac and
  not per pane (start simple; per-pane only if Zach asks).
- Status line: derived on the phone from the live tool events the app already
  receives, using the Pi spec's labels; no new wire messages unless the Pi
  version adds a summary event worth reusing.
