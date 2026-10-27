import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ed25519Sign, ed25519Verify, type Ed25519Keypair } from "./pairing/crypto.js";
import type { RelayClient } from "./transport/relay_client.js";
import type { ExtensionUiRequestWire } from "./protocol/types.js";

export function questionForPrompt(msg: ExtensionUiRequestWire): string | undefined {
  if (msg.method === "notify") return undefined;
  // AskQuestionWire.prompt is the actual question. Do not use option previews,
  // answer fields, tool arguments, conversation history, or approval bodies.
  const question = msg.ask?.questions[0]?.prompt || msg.ask?.title ||
    (msg.method === "select" || msg.method === "confirm" ? msg.title : undefined);
  return sanitizeQuestion(question);
}

/** Best-effort refusal, not a guarantee that natural language contains no secrets. */
export function sanitizeQuestion(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 4096) return undefined;
  const clean = value.replace(/[\p{Cc}\p{Cf}]/gu, "").trim();
  if (!clean || /password|passphrase|credential|secret|token|otp|one[ -]?time|verification[ -]?code|api[ _-]?key|private[ _-]?key|sign[ -]?in|log[ -]?in|bearer|authorization|-----BEGIN|(?:sk|pk|ghp|github_pat|xox[baprs])[-_]|\d{4,}|[A-Za-z0-9_+/=-]{24,}/i.test(clean)) return undefined;
  return Array.from(clean).slice(0, 180).join("");
}
export function readablePaneName(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 4096) return undefined;
  const leaf = value.replace(/[\p{Cc}\p{Cf}]/gu, "").split(/[\\/@›]/).filter(Boolean).pop()?.trim();
  return leaf ? Array.from(leaf).slice(0, 64).join("") : undefined;
}

export const notificationCategories = ["input_needed", "credential_needed", "task_finished", "task_failed", "tests_failed", "review_ready", "update_available", "connection_lost"] as const;
export type NotificationCategory = typeof notificationCategories[number];
export type AgentNotificationCategory = Exclude<NotificationCategory, "update_available" | "connection_lost">;
export type NotificationClientMessage =
  | { type: "notify_register"; id: string; device_id: string; token: string; environment: "production" | "sandbox"; categories: NotificationCategory[]; show_pane_name: boolean; show_question_preview?: boolean; expires_at: number; signature: string }
  | { type: "notify_unregister"; id: string; device_id: string }
  | { type: "notify_presence"; id: string; device_id: string; foreground: boolean; room?: string | null };
