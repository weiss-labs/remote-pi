import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import { createHash, randomBytes } from "node:crypto";
import * as ed from "@noble/ed25519";
import vectors from "./vectors.json" with { type: "json" };
import credVectors from "../credentials/vectors.json" with { type: "json" };
import * as cred from "../credentials/crypto.js";
import { canonicalRequest, decrypt, deriveKey, encrypt, generateX25519, signRequest, signResponse, verifyRequest, verifyResponse, x25519FromSeed, type LocationRequestFields } from "./crypto.js";
import { describeFix, LocationBridge, LocationError, MAX_AGE_MS, REQUEST_TTL_MS, type LocationClientMessage, type LocationServerMessage } from "./bridge.js";
import { FIX_TTL_MS, forgetFixes, registerLocationTool, sweepFixes, writeFix } from "./tool.js";
import { existsSync, mkdtempSync, readFileSync, statSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

(ed.hashes as Record<string, unknown>)["sha512"] = (...m: Uint8Array[]) => { const h = createHash("sha512"); for (const x of m) h.update(x); return Uint8Array.from(h.digest()); };
const b64 = (s: string) => Buffer.from(s, "base64");
const req = vectors.request as LocationRequestFields;
const pub = (seed: string) => Buffer.from(ed.getPublicKey(b64(seed)));

describe("location crypto vectors (shared with app/test/data/location)", () => {
  it("reproduces request signature, canonical bytes, key, ciphertext and response signature", () => {
    expect(canonicalRequest(req).toString("utf8")).toBe(vectors.canonical_request);
    expect(signRequest(b64(vectors.mac_seed), req)).toBe(vectors.request_sig);
    expect(verifyRequest(pub(vectors.mac_seed), req, vectors.request_sig)).toBe(true);
    const macE = x25519FromSeed(b64(vectors.mac_x25519_seed)), phoneE = x25519FromSeed(b64(vectors.phone_x25519_seed));
    const key = deriveKey(macE, phoneE.publicKey, req.mac_epk, vectors.response.phone_epk, req.id);
    expect(key.toString("base64")).toBe(vectors.key);
    expect(encrypt(key, canonicalRequest(req), b64(vectors.plaintext), b64(vectors.response.nonce)).ciphertext.toString("base64")).toBe(vectors.response.ciphertext);
    expect(decrypt(key, canonicalRequest(req), b64(vectors.response.nonce), b64(vectors.response.ciphertext)).equals(b64(vectors.plaintext))).toBe(true);
    expect(signResponse(b64(vectors.phone_seed), req, vectors.response)).toBe(vectors.response_sig);
    expect(verifyResponse(pub(vectors.phone_seed), req, vectors.response, vectors.response_sig)).toBe(true);
  });

  it("never accepts credential-domain signatures, keys or ciphertext as location ones (and vice versa)", () => {
    const macE = x25519FromSeed(b64(vectors.mac_x25519_seed)), phoneE = x25519FromSeed(b64(vectors.phone_x25519_seed));
    // Same ephemerals and request id: the two domains still derive different keys.
    const credKey = cred.deriveKey(macE, phoneE.publicKey, req.mac_epk, vectors.response.phone_epk, req.id);
    expect(credKey.toString("base64")).not.toBe(vectors.key);
    expect(() => decrypt(credKey, canonicalRequest(req), b64(vectors.response.nonce), b64(vectors.response.ciphertext))).toThrow();
    // A credential signature never verifies as a location signature.
    const credReq = credVectors.request as cred.CredentialRequestFields;
    expect(verifyRequest(pub(vectors.mac_seed), req, credVectors.request_sig)).toBe(false);
    expect(cred.verifyRequest(pub(vectors.mac_seed), credReq, vectors.request_sig)).toBe(false);
    expect(verifyResponse(pub(vectors.phone_seed), req, credVectors.response, credVectors.response_sig)).toBe(false);
    expect(cred.verifyResponse(pub(vectors.phone_seed), credReq, vectors.response, vectors.response_sig)).toBe(false);
    // Location ciphertext does not open under the credential key/AAD.
    expect(() => cred.decrypt(credKey, cred.canonicalRequest(credReq), b64(vectors.response.nonce), b64(vectors.response.ciphertext))).toThrow();
  });
});

// ── Bridge harness: a synthetic phone that answers like the app does ─────────
const macSeed = randomBytes(32), phoneSeed = randomBytes(32), strangerSeed = randomBytes(32);
const macId = { publicKey: Buffer.from(ed.getPublicKey(macSeed)), secretKey: macSeed };
const phoneKey = Buffer.from(ed.getPublicKey(phoneSeed)).toString("base64");
const strangerKey = Buffer.from(ed.getPublicKey(strangerSeed)).toString("base64");
type Req = Extract<LocationServerMessage, { type: "location_request" }>;
const START = 1_800_000_000_000;

function answer(request: Req, payload: unknown, opts: { seed?: Buffer; key?: string; credentialDomain?: boolean } = {}): LocationClientMessage {
  const { sig: _sig, type: _type, ...fields } = request;
  const phoneE = generateX25519();
  const phoneEpk = phoneE.publicKey.toString("base64");
  const plain = Buffer.from(JSON.stringify(payload));
  const r = { id: fields.id, phone_key: opts.key ?? phoneKey, phone_epk: phoneEpk, nonce: "", ciphertext: "" };
  let sig: string;
  if (opts.credentialDomain) {
    // A phone answering with the credential protocol instead (same fields, other domain).
    const credFields = { ...fields, label: "", reference: "" } as cred.CredentialRequestFields;
    const { nonce, ciphertext } = cred.encrypt(cred.deriveKey(phoneE, b64(fields.mac_epk), fields.mac_epk, phoneEpk, fields.id), cred.canonicalRequest(credFields), plain);
    Object.assign(r, { nonce: nonce.toString("base64"), ciphertext: ciphertext.toString("base64") });
    sig = cred.signResponse(opts.seed ?? phoneSeed, credFields, r);
  } else {
    const { nonce, ciphertext } = encrypt(deriveKey(phoneE, b64(fields.mac_epk), fields.mac_epk, phoneEpk, fields.id), canonicalRequest(fields), plain);
    Object.assign(r, { nonce: nonce.toString("base64"), ciphertext: ciphertext.toString("base64") });
    sig = signResponse(opts.seed ?? phoneSeed, fields, r);
  }
  return { type: "location_response", ...r, id: "m1", request_id: fields.id, sig };
}
function harness() {
  const sender = {}, out: LocationServerMessage[] = [];
  let paired = true, connected = true, now = START, authorizeHook: (() => void) | null = null;
  const bridge = new LocationBridge({ identity: () => macId, room: () => "room-1", now: () => now, connected: () => connected,
    authorize: async (phone, s) => { authorizeHook?.(); return paired && s === sender && phone === phoneKey; },
    broadcast: (m) => { out.push(m); } });
  bridge.start();
  const request = () => out.filter((m): m is Req => m.type === "location_request").at(-1)!;
  return { bridge, sender, out, request, setPaired: (v: boolean) => { paired = v; }, setConnected: (v: boolean) => { connected = v; },
    tick: (ms: number) => { now += ms; }, now: () => now, onAuthorize: (fn: (() => void) | null) => { authorizeHook = fn; } };
}
const fix = (capturedAt: number) => ({ lat: 40.6205, lng: -73.9811, accuracy_m: 12.4, captured_at: capturedAt });
const quiet = <T,>(p: Promise<T>): Promise<T> => { p.catch(() => {}); return p; };
const reason = async (p: Promise<unknown>) => { try { await p; return "resolved"; } catch (e) { return e instanceof LocationError ? e.reason : `other:${(e as Error).message}`; } };

describe("LocationBridge", () => {
  let h: ReturnType<typeof harness>;
  beforeEach(() => { vi.useFakeTimers(); h = harness(); });
  afterEach(() => { h.bridge.stop(); vi.useRealTimers(); });

  it("publishes a signed request without coordinates and resolves with one fresh fix", async () => {
    const p = h.bridge.request({ purpose: "find a nearby minyan" });
    const r = h.request();
    expect(r).toMatchObject({ mac_key: macId.publicKey.toString("base64"), room: "room-1", purpose: "find a nearby minyan", expires_at: START + REQUEST_TTL_MS });
    const { sig, type: _t, ...fields } = r;
    expect(verifyRequest(macId.publicKey, fields, sig)).toBe(true);
    h.tick(8_000);
    const reply = await h.bridge.handle(phoneKey, h.sender, answer(r, fix(START)));
    expect(reply).toEqual({ type: "location_result", in_reply_to: "m1", id: r.id, ok: true });
    const f = await p;
    expect(f).toMatchObject({ lat: 40.6205, lng: -73.9811, accuracy_m: 12.4, age_ms: 8_000 });
    expect(describeFix(f)).toMatch(/^Phone location ±12 m, captured \d\d:\d\d:\d\d \(8 s old\)$/);
    expect(JSON.stringify([h.out, reply])).not.toContain("40.62");
    // Replay of the accepted answer cannot re-run.
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r, fix(START)))).toMatchObject({ ok: false, error: "no_pending" });
    expect(h.bridge.pendingWire()).toBeNull();
  });

  it.each([["off"], ["denied"], ["background"], ["unavailable"]])("a signed %s error from the phone fails with that reason", async (code) => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), { error: code }))).toMatchObject({ ok: true });
    expect(await reason(p)).toBe(code);
  });
  it("an unknown phone error code becomes unavailable, and error text points at the labeled home fallback", async () => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), { error: "weird" }));
    await expect(p).rejects.toThrow(/Live phone location unavailable: the phone could not get a location fix\. Use the home location.*from home, live location unavailable/);
  });

  it("labels a fix older than 120 s as stale and refuses one from the future", async () => {
    const p1 = quiet(h.bridge.request({ purpose: "nearby" }));
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START - MAX_AGE_MS - 1)))).toMatchObject({ ok: true });
    expect(await reason(p1)).toBe("stale");
    const p2 = quiet(h.bridge.request({ purpose: "nearby" }));
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START + 60_000)))).toMatchObject({ ok: false, error: "invalid_payload" });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), { lat: 91, lng: 0, accuracy_m: 1, captured_at: START }))).toMatchObject({ ok: false, error: "invalid_payload" });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), { lat: "40", lng: 0, accuracy_m: 1, captured_at: START }))).toMatchObject({ ok: false, error: "invalid_payload" });
    expect(h.bridge.pendingWire()?.id).toBe(h.request().id);
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START + 5_000)))).toMatchObject({ ok: true }); // small skew is fine
    await expect(p2).resolves.toMatchObject({ age_ms: 0 });
  });

  it.each([
    ["foreign phone identity", (r: Req) => [strangerKey, answer(r, fix(START), { seed: strangerSeed, key: strangerKey })] as const, "not_paired"],
    ["phone_key claim not matching the channel", (r: Req) => [phoneKey, answer(r, fix(START), { key: strangerKey })] as const, "wrong_phone"],
    ["signature by another key", (r: Req) => [phoneKey, answer(r, fix(START), { seed: strangerSeed })] as const, "bad_signature"],
    ["a credential-domain response", (r: Req) => [phoneKey, answer(r, fix(START), { credentialDomain: true })] as const, "bad_signature"],
    ["wrong request id", (r: Req) => [phoneKey, { ...answer(r, fix(START)), request_id: "other" }] as const, "no_pending"],
    ["tampered ciphertext", (r: Req) => { const a = answer(r, fix(START)); const c = b64(a.ciphertext); c[0] ^= 1; return [phoneKey, { ...a, ciphertext: c.toString("base64") }] as const; }, "bad_signature"],
    ["malformed fields", (r: Req) => [phoneKey, { ...answer(r, fix(START)), nonce: "short" }] as const, "invalid"],
  ])("refuses %s and keeps waiting", async (_name, build, code) => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    const [phone, msg] = build(h.request());
    expect(await h.bridge.handle(phone, h.sender, msg as LocationClientMessage)).toMatchObject({ ok: false, error: code });
    expect(h.bridge.pendingWire()?.id).toBe(h.request().id);
    h.bridge.stop();
    expect(await reason(p)).toBe("session_ended");
  });

  it("refuses a response from an unknown channel or a revoked owner (even mid-check)", async () => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    expect(await h.bridge.handle(phoneKey, {}, answer(h.request(), fix(START)))).toMatchObject({ ok: false, error: "not_paired" });
    let calls = 0;
    h.onAuthorize(() => { if (++calls === 2) h.setPaired(false); }); // revoked during decrypt
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START)))).toMatchObject({ ok: false, error: "not_paired" });
    h.bridge.stop();
    expect(await reason(p)).toBe("session_ended");
  });

  it("times out after 20 s as 'not open', and the late reply is refused", async () => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    const r = h.request();
    h.tick(REQUEST_TTL_MS + 1);
    vi.advanceTimersByTime(REQUEST_TTL_MS + 1);
    expect(await reason(p)).toBe("not_open");
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r, fix(h.now())))).toMatchObject({ ok: false, error: "no_pending" });
  });

  it("an expired-but-unfired request refuses a late reply", async () => {
    const p = quiet(h.bridge.request({ purpose: "nearby" }));
    h.tick(REQUEST_TTL_MS);
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(h.now())))).toMatchObject({ ok: false, error: "expired" });
    expect(await reason(p)).toBe("not_open");
  });

  it("fails fast with no connected phone, refuses a second pending request, aborts, and drops on session change", async () => {
    h.setConnected(false);
    expect(await reason(h.bridge.request({ purpose: "nearby" }))).toBe("not_open");
    expect(h.out).toEqual([]);
    h.setConnected(true);
    await expect(h.bridge.request({ purpose: "" })).rejects.toThrow("purpose");
    const first = quiet(h.bridge.request({ purpose: "nearby" }));
    expect(await reason(h.bridge.request({ purpose: "nearby" }))).toBe("busy");
    const r1 = h.request();
    h.bridge.start(); // new session / tree
    expect(await reason(first)).toBe("session_ended");
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r1, fix(START)))).toMatchObject({ ok: false, error: "no_pending" });
    const ac = new AbortController();
    const p = quiet(h.bridge.request({ purpose: "nearby" }, ac.signal));
    expect(h.bridge.pendingWire()?.id).toBe(h.request().id);
    ac.abort();
    expect(await reason(p)).toBe("aborted");
    expect(h.bridge.pendingWire()).toBeNull();
  });

  it("an abort landing during the response checks wins: nothing resolves", async () => {
    const ac = new AbortController();
    const p = quiet(h.bridge.request({ purpose: "nearby" }, ac.signal));
    let calls = 0;
    h.onAuthorize(() => { if (++calls === 2) ac.abort(); });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START)))).toMatchObject({ ok: false, error: "aborted" });
    expect(await reason(p)).toBe("aborted");
  });

  it("registers request_location: success text carries the fix, errors name the reason and the home fallback", async () => {
    let execute: ((id: string, a: unknown, s?: AbortSignal) => Promise<{ content: { type: string; text: string }[] }>) | undefined;
    const pi = { on: () => {}, registerTool: (t: { name: string; execute: typeof execute }) => { expect(t.name).toBe("request_location"); execute = t.execute; } } as never;
    registerLocationTool(pi, h.bridge);
    const ok = execute!("t1", { purpose: "find a nearby minyan" });
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), fix(START)));
    const text = (await ok).content[0].text as string;
    expect(text).toMatch(/^Phone location ±12 m, captured .* \(0 s old\)\. Coordinates saved to (\S+) /);
    expect(text).not.toMatch(/40\.6|73\.98/);
    const path = /saved to (\S+) /.exec(text)![1];
    expect(readFileSync(path, "utf8")).toBe("40.6205,-73.9811\n");
    rmSync(path);
    const bad = quiet(execute!("t2", { purpose: "find a nearby minyan" }));
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), { error: "off" }));
    await expect(bad).rejects.toThrow(/location sharing is off on the phone.*home/);
  });
});

