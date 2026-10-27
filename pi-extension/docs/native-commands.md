# Paired-pane native commands

## The SDK seam is verified, not invented

The inspected globally installed Pi package is 1.4.0. Its public `ExtensionAPI.getCommands()` lists live extension commands, prompt templates and skills with descriptions. Its documented `sendUserMessage(text, {expandPromptTemplates:true})` enters `AgentSession.prompt()`'s genuine command dispatcher and skill/template expansion. This is not the ordinary literal-chat path. The checked development SDK is 0.79.10, whose sendUserMessage implementation hardcodes expansion false; silently using that older API would send a slash literal to the model.

There is no public generic executeCommand or host AgentSession accessor in the inspected ExtensionAPI. The extension therefore registers a reserved `remote-pi-native-dispatch` command. A paired request first invokes that command with a random private nonce and expansion enabled. On a capable host, the real native dispatcher supplies a fresh command-capable context. Only that verified callback can dispatch a selected current command. On an older host, a public input handler consumes the private probe before model/auth/queue processing and reports unsupported. No raw command is sent as fallback. This behavior is tested against both actual installed SDK versions in isolated model-free sessions, not only a fake API.

This does not claim every already-running pane uses the on-disk 1.4 package. The per-pane native round-trip is authoritative. A host without this seam remains honestly disabled until the host is updated through an authorized rollout.

## The live catalog is bounded

The remote catalog comes from the current runtime on each request, not a disk scan, static advertised wish list or another pane. Resource paths/sourceInfo are excluded. Up to 512 native entries are exposed, with bounded names/descriptions. Supported names use ASCII letters/numbers, colon, dot, underscore, hyphen and separate command-name words. Unsupported names are omitted rather than converted into shell input.

TUI-only built-ins are not part of getCommands and do not run through prompt. They are not advertised as remotely executable. The one explicit adaptation is reload: it invokes the public SDK-supplied command context's reload(), which the real interactive host binds to its normal reload handler. It is rejected while busy, compacting or holding queued messages. Accepted is sent before reload invalidates the old context; old ctx/pi are never reused afterward. A reconnect proves availability, not necessarily successful completion of every reload hook.

The `/fast` convenience alias resolves only to an actual live extension command for the current provider (`claude-fast` for claude-bridge, `codex-fast` for openai-codex-family providers), unless a real `/fast` already exists. No provider flags, model choice or service tier are fabricated. The inspected local extensions have claude-fast; no Codex fast command was found. On such a Codex pane, fast is honestly unavailable until a genuine host/provider command is registered. Other native loaded commands remain available by their real names.

`/checkpoint` resolves only to the real loaded `skill:checkpointing-project-state`, unless a native checkpoint command already exists. The exact skill and prompt-template commands also appear in the catalog with their live descriptions. Skill/template dispatch requests a normal follow-up when busy, never silent steering or an abort. Native extension commands retain native immediate-during-streaming semantics and their own checks/UI.

## The app protocol uses explicit execution

All messages are ordinary inner messages to one attached paired phone's chosen Pi room. The sender is recovered from the exact attached channel and rechecked against durable pairing before dispatch. No body-supplied peer/pane selects authority.

```typescript
// Phone to paired Pi
{ type: 'list_commands', id }
{ type: 'command_execute', id, name, args?: string }

// Paired Pi to phone
{ type: 'commands_list', in_reply_to: id, dispatch_supported: boolean,
  commands: [{ name, description,
    source: 'extension' | 'prompt' | 'skill' | 'builtin' | 'alias',
    available: boolean, reason?: string,
    busy_policy: 'immediate' | 'follow_up' | 'idle_only' }] }
{ type: 'command_result', in_reply_to: id, name,
  status: 'accepted' | 'rejected', code?: string, message: string }
```

When dispatch_supported is false, every command is unavailable with sdk_dispatch_unsupported. Reasons also include busy, provider_command_unavailable and skill_unavailable. Unknown/missing native commands are rejected, not sent to chat. Arguments are optional, single-line, at most 8192 characters and contain no control characters. The bridge never sends a shell command, terminal keypress, browser action or Herdr pane input.

