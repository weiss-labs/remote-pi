import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

// This is a registered Pi command, not a fabricated host executeCommand API.
const NATIVE_GATE = "remote-pi-native-dispatch";
const NAME = /^[A-Za-z0-9][A-Za-z0-9:_.-]*(?: [A-Za-z0-9][A-Za-z0-9:_.-]*)*$/;
const ID = /^[A-Za-z0-9._-]{1,128}$/;
export type CommandClientMessage =
  | { type: "list_commands"; id: string }
  | { type: "command_execute"; id: string; name: string; args?: string };
export type CommandSource = "extension" | "prompt" | "skill" | "builtin" | "alias";
export interface WireCommand {
  name: string; description: string; source: CommandSource;
  available: boolean; reason?: string; busy_policy: "immediate" | "follow_up" | "idle_only";
}
export type CommandServerMessage =
  | { type: "commands_list"; in_reply_to: string; commands: WireCommand[]; dispatch_supported: boolean }
  | { type: "command_result"; in_reply_to: string; name: string; status: "accepted" | "rejected"; code?: string; message: string };
export interface CommandSender { send(message: CommandServerMessage): void }
interface Dependencies {
  busy(): boolean;
  provider(): string | undefined;
  /** Real paired identity and exact attached channel, rechecked immediately before dispatch. */
  authorize(phone: string, sender: CommandSender): Promise<boolean>;
  promptSubmitted?(id: string, text: string): void;
}
interface Pending {
  phone: string; sender: CommandSender; message: CommandClientMessage;
  generation: number; timer: ReturnType<typeof setTimeout>; replied?: boolean; entered?: boolean;
}
interface CatalogCommand extends WireCommand { target: string }
interface Cached { reply: CommandServerMessage; expires: number }