describe("coordinates never reach the model or the relay-readable channel", () => {
  it("writes the fix to a private 0600 file in a 0700 directory and returns only its path", async () => {
    const dir = join(mkdtempSync(join(tmpdir(), "rp-loc-")), "location");
    try {
      const path = await writeFix({ lat: 40.6205, lng: -73.9811, accuracy_m: 9, captured_at: 0, age_ms: 0 }, dir);
      expect(readFileSync(path, "utf8")).toBe("40.6205,-73.9811\n");
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(statSync(dir).mode & 0o777).toBe(0o700);
      expect(path).not.toMatch(/40\.6|73\.98/);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("session end deletes this process's files; a later start sweeps expired ones left by an exited Pi", async () => {
    const dir = join(mkdtempSync(join(tmpdir(), "rp-loc-")), "location");
    try {
      const fresh = await writeFix({ lat: 1, lng: 2, accuracy_m: 9, captured_at: 0, age_ms: 0 }, dir);
      await forgetFixes();
      expect(existsSync(fresh)).toBe(false);
      const orphan = join(dir, "loc-orphan"), recent = join(dir, "loc-recent"), other = join(dir, "notes");
      for (const f of [orphan, recent, other]) writeFileSync(f, "1,2\n");
      const old = (Date.now() - FIX_TTL_MS - 1000) / 1000;
      utimesSync(orphan, old, old); utimesSync(other, old, old);
      await sweepFixes(dir);
      expect([existsSync(orphan), existsSync(recent), existsSync(other)]).toEqual([false, true, true]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});
