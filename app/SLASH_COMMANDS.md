# Paired pane commands

Typing `/` in the chat composer requests the active paired pane's live command catalogue. Prefix filtering shows names, descriptions, availability and busy policy. Tapping a suggestion inserts it; it does not execute. Tap Run or the send button (hardware Enter also works) to explicitly dispatch the chosen command. Optional arguments are single-line and limited to 8192 characters. Multiword command names use the longest exact advertised name.

Slash text is never sent as an ordinary user message. Missing command support, an unknown command, disabled command, offline connection, error or timeout retains the draft and displays a reason. There is no native key injection, shell fallback, speculative local command catalogue or automatic command retry.

## Wire contract

The app uses ordinary authenticated paired-room messages:

```
list_commands {id}
commands_list {in_reply_to, dispatch_supported, commands:[
  {name, description, source, available, reason?, busy_policy}
]}
command_execute {id, name, args}
command_result {in_reply_to, name, status:'accepted'|'rejected', code?, message?}
```

`source` is extension, prompt, skill, builtin or alias. `busy_policy` is immediate, follow_up or idle_only. The app mirrors live SDK descriptors and does not invent provider aliases or built-in capabilities. The backend owns actual execution and busy-state validation.

Requests and the cached catalogue are bound to channel, paired peer and room. Switching any of these invalidates pending work and cached descriptors. Older list responses cannot replace a newer catalogue. Execute replies must correlate both request ID and command name. Discovery errors use `command_result` with an empty name. Socket write success is never dispatch acceptance.

The UI displays `Dispatching` while awaiting acknowledgement and `Accepted by pane. Watch the conversation for results.` only after accepted status. Acceptance is not completion; normal session events and UI prompts continue. On timeout the user is told to inspect the pane before retrying because dispatch may already have happened. This app does not auto-resend state-changing commands.

Backend support requires a Pi runtime with its verified native command-dispatch path. Old SDK hosts fail closed and advertise unavailable commands. Not every desktop-only TUI slash command is necessarily exposed by the live catalogue. The app does not treat a slash string as model input when native dispatch is unavailable.

## Credential-needed instructions

A valid `credential_needed` notification tap opens a read-only `Desktop authorization required` dialog after routing to the known paired room (or safe Home fallback). It points to the requesting pane's notice for the exact approval, and explains that remote integrations should use scoped unattended credentials configured on the Mac. It explicitly states that this app does not transfer passwords or approve desktop Touch ID, phone 1Password unlock does not unlock the Mac, and the notice alone does not unblock the task. Interactive authorization still requires the affected Mac. The dialog has no secret input or transmission controls; passwords/API keys/recovery codes must not be pasted into chat. Backend's fixed safe instruction appears in the pane conversation; arbitrary chat/tool output is not copied into the dialog.

The backend can also send its fixed instructions as `error{code:'credential_needed'}` while the pane is open. This app shows that advisory warning without discarding an active stream or changing the working state; only the normal agent lifecycle ends the turn.

This is actionable guidance for the credential-needed event. It is not automatic detection of arbitrary operating-system prompts and it does not implement secure credential transfer.

## Local checks

```
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
flutter test --no-pub test/data/pane_commands_repository_test.dart test/ui/chat/commands_viewmodel_test.dart test/ui/chat/commands_input_test.dart test/ui/chat/credential_needed_dialog_test.dart
flutter build ios --no-codesign --no-pub
```

Tests use fake paired channels and repositories, not live command execution. Main owns combined backend/app review and a real paired-pane smoke test. No deployment, TestFlight upload or real slash command is executed by this worker.