export class NativeCommands {
  private pending = new Map<string, Pending>();
  private completed = new Map<string, Cached>();
  private inFlight = new Set<string>();
  private supported: boolean | null = null;
  private live = true;
  private generation = 0;
  constructor(private readonly pi: ExtensionAPI, private readonly deps: Dependencies) {
    pi.registerCommand(NATIVE_GATE, {
      description: "Internal paired-phone native command dispatch (not for manual use)",
      handler: (nonce, ctx) => this.enter(nonce, ctx),
    });
    // Pi 0.79.10 hardcodes expandPromptTemplates:false in sendUserMessage.
    // If a host ignores the supported modern option, consume the private gate
    // before model/auth/queue processing. Never send a slash literal as fallback.
    pi.on("input", (event) => {
      if (event.text === `/${NATIVE_GATE}` || event.text.startsWith(`/${NATIVE_GATE} `)) {
        this.supported = false;
        const nonce = event.text.slice(NATIVE_GATE.length + 2);
        const pending = this.take(nonce);
        if (pending) {
          try { this.unsupported(pending); }
          catch { try { this.result(pending, "sdk_unavailable", "Native command catalog is unavailable."); } catch { /* A detached channel cannot make this become model input. */ } }
        }
        return { action: "handled" };
      }
      return undefined;
    });
  }
  resume(): void { this.live = true; this.supported = null; }
  stop(): void {
    this.live = false; this.generation++;
    for (const nonce of [...this.pending.keys()]) {
      const pending = this.take(nonce);
      if (pending) this.result(pending, "session_changed", "Session changed before command dispatch. Refresh the command list.");
    }
    this.completed.clear(); this.inFlight.clear();
  }
  private key(phone: string, id: string): string { return `${phone}:${id}`; }
  private take(nonce: string): Pending | undefined {
    const pending = this.pending.get(nonce);
    if (pending) { clearTimeout(pending.timer); this.pending.delete(nonce); }
    return pending;
  }
  private reply(p: Pending, reply: CommandServerMessage): void {
    p.replied = true;
    const key = this.key(p.phone, p.message.id);
    this.inFlight.delete(key);
    if (p.message.type === "command_execute") {
      this.completed.set(key, { reply, expires: Date.now() + 600000 });
      while (this.completed.size > 128) this.completed.delete(this.completed.keys().next().value!);
    }
    p.sender.send(reply);
  }
  private result(p: Pending, code: string, message: string): void {
    this.reply(p, { type: "command_result", in_reply_to: p.message.id, name: p.message.type === "command_execute" ? p.message.name : "", status: "rejected", code, message });
  }
  private catalog(): CatalogCommand[] {
    const result: CatalogCommand[] = [];
    const seen = new Set<string>();
    for (const command of this.pi.getCommands().slice(0, 512)) {
      if (command.name === NATIVE_GATE || !NAME.test(command.name) || command.name.length > 128 || seen.has(command.name)) continue;
      if (!["extension", "prompt", "skill"].includes(command.source)) continue;
      seen.add(command.name);
      const description = (command.description ?? "No description provided by this pane").replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 512);
      result.push({ name: command.name, target: command.name, description, source: command.source, available: this.supported === true, busy_policy: command.source === "extension" ? "immediate" : "follow_up" });
    }
    // Built-in TUI /reload is not part of getCommands/prompt dispatch. This
    // bridge uses the public SDK command-context reload(), not a literal prompt.
    if (!seen.has("reload")) result.push({ name: "reload", target: NATIVE_GATE, description: "Reload this pane's resources using native Pi command context (idle only)", source: "builtin", available: this.supported === true, busy_policy: "idle_only" });
    if (!seen.has("fast")) {
      const provider = this.deps.provider();
      const target = provider === "claude-bridge" ? "claude-fast" : provider?.startsWith("openai-codex") ? "codex-fast" : undefined;
      const actual = result.find(c => c.name === target && c.source === "extension");
      result.push({ name: "fast", target: actual?.name ?? "", description: actual ? `Use the current provider's /${actual.name}. ${actual.description}` : "No native fast command is registered for this pane's current provider", source: "alias", available: this.supported === true && !!actual, ...(!actual ? { reason: "provider_command_unavailable" } : {}), busy_policy: "immediate" });
    }
    if (!seen.has("checkpoint")) {
      const actual = result.find(c => c.name === "skill:checkpointing-project-state" && c.source === "skill");
      result.push({ name: "checkpoint", target: actual?.name ?? "", description: actual ? actual.description : "Checkpoint skill is not loaded in this pane", source: "alias", available: this.supported === true && !!actual, ...(!actual ? { reason: "skill_unavailable" } : {}), busy_policy: "follow_up" });
    }
    if (this.supported !== true) for (const c of result) { c.available = false; c.reason = "sdk_dispatch_unsupported"; }
    else if (this.deps.busy()) for (const c of result) if (c.busy_policy === "idle_only") { c.available = false; c.reason = "busy"; }
    return result.sort((a,b) => a.name.localeCompare(b.name));
  }
  private list(p: Pending): void {
    this.reply(p, { type: "commands_list", in_reply_to: p.message.id, dispatch_supported: this.supported === true, commands: this.catalog().map(({target: _target, ...wire}) => wire) });
  }
  private unsupported(p: Pending): void {
    if (p.message.type === "list_commands") this.list(p);
    else this.result(p, "sdk_dispatch_unsupported", "This Pi host lacks native extension command dispatch. Upgrade the host; no literal chat fallback was sent.");
  }
  private sendExpanded(text: string, followUp = false): void {
    // This documented option is present on the actual installed Pi 1.4.0.
    // A variable keeps compatibility with the older dev SDK's structural type;
    // the private gate round-trip above verifies real host behavior, not a version guess.
    const options = { expandPromptTemplates: true, deliverAs: followUp ? "followUp" as const : undefined };
    this.pi.sendUserMessage(text, options);
  }
  async handle(phone: string, sender: CommandSender, message: CommandClientMessage): Promise<void> {
    if (typeof message.id !== "string" || !ID.test(message.id)) return;
    const key = this.key(phone, message.id);
    for (const [k, v] of this.completed) if (v.expires <= Date.now()) this.completed.delete(k);
    const fail = (code: string, text: string) => sender.send({
      type: "command_result", in_reply_to: message.id,
      name: message.type === "command_execute" && typeof message.name === "string" ? message.name.slice(0, 128) : "",
      status: "rejected", code, message: text,
    });
    if (!this.live) { fail("not_paired", "An active paired pane connection is required."); return; }
    if (message.type === "command_execute" && (typeof message.name !== "string" || message.name.length > 128 || !NAME.test(message.name) || (message.args !== undefined && (typeof message.args !== "string" || message.args.length > 8192 || /[\x00-\x1f\x7f]/.test(message.args))))) {
      fail("invalid_command", "Select one command and use single-line arguments."); return;
    }
    if (this.inFlight.size >= 16 || this.inFlight.has(key)) {
      fail("command_pending", "A matching command is pending or the native command queue is full."); return;
    }
    const nonce = randomUUID();
    const timer = setTimeout(() => {
      const p = this.take(nonce);
      if (p) this.result(p, "dispatch_timeout", "Native dispatch was not acknowledged. Refresh before trying again; do not automatically resend state-changing commands.");
    }, 12000);
    const p: Pending = { phone, sender, message, generation: this.generation, timer };
    this.pending.set(nonce, p); this.inFlight.add(key);
    try {
      const authorized = await this.deps.authorize(phone, sender);
      if (this.pending.get(nonce) !== p) return;
      if (!authorized || !this.live || p.generation !== this.generation) {
        this.take(nonce); this.result(p, "not_paired", "An active paired pane connection is required."); return;
      }
      const cached = this.completed.get(key);
      if (cached) { this.take(nonce); this.reply(p, cached.reply); return; }
      if (this.supported === false) { this.take(nonce); this.unsupported(p); return; }
      this.sendExpanded(`/${NATIVE_GATE} ${nonce}`);
    } catch {
      if (this.take(nonce)) this.result(p, "sdk_unavailable", "Native command dispatch is unavailable in the current session.");
    }
  }
  private async enter(nonce: string, ctx: ExtensionCommandContext): Promise<void> {
    const p = this.pending.get(nonce);
    if (!p || p.entered) return;
    p.entered = true;
    try {
      const authorized = await this.deps.authorize(p.phone, p.sender);
      // Timeout/replacement may settle the request during asynchronous pairing IO.
      if (this.pending.get(nonce) !== p) return;
      this.take(nonce);
      if (!this.live || p.generation !== this.generation || !authorized) {
        this.result(p, "not_paired", "Pairing or session changed before dispatch."); return;
      }
      this.supported = true;
      if (p.message.type === "list_commands") { this.list(p); return; }
      const message = p.message;
      const command = this.catalog().find(c => c.name === message.name);
      if (!command?.available || !command.target) {
        this.result(p, command?.reason ?? "unknown_command", command?.reason === "busy"
          ? "Wait for this pane's work, queued messages and compaction to finish before reloading."
          : "That command is not currently available in this pane. Refresh the list.");
        return;
      }
      const busy = this.deps.busy() || !ctx.isIdle() || ctx.hasPendingMessages();
      if (command.busy_policy === "idle_only" && busy) {
        this.result(p, "busy", "Wait for this pane's work, queued messages and compaction to finish before reloading."); return;
      }
      if (command.source === "builtin" && command.name === "reload") {
        if (message.args?.trim()) { this.result(p, "invalid_arguments", "Native reload takes no arguments."); return; }
        this.reply(p, { type: "command_result", in_reply_to: message.id, name: message.name, status: "accepted", message: "Native reload accepted. This pane will reconnect; acceptance is not completion." });
        // Never reuse ctx or pi after await reload: the old SDK runtime is stale.
        await ctx.reload();
        return;
      }
      const raw = `/${command.target}${message.args ? ` ${message.args}` : ""}`;
      this.sendExpanded(raw, busy && command.busy_policy === "follow_up");
      if (!busy && command.busy_policy === "follow_up") this.deps.promptSubmitted?.(message.id, raw);
      this.reply(p, { type: "command_result", in_reply_to: message.id, name: message.name, status: "accepted", message: "Submitted to native Pi command dispatch. Completion, errors and any UI prompts are separate; no approval was bypassed." });
    } catch (error) {
      this.take(nonce);
      if (!p.replied) this.result(p, "sdk_unavailable", "Native command context or catalog is unavailable.");
      else throw error; // Preserve normal SDK error reporting after acceptance.
    }
  }
}
