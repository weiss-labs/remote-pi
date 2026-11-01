// Opt-in phone location for nearby asks (plan 76). One pending signed request per
// pane; the paired phone answers with ciphertext only this request's ephemeral key
// can open (same primitives as credentials, separate domain). Coordinates are
// returned to the tool caller only: never logged, broadcast or put in an error.
import { randomUUID } from "node:crypto";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import { canonicalizeEd25519PublicKey } from "../mesh/encoding.js";
import { validateText } from "../credentials/bridge.js";
import { canonicalRequest, decrypt, deriveKey, generateX25519, keysEqual, MAX_PLAINTEXT_BYTES, signRequest, verifyResponse, type LocationRequestFields, type X25519Keypair } from "./crypto.js";

export const REQUEST_TTL_MS = 20_000;
export const MAX_AGE_MS = 120_000;
/** Phone clock may run slightly ahead of the Mac's. */
const MAX_FUTURE_SKEW_MS = 30_000;
export const MAX_PURPOSE = 240;

export type LocationErrorReason = "off" | "denied" | "background" | "unavailable" | "stale" | "not_open" | "busy" | "aborted" | "session_ended" | "no_pairing";
const PHONE_REASONS = new Set(["off", "denied", "background", "unavailable"]);
const REASON_TEXT: Record<LocationErrorReason, string> = {
  off: "location sharing is off on the phone",
  denied: "location permission is denied on the phone",
  background: "Remote Pi is not open on the phone",
  unavailable: "the phone could not get a location fix",
  stale: `the phone's fix was older than ${MAX_AGE_MS / 1000} s`,
  not_open: `Remote Pi is not open on the phone (no answer within ${REQUEST_TTL_MS / 1000} s)`,
  busy: "another location request is already pending",
  aborted: "the request was cancelled",
  session_ended: "the session changed before the phone answered",
  no_pairing: "no paired phone is connected",
};
export class LocationError extends Error {
  constructor(readonly reason: LocationErrorReason) {
    super(`Live phone location unavailable: ${REASON_TEXT[reason]}. Use the home location instead and label it plainly as "from home, live location unavailable (${REASON_TEXT[reason]})". Do not describe home as where the user is now, and do not retry automatically.`);
  }
}

export interface LocationFix { lat: number; lng: number; accuracy_m: number; captured_at: number; age_ms: number }
export type LocationServerMessage =
  | { type: "location_request"; id: string; mac_key: string; room: string; session: string; expires_at: number; purpose: string; mac_epk: string; sig: string }
  | { type: "location_result"; in_reply_to: string; id: string; ok: boolean; error?: string };
export type LocationClientMessage =
  { type: "location_response"; id: string; request_id: string; phone_key: string; phone_epk: string; nonce: string; ciphertext: string; sig: string };

interface Dependencies {
  identity(): Ed25519Keypair | null;
  room(): string | null;
  /** True when at least one paired phone channel is live (else fail fast). */
  connected(): boolean;
  /** Active channel must be this exact sender AND the owner must still be durably paired. */
  authorize(phone: string, sender: object): Promise<boolean>;
  broadcast(msg: LocationServerMessage): void;
  now?(): number;
}
interface Pending {
  fields: LocationRequestFields; sig: string; ephemeral: X25519Keypair; generation: number; busy: boolean;
  resolve(f: LocationFix): void; reject(e: Error): void; timer: ReturnType<typeof setTimeout>; signal?: AbortSignal; onAbort?: () => void;
}
class Refused extends Error { constructor(readonly code: string) { super(code); } }

const B64_32 = /^[A-Za-z0-9+/]{43}=$/;
const B64_12 = /^[A-Za-z0-9+/]{16}$/;
const B64_SIG = /^[A-Za-z0-9+/]{86}==$/;
const B64_ANY = /^[A-Za-z0-9+/]+={0,2}$/;

export class LocationBridge {
  private pending: Pending | null = null;
  private generation = 0;
  private session = randomUUID();
  constructor(private readonly deps: Dependencies) {}
  private now(): number { return this.deps.now?.() ?? Date.now(); }

  start(): void { this.fail("session_ended"); this.generation++; this.session = randomUUID(); }
  stop(): void { this.fail("session_ended"); this.generation++; }
  pendingWire(): Extract<LocationServerMessage, { type: "location_request" }> | null {
    const p = this.pending;
    return p && p.fields.expires_at > this.now() ? { type: "location_request", ...p.fields, sig: p.sig } : null;
  }

  private settle(p: Pending): boolean {
    if (this.pending !== p) return false;
    this.pending = null;
    clearTimeout(p.timer);
    if (p.signal && p.onAbort) p.signal.removeEventListener("abort", p.onAbort);
    return true;
  }
  private fail(reason: LocationErrorReason, p = this.pending): void {
    if (p && this.settle(p)) p.reject(new LocationError(reason));
  }

  request(args: { purpose: unknown }, signal?: AbortSignal): Promise<LocationFix> {
    const purpose = validateText(args.purpose, MAX_PURPOSE);
    if (!purpose) return Promise.reject(new Error(`purpose (≤${MAX_PURPOSE} chars) is required plain text.`));
    if (signal?.aborted) return Promise.reject(new LocationError("aborted"));
    const identity = this.deps.identity(), room = this.deps.room();
    if (!identity || !room) return Promise.reject(new LocationError("no_pairing"));
    if (!this.deps.connected()) return Promise.reject(new LocationError("not_open"));
    if (this.pending) return Promise.reject(new LocationError("busy"));
    const ephemeral = generateX25519();
    const fields: LocationRequestFields = {
      mac_key: Buffer.from(identity.publicKey).toString("base64"), room, session: this.session, id: randomUUID(),
      expires_at: this.now() + REQUEST_TTL_MS, purpose, mac_epk: ephemeral.publicKey.toString("base64"),
    };
    const sig = signRequest(identity.secretKey, fields);
    return new Promise<LocationFix>((resolve, reject) => {
      const p: Pending = { fields, sig, ephemeral, generation: this.generation, busy: false, resolve, reject, signal,
        timer: setTimeout(() => this.fail("not_open", p), REQUEST_TTL_MS) };
      if (signal) { p.onAbort = () => this.fail("aborted", p); signal.addEventListener("abort", p.onAbort, { once: true }); }
      this.pending = p;
      this.deps.broadcast({ type: "location_request", ...fields, sig });
    });
  }

