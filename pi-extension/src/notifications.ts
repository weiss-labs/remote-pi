import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ed25519Sign, ed25519Verify, type Ed25519Keypair } from "./pairing/crypto.js";
import type { RelayClient } from "./transport/relay_client.js";

export const notificationCategories = ["input_needed", "task_finished", "task_failed", "tests_failed", "review_ready", "update_available", "connection_lost"] as const;
export type NotificationCategory = typeof notificationCategories[number];
export type AgentNotificationCategory = Exclude<NotificationCategory, "update_available" | "connection_lost">;
export type NotificationClientMessage =
  | { type: "notify_register"; id: string; device_id: string; token: string; environment: "production" | "sandbox"; categories: NotificationCategory[]; show_pane_name: boolean; expires_at: number; signature: string }
  | { type: "notify_unregister"; id: string; device_id: string }
  | { type: "notify_presence"; id: string; device_id: string; foreground: boolean; room?: string | null };
export type NotificationReply = { type: "notification_registration"; in_reply_to: string; ok: boolean; error?: string };
export function grantBytes(peer: string, phone: string, m: Extract<NotificationClientMessage, { type: "notify_register" }>): Uint8Array {
  return Buffer.from("remote-pi-notify-device-v1\n" + JSON.stringify([peer, phone, m.device_id, m.token, m.environment, m.categories, m.show_pane_name, m.expires_at]));
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
  /** Must recheck durable pairing, not just the relay key authentication. */
  paired(phone: string): Promise<boolean>;
}
export class NotificationBridge {
  private failed = false;
  private observedError = false;
  private waiting = false;
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
          !Array.isArray(msg.categories) || msg.categories.length > 7 || !msg.categories.every(c => notificationCategories.includes(c)) ||
          new Set(msg.categories).size !== msg.categories.length || typeof msg.show_pane_name !== "boolean" ||
          !Number.isSafeInteger(msg.expires_at) || msg.expires_at <= now || msg.expires_at > now + 30 * 86400 || typeof msg.signature !== "string") return fail("invalid_grant");
      const bytes = grantBytes(peer, phone, msg);
      try { if (!ed25519Verify(Buffer.from(phone, "base64"), bytes, Buffer.from(msg.signature, "base64"))) return fail("invalid_grant"); }
      catch { return fail("invalid_grant"); }
      // Authority comes only from the paired channel identity, never a body target.
      if (!(await this.deps.paired(phone)) || relay !== this.deps.relay()) return fail("not_paired");
      control = { type: "register_notification_device", grant: { peer, phone, device_id: msg.device_id, token: msg.token, environment: msg.environment, categories: msg.categories, show_pane_name: msg.show_pane_name, expires_at: msg.expires_at, signature: msg.signature, pi_signature: Buffer.from(ed25519Sign(identity.secretKey, bytes)).toString("base64") } };
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
    this.run = randomUUID(); this.failed = false; this.observedError = false; this.waiting = false; this.active = true;
    void this.control({ type: "notification_activity", active: true });
  }
  /** No arbitrary text, prompts, stdout, tool arguments, or labels enter push payloads. */
  async emit(kind: AgentNotificationCategory, eventId?: string): Promise<NotificationReply> {
    if (kind === "input_needed") this.waiting = true;
    if (kind === "task_failed") this.failed = true;
    const stamp = Date.now();
    if (stamp - (this.last.get(kind) ?? 0) < 30000) return { type: "notification_registration", in_reply_to: "", ok: true };
    const name = this.deps.paneName?.();
    const pane_name = typeof name === "string" ? name.replace(/[\x00-\x1f\x7f]/g, "").slice(0, 64) : undefined;
    const reply = await this.control({ type: "notification_event", kind, event_id: eventId ?? `${this.run}-${kind}`, ...(pane_name ? { pane_name } : {}) });
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
    if (this.active && this.observedError && !this.waiting) void this.emit("task_failed");
    else if (this.active && !this.failed && !this.waiting) void this.emit("task_finished");
    this.active = false;
    this.restoreActivity();
  }
  restoreActivity(): void {
    const call = this.deps.callActive?.() === true;
    void this.control({ type: "notification_activity", active: this.active || call, ...(!this.active && call ? { lease_seconds: 90 } : {}) });
  }
  stop(): void { this.active = false; void this.control({ type: "notification_activity", active: false }); }
  registerTool(pi: ExtensionAPI): void {
    const parameters = Type.Object({ category: Type.Union([Type.Literal("input_needed"), Type.Literal("review_ready"), Type.Literal("tests_failed"), Type.Literal("task_failed"), Type.Literal("task_finished")]) });
    pi.registerTool({ name: "notify_user", label: "Notify paired phone", description: "Signal a real input/approval blocker (highest importance), completed task, terminal task failure, verified failed tests, or work ready for review. Use input_needed before waiting for a human. Never call for routine tool activity. Only a generic category leaves the machine. Success means relay accepted the event, not phone delivery; permissions and Focus may suppress it.", parameters,
      execute: async (_id, args) => {
        const reply = await this.emit(args.category);
        if (!reply.ok) throw new Error(`Notification unavailable: ${reply.error ?? "unknown"}`);
        return { content: [{ type: "text", text: "Notification event accepted or deduplicated. Delivery is not guaranteed." }], details: { category: args.category } };
      },
    });
  }
}
