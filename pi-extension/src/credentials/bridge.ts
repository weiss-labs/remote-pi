// Private credential handoff bridge. One pending signed request at a time; the
// paired phone answers with ciphertext only the Mac's ephemeral key can open.
// The decrypted value never enters a tool result, a log, an error or the
// transcript: it is written to a private 0600 file with a short TTL and only
// the path is returned. Replays, altered requests, foreign phones, stale
// sessions and oversized secrets are refused before any decrypt.
import { randomBytes, randomUUID } from "node:crypto";
import { constants, type Dirent } from "node:fs";
import { chmod, lstat, mkdir, open, readdir, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import { canonicalizeEd25519PublicKey } from "../mesh/encoding.js";
import { canonicalRequest, decrypt, deriveKey, generateX25519, keysEqual, MAX_SECRET_BYTES, NONCE_BYTES, signRequest, TAG_BYTES, verifyResponse, type CredentialRequestFields, type X25519Keypair } from "./crypto.js";

export const REQUEST_TTL_MS = 10 * 60 * 1000;
export const FILE_TTL_MS = 15 * 60 * 1000;
export const MAX_LABEL = 120;
export const MAX_REFERENCE = 240;
export const MAX_PURPOSE = 240;
/** Only 1Password vault-unlock / whole-vault shortcuts. A Stripe/AWS "secret key" or an ordinary
 *  service password is one scoped credential and stays allowed; every reference starts with
 *  "1Password →" because that is where it is found, not what it unlocks. */
export const FORBIDDEN_REFERENCE = /master[\s_-]*password|1password[\s_-]*(?:account[\s_-]*)?password|(?:account|vault)[\s_-]*password[\s_-]*(?:for|of)[\s_-]*1password|1password[\s_-]*secret[\s_-]*key|secret[\s_-]*key[\s_-]*(?:for|of)[\s_-]*1password|\bA3-[A-Z0-9]{6}-[A-Z0-9-]{20,}\b|emergency[\s_-]*kit|recovery[\s_-]*codes?[\s_-]*(?:for|of)[\s_-]*1password|1password[\s_-]*recovery[\s_-]*codes?|service[\s_-]*account[\s_-]*token|OP_SERVICE_ACCOUNT_TOKEN|OP_SESSION|op_session|1password[\s_-]*service[\s_-]*account/i;

export type CredentialCloseReason = "fulfilled" | "cancelled" | "expired" | "session_ended" | "aborted" | "none";
export type CredentialServerMessage =
  | { type: "credential_request"; id: string; mac_key: string; room: string; session: string; expires_at: number; label: string; reference: string; purpose: string; mac_epk: string; sig: string }
  | { type: "credential_closed"; id: string; reason: CredentialCloseReason; in_reply_to?: string }
  | { type: "credential_result"; in_reply_to: string; id: string; ok: boolean; error?: string };
export type CredentialClientMessage =
  | { type: "credential_response"; id: string; request_id: string; phone_key: string; phone_epk: string; nonce: string; ciphertext: string; sig: string }
  | { type: "credential_cancel"; id: string; request_id: string }
  | { type: "credential_query"; id: string };

export interface CredentialDelivery { path: string; reference: string; label: string; expires_at: number }

interface Dependencies {
  identity(): Ed25519Keypair | null;
  room(): string | null;
  /** Active channel must be this exact sender AND the owner must still be durably paired. */
  authorize(phone: string, sender: object): Promise<boolean>;
  broadcast(msg: CredentialServerMessage): void;
  /** Tracked credential-needed waiting state (generic push, no item details). */
  opened(id: string): void;
  resolved(id: string): void;
  dir?: string;
  now?(): number;
}
interface Pending {
  fields: CredentialRequestFields; sig: string; ephemeral: X25519Keypair; generation: number; busy: boolean;
  resolve(d: CredentialDelivery): void; reject(e: Error): void; timer: ReturnType<typeof setTimeout>; signal?: AbortSignal; onAbort?: () => void;
}
interface Stored { path: string; value: string; timer: ReturnType<typeof setTimeout> }
export interface ToolResultLike { content: unknown; details?: unknown }
class Refused extends Error { constructor(readonly code: string) { super(code); } }

const B64_32 = /^[A-Za-z0-9+/]{43}=$/;
const B64_12 = /^[A-Za-z0-9+/]{16}$/;
const B64_SIG = /^[A-Za-z0-9+/]{86}==$/;
const B64_ANY = /^[A-Za-z0-9+/]+={0,2}$/;

export function validateText(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const clean = value.replace(/[\p{Cc}\p{Cf}]/gu, "").trim();
  return clean && clean.length <= max ? clean : null;
}

export class CredentialBridge {
  private pending: Pending | null = null;
  private generation = 0;
  private session = randomUUID();
  private stored = new Map<string, Stored>();
  constructor(private readonly deps: Dependencies) {}
  private now(): number { return this.deps.now?.() ?? Date.now(); }
  private dir(): string { return this.deps.dir ?? join(homedir(), ".pi", "remote", "credentials"); }

  /** New session/tree: fresh nonce, every earlier request/response is stale, this process's
   *  earlier files are deleted and stale files from other processes swept. */
  start(): void {
    this.close("session_ended");
    this.generation++; this.session = randomUUID();
    for (const s of [...this.stored.values()]) this.forget(s);
    void this.sweep();
  }
  stop(): void {
    this.close("session_ended");
    this.generation++;
    for (const s of [...this.stored.values()]) this.forget(s);
  }
  pendingWire(): Extract<CredentialServerMessage, { type: "credential_request" }> | null {
    const p = this.pending;
    if (!p || p.fields.expires_at <= this.now()) return null;
    return { type: "credential_request", ...p.fields, sig: p.sig };
  }

  private close(reason: CredentialCloseReason, error = reason): void {
    const p = this.pending;
    if (!p) return;
    this.pending = null;
    clearTimeout(p.timer);
    if (p.signal && p.onAbort) p.signal.removeEventListener("abort", p.onAbort);
    this.deps.resolved(p.fields.id);
    this.deps.broadcast({ type: "credential_closed", id: p.fields.id, reason });
    if (reason !== "fulfilled") p.reject(new Error(`Credential request ${error}. No value was received; call request_credential again if it is still needed.`));
  }

  /** Model-facing entry. Resolves only after the private file exists and authority was rechecked. */
  request(args: { label: unknown; reference: unknown; purpose: unknown }, signal?: AbortSignal): Promise<CredentialDelivery> {
    const label = validateText(args.label, MAX_LABEL), reference = validateText(args.reference, MAX_REFERENCE), purpose = validateText(args.purpose, MAX_PURPOSE);
    if (!label || !reference || !purpose) return Promise.reject(new Error(`label (≤${MAX_LABEL}), reference (≤${MAX_REFERENCE}) and purpose (≤${MAX_PURPOSE}) are required plain text.`));
    if (FORBIDDEN_REFERENCE.test(`${label}\n${reference}\n${purpose}`)) return Promise.reject(new Error("Refused: request one scoped credential (API key, token, password for one service). The 1Password account password, Secret Key, Emergency Kit, recovery codes and service-account tokens are never requested through this channel."));
    if (signal?.aborted) return Promise.reject(new Error("Credential request aborted."));
    const identity = this.deps.identity(), room = this.deps.room();
    if (!identity || !room) return Promise.reject(new Error("No paired phone session is active, so a private credential cannot be requested."));
    if (this.pending) return Promise.reject(new Error("Another credential request is already pending on the phone. Wait for it to resolve or cancel before asking for a second one."));
    const ephemeral = generateX25519();
    const fields: CredentialRequestFields = {
      mac_key: Buffer.from(identity.publicKey).toString("base64"), room, session: this.session, id: randomUUID(),
      expires_at: this.now() + REQUEST_TTL_MS, label, reference, purpose, mac_epk: ephemeral.publicKey.toString("base64"),
    };
    const sig = signRequest(identity.secretKey, fields);
    return new Promise<CredentialDelivery>((resolve, reject) => {
      const p: Pending = { fields, sig, ephemeral, generation: this.generation, busy: false, resolve, reject, signal,
        timer: setTimeout(() => this.close("expired"), REQUEST_TTL_MS) };
      if (signal) { p.onAbort = () => this.close("aborted"); signal.addEventListener("abort", p.onAbort, { once: true }); }
      this.pending = p;
      this.deps.opened(fields.id);
      this.deps.broadcast({ type: "credential_request", ...fields, sig });
    });
  }

  async handle(phone: string, sender: object, msg: CredentialClientMessage): Promise<CredentialServerMessage> {
    const id = typeof msg.id === "string" ? msg.id.slice(0, 128) : "";
    const result = (ok: boolean, error?: string): CredentialServerMessage => ({ type: "credential_result", in_reply_to: id, id: "request_id" in msg && typeof msg.request_id === "string" ? msg.request_id.slice(0, 128) : "", ok, ...(error ? { error } : {}) });
    if (!(await this.deps.authorize(phone, sender))) return result(false, "not_paired");
    if (msg.type === "credential_query") {
      const wire = this.pendingWire();
      return wire ?? { type: "credential_closed", id: "", reason: "none", in_reply_to: id };
    }
    const p = this.pending;
    if (!p || typeof msg.request_id !== "string" || msg.request_id !== p.fields.id || p.generation !== this.generation) return result(false, "no_pending");
    if (p.fields.expires_at <= this.now()) { this.close("expired"); return result(false, "expired"); }
    if (msg.type === "credential_cancel") { this.close("cancelled"); return result(true); }
    if (p.busy) return result(false, "busy");
    p.busy = true;
    try {
      const path = await this.accept(phone, sender, p, msg);
      if (this.pending !== p) throw new Refused("aborted");
      const delivery: CredentialDelivery = { path, reference: p.fields.reference, label: p.fields.label, expires_at: this.now() + FILE_TTL_MS };
      this.pending = null; clearTimeout(p.timer);
      if (p.signal && p.onAbort) p.signal.removeEventListener("abort", p.onAbort);
      this.deps.resolved(p.fields.id);
      this.deps.broadcast({ type: "credential_closed", id: p.fields.id, reason: "fulfilled" });
      p.resolve(delivery);
      return result(true);
    } catch (e) {
      if (this.pending === p) p.busy = false;
      return result(false, e instanceof Refused ? e.code : "internal_error");
    }
  }

  private async accept(phone: string, sender: object, p: Pending, msg: Extract<CredentialClientMessage, { type: "credential_response" }>): Promise<string> {
    if (!B64_32.test(msg.phone_key) || !B64_32.test(msg.phone_epk) || !B64_12.test(msg.nonce) || !B64_SIG.test(msg.sig) ||
        typeof msg.ciphertext !== "string" || msg.ciphertext.length > Math.ceil((MAX_SECRET_BYTES + TAG_BYTES) / 3) * 4 || !B64_ANY.test(msg.ciphertext)) throw new Refused("invalid");
    let phoneKey: Buffer;
    try { phoneKey = Buffer.from(canonicalizeEd25519PublicKey(phone, "Relay Owner key"), "base64"); } catch { throw new Refused("not_paired"); }
    if (!keysEqual(phoneKey, Buffer.from(msg.phone_key, "base64"))) throw new Refused("wrong_phone");
    const fields = { id: msg.request_id, phone_key: msg.phone_key, phone_epk: msg.phone_epk, nonce: msg.nonce, ciphertext: msg.ciphertext };
    if (!verifyResponse(phoneKey, p.fields, fields, msg.sig)) throw new Refused("bad_signature");
    const ciphertext = Buffer.from(msg.ciphertext, "base64");
    if (ciphertext.length < TAG_BYTES + 1 || ciphertext.length > MAX_SECRET_BYTES + TAG_BYTES) throw new Refused("too_large");
    let plaintext: Buffer;
    try {
      const key = deriveKey(p.ephemeral, Buffer.from(msg.phone_epk, "base64"), p.fields.mac_epk, msg.phone_epk, p.fields.id);
      plaintext = decrypt(key, canonicalRequest(p.fields), Buffer.from(msg.nonce, "base64"), ciphertext);
      key.fill(0);
    } catch { throw new Refused("decrypt_failed"); }
    try {
      if (plaintext.length === 0 || plaintext.length > MAX_SECRET_BYTES) throw new Refused("too_large");
      // Final authority check after the (slow) crypto: still the same pending request,
      // same session, not aborted, phone still durably paired and still on this channel.
      if (this.pending !== p || p.generation !== this.generation || p.signal?.aborted || p.fields.expires_at <= this.now()) throw new Refused("aborted");
      if (!(await this.deps.authorize(phone, sender))) throw new Refused("not_paired");
      const path = await this.write(plaintext);
      // The write yielded: the owner may have been revoked, the channel replaced, the
      // request aborted/expired or the session changed meanwhile. Nothing is delivered
      // from a file whose authority lapsed; it is removed before the refusal.
      const live = () => this.pending === p && p.generation === this.generation && !p.signal?.aborted && p.fields.expires_at > this.now();
      if (!live()) { await this.forgetPath(path); throw new Refused("aborted"); }
      if (!(await this.deps.authorize(phone, sender))) { await this.forgetPath(path); throw new Refused("not_paired"); }
      if (!live()) { await this.forgetPath(path); throw new Refused("aborted"); }
      return path;
    } finally { plaintext.fill(0); }
  }

  private async write(plaintext: Buffer): Promise<string> {
    const dir = this.dir();
    let path: string | null = null;
    try {
      await mkdir(dir, { recursive: true, mode: 0o700 });
      // lstat BEFORE chmod: a symlink planted at the directory path must not
      // have its target's permissions touched.
      const st = await lstat(dir);
      if (!st.isDirectory() || st.isSymbolicLink()) throw new Error("bad dir");
      await chmod(dir, 0o700);
      const file = join(dir, `cred-${randomBytes(16).toString("hex")}`);
      path = file;
      const fh = await open(file, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try { await fh.writeFile(plaintext); await fh.sync(); } finally { await fh.close(); }
      const value = plaintext.toString("utf8");
      this.stored.set(file, { path: file, value, timer: setTimeout(() => void this.forgetPath(file), FILE_TTL_MS) });
      return file;
    } catch {
      // A partially written file must not outlive the failure.
      if (path) await unlink(path).catch(() => {});
      throw new Refused("write_failed");
    }
  }
  private forget(s: Stored): void { clearTimeout(s.timer); this.stored.delete(s.path); void unlink(s.path).catch(() => {}); }
  private async forgetPath(path: string): Promise<void> { const s = this.stored.get(path); if (s) this.forget(s); else await unlink(path).catch(() => {}); }
  /** Deletes stale `cred-*` files from earlier processes. Never reads them. */
  async sweep(): Promise<void> {
    let entries: Dirent[];
    try { entries = await readdir(this.dir(), { withFileTypes: true }); } catch { return; }
    const cutoff = this.now() - FILE_TTL_MS;
    for (const e of entries) {
      if (!e.name.startsWith("cred-")) continue;
      const path = join(this.dir(), e.name);
      try { const st = await lstat(path); if (st.isFile() && st.mtimeMs <= cutoff && !this.stored.has(path)) await unlink(path); } catch { /* best effort */ }
    }
  }

  /** Best-effort transcript hygiene: replaces live supplied literals in text, exactly as supplied
   *  (no trimming into a different secret) and without trailing newlines (what `$(cat file)`
   *  yields). Short values such as a six-digit OTP are covered too. Not a security boundary. */
  redact(text: string): string {
    let out = text;
    for (const s of this.stored.values()) {
      for (const v of new Set([s.value, s.value.replace(/[\r\n]+$/, "")])) {
        if (v.length >= 4 && out.includes(v)) out = out.split(v).join("[redacted credential]");
      }
    }
    return out;
  }
  /** Recursively redacts decoded string values inside details/structured data (bounded). */
  redactValue(value: unknown, depth = 0): unknown {
    if (typeof value === "string") return this.redact(value);
    if (depth > 24 || value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(v => this.redactValue(v, depth + 1));
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = this.redactValue(v, depth + 1);
    return out;
  }
  /** `tool_result` hook body against the actual SDK event shape ({ content, details }). Content text
   *  parts and `details` are redacted independently; returns undefined when nothing changed. */
  redactToolResult(event: ToolResultLike): { content?: unknown; details?: unknown } | undefined {
    if (this.stored.size === 0) return undefined;
    const result: { content?: unknown; details?: unknown } = {};
    if (Array.isArray(event.content)) {
      let changed = false;
      const content = event.content.map((part: unknown) => {
        const p = part as { type?: unknown; text?: unknown };
        if (p?.type !== "text" || typeof p.text !== "string") return part;
        const text = this.redact(p.text);
        if (text === p.text) return part;
        changed = true; return { ...p, text };
      });
      if (changed) result.content = content;
    }
    if (event.details !== undefined) {
      const details = this.redactValue(event.details);
      if (JSON.stringify(details) !== JSON.stringify(event.details)) result.details = details;
    }
    return result.content !== undefined || result.details !== undefined ? result : undefined;
  }
  hasLiveValues(): boolean { return this.stored.size > 0; }
}