Request ids are bounded single ASCII identifiers and must be unique per command attempt. A pending limit of 16 and a 12-second gate timeout bound work. Accepted/rejected execution replies are cached for 10 minutes, up to 128 per bridge, to prevent a replay from toggling fast or repeating another action. Session replacement clears authority and pending work. A timeout is an unknown dispatch outcome, not permission to retry automatically. The app invalidates pending requests when the exact peer/room/channel changes and must not resend state-changing commands automatically.

The SDK extension API is fire-and-forget. An accepted reply means submission to native dispatch, not command completion or successful provider work. Native errors, permission dialogs, agent output and subsequent disconnect/reconnect still matter. Selecting an autocomplete suggestion only fills the composer; a separate explicit Run submits the command. No approval is synthesized. Commands preserve their original UI and permission checks, including dialogs that may still require the desktop in the current mode. No generic UI forwarding or phone desktop-unlock ability is claimed.

## Credential blockers have an explicit path and a narrow observer

`/credential-needed` takes no arguments or secrets. The existing agent `notify_user` tool's credential_needed category does the same generic signaling. Both show a fixed actionable notice on the affected pane and connected owners, and request the existing generic high-priority credential_needed push. The pane notice still appears if APNs is disabled. It tells the user to unlock/sign in to 1Password and approve on the affected Mac, retry the blocked step, and never paste passwords/tokens into chat. The phone cannot unlock desktop 1Password.

The public tool_result event exists in both inspected SDKs. A narrow automatic observer recognizes only a failed bash result for a simple direct op CLI invocation and an exact `[ERROR] authorization timeout` line, optionally with the known CLI timestamp prefix. This exact timeout is recorded in the canonical managing-secrets skill; installed op is 2.34.0. On a newer structured result an exit_code of zero is rejected. The observer reads at most 8 KiB across eight text blocks, returns no result transformation, stores no tool arguments/output and sends only fixed instructions plus the existing generic category. Notices and pushes are deduplicated.

Recognized executable forms are bare op and the standard /opt/homebrew/bin/op, /usr/local/bin/op and /usr/bin/op paths, optionally preceded by env, OP_ACCOUNT assignment or command. Supported op verbs are read, inject, item, document, vault, account, whoami and signin. Shell chains, pipes, redirections, substitutions, scripts, other executables, op run children, arbitrary output keywords and generic permission errors are not classified. This recognizes a narrow invocation/result shape, not cryptographic binary provenance or all shell syntax.

Generic native ui_prompt_start has no credential-specific type in the inspected SDK. It cannot honestly distinguish a 1Password prompt from another dialog. This observer cannot detect a still-pending desktop wait before op returns its actual error, most complex shell scripts, other sign-in mechanisms or every credential failure. Use the explicit command/tool in those cases. It never invokes op read/signin itself, intercepts a password, resolves secrets, opens 1Password, rewrites a tool command, changes permissions or approves anything. Secure password transport remains a separately gated main-owned feature.

## Verification remains local

`test/native_commands_sdk_smoke.ts` accepts an explicit SDK dist/index.js and expected supported/unsupported capability. It creates a private temporary SDK session with synthetic command handlers and a reload spy, not a real pane reload. Against installed 1.4.0 it observes one real native handler invocation and one SDK command-context reload spy call, with zero model conversation messages. Against 0.79.10 both operations are rejected and zero model messages are recorded. No credentials or external model/APNs calls are used.

Regression tests cover live catalogs, source privacy, genuine handler selection, old-host rejection, provider aliases, unavailable commands, busy reload, checkpoint follow-up, native UI confirmation preservation, request replay, pending bounds/timeouts, session invalidation, exact op timeout matches and security-negative shell/output cases. Main owns combined independent review, app integration, authorized host rollout and real-pane testing. This worker performed no deployment, live notification or live pane reload.