export type NotificationReply = { type: "notification_registration"; in_reply_to: string; ok: boolean; error?: string };
export function grantBytes(peer: string, phone: string, m: Extract<NotificationClientMessage, { type: "notify_register" }>): Uint8Array {
  const v2 = Object.prototype.hasOwnProperty.call(m, "show_question_preview");
  return Buffer.from(`remote-pi-notify-device-v${v2 ? 2 : 1}\n` + JSON.stringify([peer, phone, m.device_id, m.token, m.environment, m.categories, m.show_pane_name, ...(v2 ? [m.show_question_preview] : []), m.expires_at]));
}
const pending = new WeakMap<RelayClient, number>();
/** Correlates only relay-native replies, never inner peer messages. No optimistic success. */
export function notificationControl(relay: RelayClient, frame: object): Promise<NotificationReply> {
  if (!relay.isOpen()) return Promise.resolve({ type: "notification_registration", in_reply_to: "", ok: false, error: "relay_unavailable" });
  const count = pending.get(relay) ?? 0;
  if (count >= 32) return Promise.resolve({ type: "notification_registration", in_reply_to: "", ok: false, error: "rate_limited" });
  pending.set(relay, count + 1);
  const id = randomUUID();
  return new Promise((resolve) => {
    let done = false;
    const finish = (reply: NotificationReply) => {
      if (done) return; done = true; clearTimeout(timer);
      relay.off("message", listener); relay.off("close", closed);
      pending.set(relay, Math.max(0, (pending.get(relay) ?? 1) - 1)); resolve(reply);
    };
    const listener = (line: string) => {
      try { const reply = JSON.parse(line) as NotificationReply;
        if (reply.type === "notification_registration" && reply.in_reply_to === id && typeof reply.ok === "boolean") finish(reply);
      } catch { /* Not a notification reply. */ }
    };
    const closed = () => finish({ type: "notification_registration", in_reply_to: id, ok: false, error: "relay_unavailable" });
    const timer = setTimeout(() => finish({ type: "notification_registration", in_reply_to: id, ok: false, error: "notification_timeout" }), 12000);
    relay.on("message", listener); relay.on("close", closed);
    try { relay.sendControl({ ...frame, id }); } catch { closed(); }
  });
}
interface Dependencies {
  relay(): RelayClient | null;
  identity(): Ed25519Keypair | null;
  room(): string | null;
  paneName?(): string | null;
  callActive?(): boolean;
  credentialNotice?(): void;
  /** Must recheck durable pairing, not just the relay key authentication. */
  paired(phone: string): Promise<boolean>;
}
export class NotificationBridge {
  private failed = false;
  private observedError = false;
  private waiting = false;
  private unresolvedPrompts = new Set<string>();
  private run = randomUUID();
  private active = false;
  private last = new Map<string, number>();
  constructor(private readonly deps: Dependencies) {}
  async handle(phone: string, msg: NotificationClientMessage): Promise<NotificationReply> {
    const fail = (error: string): NotificationReply => ({ type: "notification_registration", in_reply_to: msg.id, ok: false, error });
    if (typeof msg.id !== "string" || msg.id.length > 128 || !(await this.deps.paired(phone))) return fail("not_paired");
    const relay = this.deps.relay(), identity = this.deps.identity();
    if (!relay || !identity) return fail("relay_unavailable");
    if (typeof msg.device_id !== "string" || !/^[\x21-\x7e]{1,128}$/.test(msg.device_id)) return fail("invalid_device");
    let control: object;
    if (msg.type === "notify_register") {
      const peer = Buffer.from(identity.publicKey).toString("base64");
      const now = Math.floor(Date.now() / 1000);
      if (!/^[a-fA-F0-9]{64,200}$/.test(msg.token) || !["sandbox", "production"].includes(msg.environment) ||
          !Array.isArray(msg.categories) || msg.categories.length > notificationCategories.length || !msg.categories.every(c => notificationCategories.includes(c)) ||
          new Set(msg.categories).size !== msg.categories.length || typeof msg.show_pane_name !== "boolean" ||
          (Object.prototype.hasOwnProperty.call(msg, "show_question_preview") && typeof msg.show_question_preview !== "boolean") ||
          (msg.show_question_preview === true && !msg.show_pane_name) ||
          !Number.isSafeInteger(msg.expires_at) || msg.expires_at <= now || msg.expires_at > now + 30 * 86400 || typeof msg.signature !== "string") return fail("invalid_grant");
      const bytes = grantBytes(peer, phone, msg);
      try { if (!ed25519Verify(Buffer.from(phone, "base64"), bytes, Buffer.from(msg.signature, "base64"))) return fail("invalid_grant"); }
      catch { return fail("invalid_grant"); }
      // Authority comes only from the paired channel identity, never a body target.
      if (!(await this.deps.paired(phone)) || relay !== this.deps.relay()) return fail("not_paired");
      control = { type: "register_notification_device", grant: { peer, phone, device_id: msg.device_id, token: msg.token, environment: msg.environment, categories: msg.categories, show_pane_name: msg.show_pane_name, ...(Object.prototype.hasOwnProperty.call(msg, "show_question_preview") ? { show_question_preview: msg.show_question_preview } : {}), expires_at: msg.expires_at, signature: msg.signature, pi_signature: Buffer.from(ed25519Sign(identity.secretKey, bytes)).toString("base64") } };
    } else if (msg.type === "notify_unregister") control = { type: "unregister_notification_device", phone, device_id: msg.device_id };
    else {
      if (typeof msg.foreground !== "boolean") return fail("invalid_presence");
      control = { type: "notification_presence", phone, device_id: msg.device_id, foreground: msg.foreground };
    }
    const reply = await notificationControl(relay, control);
    return { ...reply, in_reply_to: msg.id };
  }
  async revoke(phone: string): Promise<NotificationReply | null> {
    const relay = this.deps.relay();
    return relay ? notificationControl(relay, { type: "revoke_notification_phone", phone }) : null;
  }
  private control(frame: object): Promise<NotificationReply> {
    const relay = this.deps.relay();
    return relay ? notificationControl(relay, frame) : Promise.resolve({ type: "notification_registration", in_reply_to: "", ok: false, error: "relay_unavailable" });
  }
  start(): void {
    this.unresolvedPrompts.clear();
    this.run = randomUUID(); this.failed = false; this.observedError = false; this.waiting = false; this.active = true;
    void this.control({ type: "notification_activity", active: true });
  }
  /** Only an actual structured short question may accompany an input wait. */
  promptOpened(id: string, question?: string): void {
    if (this.unresolvedPrompts.size < 64) this.unresolvedPrompts.add(id);
    else this.waiting = true; // Conservative bounded overflow: never claim all prompts resolved.
    void this.emit("input_needed", id, true, question);
  }
  promptResolved(id: string): void { this.unresolvedPrompts.delete(id); }
  async emit(kind: AgentNotificationCategory, eventId?: string, trackedPrompt = false, question?: string): Promise<NotificationReply> {
    if (!trackedPrompt && (kind === "input_needed" || kind === "credential_needed")) this.waiting = true;
    if (kind === "credential_needed") this.deps.credentialNotice?.();
    if (kind === "task_failed") this.failed = true;
    const stamp = Date.now();
    if (stamp - (this.last.get(kind) ?? 0) < 30000) return { type: "notification_registration", in_reply_to: "", ok: true };
    const pane_name = readablePaneName(this.deps.paneName?.());
    const preview = kind === "input_needed" ? sanitizeQuestion(question) : undefined;
    const reply = await this.control({ type: "notification_event", kind, event_id: eventId ?? `${this.run}-${kind}`, ...(pane_name ? { pane_name } : {}), ...(preview ? { question: preview } : {}) });
    if (reply.ok) this.last.set(kind, stamp);
    return reply;
  }
  reconcile(phones: string[]): void { void this.control({ type: "notification_pairings", phones }); }
  cancelled(): void { this.waiting = true; }
  observeAssistant(stopReason: string | undefined): void {
    this.observedError = stopReason === "error";
    if (stopReason === "aborted") this.cancelled();
  }
  end(): void {
    if (this.active && this.observedError) void this.emit("task_failed");
    else if (this.active && !this.failed && !this.waiting && this.unresolvedPrompts.size === 0) void this.emit("task_finished");
    this.active = false;
    this.unresolvedPrompts.clear(); // aborted/expired tool prompts cannot poison a later run
    this.restoreActivity();
  }
  restoreActivity(): void {
    const call = this.deps.callActive?.() === true;
    void this.control({ type: "notification_activity", active: this.active || call, ...(!this.active && call ? { lease_seconds: 90 } : {}) });
  }
  pauseTransport(): void { void this.control({ type: "notification_activity", active: false }); }
  stop(): void { this.active = false; this.waiting = false; this.unresolvedPrompts.clear(); this.pauseTransport(); }
  registerTool(pi: ExtensionAPI): void {
    // Pi 1.4 exposes generic blocking UI lifecycle events. They are input
    // requests, not proof of a credential prompt: never inspect titles or
    // forward their contents. Older hosts simply never emit these events.
    const prompts = new Map<string, { id: string; depth: number }>();
    const on = pi.on as unknown as (event: string, handler: (event: {kind?: unknown}) => void) => unknown;
    if (typeof on === "function") {
      on.call(pi, "ui_prompt_start", (event) => {
        const kind = typeof event.kind === "string" ? event.kind : "ui";
        const current = prompts.get(kind);
        if (current) { current.depth++; return; }
        const prompt = { id: `native-${randomUUID()}`, depth: 1 };
        prompts.set(kind, prompt);
        this.promptOpened(prompt.id);
      });
      on.call(pi, "ui_prompt_end", (event) => {
        const kind = typeof event.kind === "string" ? event.kind : "ui";
        const current = prompts.get(kind);
        if (!current || --current.depth > 0) return;
        prompts.delete(kind);
        this.promptResolved(current.id);
      });
      const clearPrompts = () => { for (const p of prompts.values()) this.promptResolved(p.id); prompts.clear(); };
      on.call(pi, "session_start", clearPrompts);
      on.call(pi, "session_shutdown", clearPrompts);
    }
    pi.registerCommand("credential-needed", {
      description: "Show generic credential/sign-in blocker instructions and notify the paired phone (no secrets or arguments)",
      handler: async (args, ctx) => {
        if (args.trim()) { ctx.ui.notify("This command accepts no arguments or secret values.", "warning"); return; }
        const reply = await this.emit("credential_needed");
        if (!reply.ok) ctx.ui.notify("Credential blocker instructions shown on this pane. Phone push is unavailable.", "warning");
      },
    });
    const parameters = Type.Object({ category: Type.Union([Type.Literal("input_needed"), Type.Literal("credential_needed"), Type.Literal("review_ready"), Type.Literal("tests_failed"), Type.Literal("task_failed"), Type.Literal("task_finished")]), question: Type.Optional(Type.String({ maxLength: 4096, description: "Optional actual short question for input_needed only. Never include credentials, secret values, tool output, or approval bodies. Private previews require phone opt-in." })) });
    pi.registerTool({ name: "notify_user", label: "Notify paired phone", description: "Signal a real input/approval or credential/sign-in blocker (highest importance), completed task, terminal task failure, verified failed tests, or work ready for review. Use input_needed before waiting for a human, or credential_needed when a credential/sign-in is required. This never transports credentials or infers arbitrary system prompts. Never call for routine tool activity. Only a category, optional pane label, and sanitized explicit input question leave the machine. Lock-screen previews require phone opt-in. Success means relay accepted the event, not phone delivery; permissions and Focus may suppress it.", parameters,
      execute: async (_id, args) => {
        if (args.question !== undefined && args.category !== "input_needed") throw new Error("Question previews are only permitted for input_needed.");
        const reply = await this.emit(args.category, undefined, false, args.question);
        if (!reply.ok) throw new Error(`Notification unavailable: ${reply.error ?? "unknown"}`);
        return { content: [{ type: "text", text: "Notification event accepted or deduplicated. Delivery is not guaranteed." }], details: { category: args.category } };
      },
    });
  }
}