  async handle(phone: string, sender: object, msg: LocationClientMessage): Promise<LocationServerMessage> {
    const id = typeof msg.id === "string" ? msg.id.slice(0, 128) : "";
    const requestId = typeof msg.request_id === "string" ? msg.request_id.slice(0, 128) : "";
    const result = (ok: boolean, error?: string): LocationServerMessage => ({ type: "location_result", in_reply_to: id, id: requestId, ok, ...(error ? { error } : {}) });
    if (!(await this.deps.authorize(phone, sender))) return result(false, "not_paired");
    const p = this.pending;
    if (!p || requestId !== p.fields.id || p.generation !== this.generation) return result(false, "no_pending");
    if (p.fields.expires_at <= this.now()) { this.fail("not_open", p); return result(false, "expired"); }
    if (p.busy) return result(false, "busy");
    p.busy = true;
    try {
      const outcome = await this.accept(phone, sender, p, msg);
      if (!this.settle(p)) throw new Refused("aborted");
      if (typeof outcome === "string") p.reject(new LocationError(outcome)); else p.resolve(outcome);
      return result(true);
    } catch (e) {
      if (this.pending === p) p.busy = false;
      return result(false, e instanceof Refused ? e.code : "internal_error");
    }
  }

  private async accept(phone: string, sender: object, p: Pending, msg: LocationClientMessage): Promise<LocationFix | LocationErrorReason> {
    if (typeof msg.phone_key !== "string" || !B64_32.test(msg.phone_key) || typeof msg.phone_epk !== "string" || !B64_32.test(msg.phone_epk) ||
        typeof msg.nonce !== "string" || !B64_12.test(msg.nonce) || typeof msg.sig !== "string" || !B64_SIG.test(msg.sig) ||
        typeof msg.ciphertext !== "string" || msg.ciphertext.length > Math.ceil((MAX_PLAINTEXT_BYTES + 16) / 3) * 4 || !B64_ANY.test(msg.ciphertext)) throw new Refused("invalid");
    let phoneKey: Buffer;
    try { phoneKey = Buffer.from(canonicalizeEd25519PublicKey(phone, "Relay Owner key"), "base64"); } catch { throw new Refused("not_paired"); }
    if (!keysEqual(phoneKey, Buffer.from(msg.phone_key, "base64"))) throw new Refused("wrong_phone");
    const fields = { id: msg.request_id, phone_key: msg.phone_key, phone_epk: msg.phone_epk, nonce: msg.nonce, ciphertext: msg.ciphertext };
    if (!verifyResponse(phoneKey, p.fields, fields, msg.sig)) throw new Refused("bad_signature");
    let payload: unknown;
    try {
      const key = deriveKey(p.ephemeral, Buffer.from(msg.phone_epk, "base64"), p.fields.mac_epk, msg.phone_epk, p.fields.id);
      const plain = decrypt(key, canonicalRequest(p.fields), Buffer.from(msg.nonce, "base64"), Buffer.from(msg.ciphertext, "base64"));
      key.fill(0);
      if (plain.length > MAX_PLAINTEXT_BYTES) throw new Error("size");
      payload = JSON.parse(plain.toString("utf8"));
    } catch { throw new Refused("decrypt_failed"); }
    // Authority after the crypto: still this request, session, phone and channel.
    if (this.pending !== p || p.generation !== this.generation || p.signal?.aborted || p.fields.expires_at <= this.now()) throw new Refused("aborted");
    if (!(await this.deps.authorize(phone, sender))) throw new Refused("not_paired");
    if (this.pending !== p || p.generation !== this.generation) throw new Refused("aborted");
    return this.parse(payload);
  }

  private parse(payload: unknown): LocationFix | LocationErrorReason {
    const o = (payload && typeof payload === "object" ? payload : {}) as Record<string, unknown>;
    if (typeof o.error === "string") return PHONE_REASONS.has(o.error) ? o.error as LocationErrorReason : "unavailable";
    const { lat, lng, accuracy_m, captured_at } = o;
    if (typeof lat !== "number" || typeof lng !== "number" || typeof accuracy_m !== "number" || typeof captured_at !== "number" ||
        !Number.isFinite(lat) || !Number.isFinite(lng) || !Number.isFinite(accuracy_m) || !Number.isFinite(captured_at) ||
        Math.abs(lat) > 90 || Math.abs(lng) > 180 || accuracy_m < 0) throw new Refused("invalid_payload");
    const age = this.now() - captured_at;
    if (age < -MAX_FUTURE_SKEW_MS) throw new Refused("invalid_payload");
    if (age > MAX_AGE_MS) return "stale";
    return { lat, lng, accuracy_m, captured_at, age_ms: Math.max(0, age) };
  }
}

const pad = (n: number) => String(n).padStart(2, "0");
/** Model-facing success line WITHOUT coordinates, e.g. "Phone location ±12 m, captured 14:03:22 (8 s old)". */
export function describeFix(f: LocationFix): string {
  const t = new Date(f.captured_at);
  return `Phone location ±${Math.round(f.accuracy_m)} m, captured ${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())} (${Math.round(f.age_ms / 1000)} s old)`;
}
