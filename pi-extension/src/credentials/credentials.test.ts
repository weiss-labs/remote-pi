import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as ed from "@noble/ed25519";
import vectors from "./vectors.json" with { type: "json" };
import { canonicalRequest, decrypt, deriveKey, encrypt, generateX25519, signRequest, signResponse, verifyRequest, verifyResponse, x25519FromSeed, MAX_SECRET_BYTES, type CredentialRequestFields } from "./crypto.js";
import { CredentialBridge, FILE_TTL_MS, REQUEST_TTL_MS, type CredentialClientMessage, type CredentialServerMessage } from "./bridge.js";
import { registerCredentialTool } from "./tool.js";

(ed.hashes as Record<string, unknown>)["sha512"] = (...m: Uint8Array[]) => { const h = createHash("sha512"); for (const x of m) h.update(x); return Uint8Array.from(h.digest()); };
const b64 = (s: string) => Buffer.from(s, "base64");
const req = vectors.request as CredentialRequestFields;

describe("credential crypto vectors (shared with app/test/data/credentials)", () => {
  it("reproduces request signature, canonical bytes, key, ciphertext and response signature", () => {
    expect(canonicalRequest(req).toString("utf8")).toBe(vectors.canonical_request);
    expect(signRequest(b64(vectors.mac_seed), req)).toBe(vectors.request_sig);
    expect(verifyRequest(Buffer.from(ed.getPublicKey(b64(vectors.mac_seed))), req, vectors.request_sig)).toBe(true);
    const macE = x25519FromSeed(b64(vectors.mac_x25519_seed)), phoneE = x25519FromSeed(b64(vectors.phone_x25519_seed));
    expect(macE.publicKey.toString("base64")).toBe(req.mac_epk);
    expect(phoneE.publicKey.toString("base64")).toBe(vectors.response.phone_epk);
    const phoneKey = deriveKey(phoneE, macE.publicKey, req.mac_epk, vectors.response.phone_epk, req.id);
    const macKey = deriveKey(macE, phoneE.publicKey, req.mac_epk, vectors.response.phone_epk, req.id);
    expect(phoneKey.toString("base64")).toBe(vectors.key);
    expect(macKey.equals(phoneKey)).toBe(true);
    expect(encrypt(phoneKey, canonicalRequest(req), b64(vectors.secret), b64(vectors.response.nonce)).ciphertext.toString("base64")).toBe(vectors.response.ciphertext);
    expect(decrypt(macKey, canonicalRequest(req), b64(vectors.response.nonce), b64(vectors.response.ciphertext)).equals(b64(vectors.secret))).toBe(true);
    expect(signResponse(b64(vectors.phone_seed), req, vectors.response)).toBe(vectors.response_sig);
    expect(verifyResponse(Buffer.from(ed.getPublicKey(b64(vectors.phone_seed))), req, vectors.response, vectors.response_sig)).toBe(true);
  });
  it("rejects tampered ciphertext, nonce, aad, key and oversized secrets", () => {
    const macE = x25519FromSeed(b64(vectors.mac_x25519_seed)), phoneE = x25519FromSeed(b64(vectors.phone_x25519_seed));
    const key = deriveKey(macE, phoneE.publicKey, req.mac_epk, vectors.response.phone_epk, req.id);
    const aad = canonicalRequest(req), nonce = b64(vectors.response.nonce), ct = b64(vectors.response.ciphertext);
    const flipped = Buffer.from(ct); flipped[3] ^= 1;
    expect(() => decrypt(key, aad, nonce, flipped)).toThrow();
    const badNonce = Buffer.from(nonce); badNonce[0] ^= 1;
    expect(() => decrypt(key, aad, badNonce, ct)).toThrow();
    expect(() => decrypt(key, canonicalRequest({ ...req, reference: "other" }), nonce, ct)).toThrow();
    expect(() => decrypt(deriveKey(macE, phoneE.publicKey, req.mac_epk, vectors.response.phone_epk, "other-id"), aad, nonce, ct)).toThrow();
    expect(() => decrypt(key, aad, nonce, Buffer.alloc(MAX_SECRET_BYTES + 17))).toThrow("bad ciphertext");
    expect(() => deriveKey(macE, Buffer.alloc(32, 0), req.mac_epk, vectors.response.phone_epk, req.id)).toThrow();
    expect(verifyRequest(Buffer.from(ed.getPublicKey(b64(vectors.phone_seed))), req, vectors.request_sig)).toBe(false);
    expect(verifyResponse(Buffer.from(ed.getPublicKey(b64(vectors.phone_seed))), { ...req, label: "changed" }, vectors.response, vectors.response_sig)).toBe(false);
  });
});

// ── Bridge harness: a synthetic phone that answers like the app does ─────────
const macSeed = randomBytes(32), phoneSeed = randomBytes(32), strangerSeed = randomBytes(32);
const macId = { publicKey: Buffer.from(ed.getPublicKey(macSeed)), secretKey: macSeed };
const phoneKey = Buffer.from(ed.getPublicKey(phoneSeed)).toString("base64");
const strangerKey = Buffer.from(ed.getPublicKey(strangerSeed)).toString("base64");
function answer(request: Extract<CredentialServerMessage, { type: "credential_request" }>, secret: Buffer, opts: { seed?: Buffer; key?: string; tamper?: (r: CredentialRequestFields) => CredentialRequestFields } = {}): Extract<CredentialClientMessage, { type: "credential_response" }> {
  const { sig: _sig, type: _type, ...fields } = request;
  const signedFields = opts.tamper ? opts.tamper(fields) : fields;
  const phoneE = generateX25519();
  const key = deriveKey(phoneE, b64(fields.mac_epk), fields.mac_epk, phoneE.publicKey.toString("base64"), fields.id);
  const { nonce, ciphertext } = encrypt(key, canonicalRequest(fields), secret);
  const r = { id: fields.id, phone_key: opts.key ?? phoneKey, phone_epk: phoneE.publicKey.toString("base64"), nonce: nonce.toString("base64"), ciphertext: ciphertext.toString("base64") };
  return { type: "credential_response", id: "m1", request_id: fields.id, ...r, sig: signResponse(opts.seed ?? phoneSeed, signedFields, r) };
}
function harness() {
  const sender = {}, out: CredentialServerMessage[] = [], opened: string[] = [], resolved: string[] = [];
  const dir = mkdtempSync(join(tmpdir(), "rp-cred-"));
  let paired = true, now = 1_800_000_000_000, authorizeHook: (() => void) | null = null;
  const bridge = new CredentialBridge({ identity: () => macId, room: () => "room-1", dir, now: () => now,
    authorize: async (phone, s) => { authorizeHook?.(); return paired && s === sender && phone === phoneKey; },
    broadcast: (m) => { out.push(m); }, opened: (id) => { opened.push(id); }, resolved: (id) => { resolved.push(id); } });
  bridge.start();
  const request = () => out.filter((m): m is Extract<CredentialServerMessage, { type: "credential_request" }> => m.type === "credential_request").at(-1)!;
  return { bridge, sender, out, opened, resolved, dir, request, setPaired: (v: boolean) => { paired = v; }, tick: (ms: number) => { now += ms; }, onAuthorize: (fn: (() => void) | null) => { authorizeHook = fn; } };
}
const args = { label: "Synthetic key", reference: "1Password → Test → Item → credential", purpose: "unit test" };
/** Expected rejections are asserted later; keep Node's unhandled-rejection tracker quiet meanwhile. */
const quiet = <T,>(p: Promise<T>): Promise<T> => { p.catch(() => {}); return p; };

describe("CredentialBridge", () => {
  let h: ReturnType<typeof harness>;
  beforeEach(() => { vi.useFakeTimers(); h = harness(); });
  afterEach(() => { h.bridge.stop(); vi.useRealTimers(); rmSync(h.dir, { recursive: true, force: true }); });

  it("publishes a signed request with metadata only and resolves with a private 0600 file, never the value", async () => {
    const promise = h.bridge.request(args);
    const r = h.request();
    expect(r).toMatchObject({ mac_key: macId.publicKey.toString("base64"), room: "room-1", ...args });
    expect(verifyRequest(macId.publicKey, { ...r, type: undefined, sig: undefined } as unknown as CredentialRequestFields, r.sig)).toBe(true);
    expect(h.opened).toEqual([r.id]);
    expect(JSON.stringify(h.out)).not.toContain("synthetic-secret");
    const secret = Buffer.from("synthetic-secret\nmulti\tline ✓");
    const reply = await h.bridge.handle(phoneKey, h.sender, answer(r, secret));
    expect(reply).toMatchObject({ type: "credential_result", ok: true });
    const d = await promise;
    expect(d.reference).toBe(args.reference);
    expect(readFileSync(d.path).equals(secret)).toBe(true);
    expect(statSync(d.path).mode & 0o777).toBe(0o600);
    expect(lstatSync(h.dir).mode & 0o777).toBe(0o700);
    expect(h.resolved).toEqual([r.id]);
    expect(h.out.at(-1)).toEqual({ type: "credential_closed", id: r.id, reason: "fulfilled" });
    expect(JSON.stringify([h.out, reply, d])).not.toContain("synthetic-secret");
    // replay of the same accepted response cannot re-run or overwrite
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r, Buffer.from("other")))).toMatchObject({ ok: false, error: "no_pending" });
    expect(h.bridge.redact("token=synthetic-secret\nmulti\tline ✓ end")).toBe("token=[redacted credential] end");
    // Actual SDK hook shape: { content, details }. Content and details are redacted independently.
    const detailOnly = h.bridge.redactToolResult({ content: [{ type: "text", text: "ok" }], details: { env: { TOKEN: "synthetic-secret\nmulti\tline ✓" }, keep: 1, list: ["a", "synthetic-secret\nmulti\tline ✓"] } });
    expect(detailOnly).toEqual({ details: { env: { TOKEN: "[redacted credential]" }, keep: 1, list: ["a", "[redacted credential]"] } });
    const both = h.bridge.redactToolResult({ content: [{ type: "text", text: "x synthetic-secret\nmulti\tline ✓ y" }, { type: "image", data: "zz" }], details: { out: "synthetic-secret\nmulti\tline ✓" } });
    expect(both).toEqual({ content: [{ type: "text", text: "x [redacted credential] y" }, { type: "image", data: "zz" }], details: { out: "[redacted credential]" } });
    expect(h.bridge.redactToolResult({ content: [{ type: "text", text: "clean" }], details: { a: 1 } })).toBeUndefined();
    expect(h.bridge.redactToolResult({ content: "not-an-array", details: undefined })).toBeUndefined();
    vi.advanceTimersByTime(FILE_TTL_MS + 1);
    expect(h.bridge.hasLiveValues()).toBe(false);
    await vi.waitFor(() => expect(readdirSync(h.dir)).toEqual([]));
  });

  it.each([
    "1Password account password", "master password", "Master Password", "1Password Secret Key", "Secret Key for 1Password",
    "A3-ABCDEF-GHIJKL-MNOPQ-RSTUV-WXYZ1-23456", "Emergency Kit", "1Password recovery codes", "OP_SERVICE_ACCOUNT_TOKEN",
    "1Password service account token", "OP_SESSION_my", "1Password → Private → 1Password service account → token",
  ])("refuses the vault-unlock shortcut %j", async (reference) => {
    await expect(h.bridge.request({ ...args, reference })).rejects.toThrow("Refused");
    await expect(h.bridge.request({ ...args, label: reference })).rejects.toThrow("Refused");
    expect(h.out).toEqual([]);
  });
  it.each([
    ["Stripe secret key (live)", "1Password → Weiss Labs → Stripe live → secret key"],
    ["AWS secret access key", "1Password → Weiss Labs → AWS deploy user → Secret Access Key"],
    ["Postgres service password", "1Password → Clients → dagim-db → password"],
    ["GitHub service account PAT", "op://Weiss Labs/GitHub bot/token"],
    ["Vendor account password", "1Password → Vendors → Twilio account → password"],
  ])("allows the ordinary scoped credential %j", async (label, reference) => {
    const p = quiet(h.bridge.request({ label, reference, purpose: "task" }));
    expect(h.request()).toMatchObject({ label, reference });
    h.bridge.stop();
    await expect(p).rejects.toThrow("session_ended");
  });

  it("refuses bad text and a second concurrent request", async () => {
    await expect(h.bridge.request({ ...args, purpose: "" })).rejects.toThrow("required");
    await expect(h.bridge.request({ ...args, label: "x".repeat(121) })).rejects.toThrow("required");
    const first = quiet(h.bridge.request(args));
    await expect(h.bridge.request(args)).rejects.toThrow("already pending");
    h.bridge.stop();
    await expect(first).rejects.toThrow("session_ended");
  });

  it.each([
    ["foreign phone identity", (r: ReturnType<typeof h.request>) => [strangerKey, answer(r, Buffer.from("s"), { seed: strangerSeed, key: strangerKey })] as const, "not_paired"],
    ["phone_key claim not matching the channel", (r: ReturnType<typeof h.request>) => [phoneKey, answer(r, Buffer.from("s"), { key: strangerKey })] as const, "wrong_phone"],
    ["signature by another key", (r: ReturnType<typeof h.request>) => [phoneKey, answer(r, Buffer.from("s"), { seed: strangerSeed })] as const, "bad_signature"],
    ["signature over a changed request", (r: ReturnType<typeof h.request>) => [phoneKey, answer(r, Buffer.from("s"), { tamper: f => ({ ...f, reference: "other" }) })] as const, "bad_signature"],
    ["wrong request id", (r: ReturnType<typeof h.request>) => [phoneKey, { ...answer(r, Buffer.from("s")), request_id: "other" }] as const, "no_pending"],
    ["tampered ciphertext", (r: ReturnType<typeof h.request>) => { const a = answer(r, Buffer.from("s")); const c = b64(a.ciphertext); c[0] ^= 1; return [phoneKey, { ...a, ciphertext: c.toString("base64") }] as const; }, "bad_signature"],
    ["malformed fields", (r: ReturnType<typeof h.request>) => [phoneKey, { ...answer(r, Buffer.from("s")), nonce: "short" }] as const, "invalid"],
  ])("rejects %s without resolving the tool", async (_name, build, code) => {
    const promise = quiet(h.bridge.request(args));
    const [phone, msg] = build(h.request());
    expect(await h.bridge.handle(phone, h.sender, msg as CredentialClientMessage)).toMatchObject({ ok: false, error: code });
    expect(h.bridge.pendingWire()?.id).toBe(h.request().id);
    expect(readdirSync(h.dir)).toEqual([]);
    h.bridge.stop();
    await expect(promise).rejects.toThrow();
  });

  it("redacts multi-line/quoted values and six-digit OTPs exactly, without trimming into another secret", async () => {
    const p1 = h.bridge.request(args);
    const pem = '-----BEGIN SYNTHETIC-----\nab"c\n-----END SYNTHETIC-----\n';
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from(pem)));
    const d1 = await p1;
    expect(JSON.stringify(d1)).not.toContain("SYNTHETIC");
    const p2 = h.bridge.request(args);
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("483920")));
    await p2;
    // `$(cat file)` strips the trailing newline: both forms are covered; quotes/newlines inside survive matching.
    expect(h.bridge.redact(`key='${pem}' code=483920 other=4839201`)).toBe("key='[redacted credential]' code=[redacted credential] other=[redacted credential]1");
    expect(h.bridge.redact(`key=${pem.trimEnd()} end`)).toBe("key=[redacted credential] end");
    const r = h.bridge.redactToolResult({ content: [{ type: "text", text: JSON.stringify({ k: pem }) }], details: { stdout: `otp 483920\n`, nested: [{ v: pem.trimEnd() }] } });
    expect(JSON.stringify(r)).not.toContain("SYNTHETIC");
    expect(JSON.stringify(r)).not.toContain("483920");
    // The tool's own result stays path-only and is never changed by redaction.
    expect(h.bridge.redactToolResult({ content: [{ type: "text", text: `File: ${d1.path}` }], details: { path: d1.path, expires_at: d1.expires_at } })).toBeUndefined();
  });

  it("deletes the file and refuses when the owner is revoked or the request aborts during the write", async () => {
    const p1 = quiet(h.bridge.request(args));
    let calls = 0;
    h.onAuthorize(() => { if (++calls === 2) h.setPaired(false); }); // revoked while the file is being written
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "not_paired" });
    expect(readdirSync(h.dir)).toEqual([]);
    expect(h.bridge.hasLiveValues()).toBe(false);
    h.setPaired(true); h.onAuthorize(null);
    h.bridge.stop();
    await expect(p1).rejects.toThrow();
    h.bridge.start();
    const ac = new AbortController();
    const p2 = quiet(h.bridge.request(args, ac.signal));
    calls = 0;
    h.onAuthorize(() => { if (++calls === 3) ac.abort(); }); // aborted at the post-write authority check
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "aborted" });
    await expect(p2).rejects.toThrow("aborted");
    expect(readdirSync(h.dir)).toEqual([]);
  });

  it("write failures leave no file and a symlinked directory is refused before any chmod", async () => {
    const target = mkdtempSync(join(tmpdir(), "rp-cred-target-"));
    chmodSync(target, 0o755);
    rmSync(h.dir, { recursive: true, force: true });
    symlinkSync(target, h.dir);
    const p1 = quiet(h.bridge.request(args));
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "write_failed" });
    expect(statSync(target).mode & 0o777).toBe(0o755); // target permissions untouched
    expect(readdirSync(target)).toEqual([]);
    rmSync(h.dir, { force: true }); rmSync(target, { recursive: true, force: true });
    writeFileSync(h.dir, "a regular file where the directory should be");
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "write_failed" });
    expect(h.bridge.pendingWire()?.id).toBe(h.request().id); // still answerable after the failure
    rmSync(h.dir, { force: true }); mkdirSync(h.dir, { mode: 0o700 });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: true });
    await expect(p1).resolves.toMatchObject({ label: args.label });
  });

  it("a session switch deletes this process's earlier files and forgets their values", async () => {
    const p = h.bridge.request(args);
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("synthetic-secret-999")));
    const d = await p;
    expect(readFileSync(d.path, "utf8")).toBe("synthetic-secret-999");
    h.bridge.start(); // session_start / session_tree
    expect(h.bridge.hasLiveValues()).toBe(false);
    await vi.waitFor(() => expect(readdirSync(h.dir)).toEqual([]));
    expect(h.bridge.redact("synthetic-secret-999")).toBe("synthetic-secret-999");
  });

  it("rejects a secret over 16 KiB and an empty one", async () => {
    const promise = h.bridge.request(args);
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.alloc(MAX_SECRET_BYTES + 1, 65)))).toMatchObject({ ok: false, error: "too_large" });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.alloc(0)))).toMatchObject({ ok: false, error: "too_large" });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.alloc(MAX_SECRET_BYTES, 65)))).toMatchObject({ ok: true });
    await expect(promise).resolves.toMatchObject({ reference: args.reference });
  });

  it("rejects a revoked owner at the final authority check and an unknown channel", async () => {
    const promise = quiet(h.bridge.request(args));
    h.setPaired(false);
    expect(await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "not_paired" });
    h.setPaired(true);
    expect(await h.bridge.handle(phoneKey, {}, answer(h.request(), Buffer.from("s")))).toMatchObject({ ok: false, error: "not_paired" });
    h.bridge.stop();
    await expect(promise).rejects.toThrow();
  });

  it("expires after the request TTL, and a late response is refused", async () => {
    const promise = quiet(h.bridge.request(args));
    const r = h.request();
    h.tick(REQUEST_TTL_MS + 1);
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r, Buffer.from("s")))).toMatchObject({ ok: false, error: "expired" });
    await expect(promise).rejects.toThrow("expired");
    expect(h.out.at(-1)).toEqual({ type: "credential_closed", id: r.id, reason: "expired" });
    expect(h.bridge.pendingWire()).toBeNull();
  });

  it("cancels from the phone, aborts with the tool signal, and drops on session change", async () => {
    const p1 = quiet(h.bridge.request(args));
    expect(await h.bridge.handle(phoneKey, h.sender, { type: "credential_cancel", id: "c", request_id: h.request().id })).toMatchObject({ ok: true });
    await expect(p1).rejects.toThrow("cancelled");
    const ac = new AbortController();
    const p2 = quiet(h.bridge.request(args, ac.signal));
    ac.abort();
    await expect(p2).rejects.toThrow("aborted");
    expect(h.out.at(-1)).toMatchObject({ type: "credential_closed", reason: "aborted" });
    const p3 = quiet(h.bridge.request(args));
    const r3 = h.request();
    h.bridge.start(); // new session / tree change
    await expect(p3).rejects.toThrow("session_ended");
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r3, Buffer.from("s")))).toMatchObject({ ok: false, error: "no_pending" });
    expect(await h.bridge.handle(phoneKey, h.sender, { type: "credential_query", id: "q" })).toEqual({ type: "credential_closed", id: "", reason: "none", in_reply_to: "q" });
  });

  it("replays the pending request on query and session_sync, and nothing is written if aborted mid-write", async () => {
    const ac = new AbortController();
    const promise = quiet(h.bridge.request(args, ac.signal));
    const r = h.request();
    expect(await h.bridge.handle(phoneKey, h.sender, { type: "credential_query", id: "q" })).toEqual(r);
    expect(h.bridge.pendingWire()).toEqual(r);
    // Abort lands during the final authority check, after decrypt and before the write.
    let calls = 0;
    h.onAuthorize(() => { if (++calls === 2) ac.abort(); });
    expect(await h.bridge.handle(phoneKey, h.sender, answer(r, Buffer.from("s")))).toMatchObject({ ok: false, error: "aborted" });
    await expect(promise).rejects.toThrow("aborted");
    expect(readdirSync(h.dir)).toEqual([]);
  });

  it("sweeps stale files from earlier processes on start without reading them", async () => {
    const stale = join(h.dir, "cred-stale"), fresh = join(h.dir, "cred-fresh"), other = join(h.dir, "notes.txt");
    for (const f of [stale, fresh, other]) writeFileSync(f, "x");
    const old = new Date(1_800_000_000_000 - FILE_TTL_MS - 1000);
    utimesSync(stale, old, old);
    utimesSync(other, old, old);
    utimesSync(fresh, new Date(1_800_000_000_000), new Date(1_800_000_000_000));
    h.bridge.start();
    await h.bridge.sweep();
    expect(readdirSync(h.dir).sort()).toEqual(["cred-fresh", "notes.txt"]);
  });

  it("registers a tool whose result carries the path and guidance but never the value", async () => {
    let execute: ((id: string, a: unknown, s?: AbortSignal) => Promise<{ content: { type: string; text: string }[]; details: unknown }>) | undefined;
    const pi = { registerTool: (t: { name: string; execute: typeof execute }) => { expect(t.name).toBe("request_credential"); execute = t.execute; } } as never;
    registerCredentialTool(pi, h.bridge);
    const run = execute!("t1", args);
    await vi.waitFor(() => expect(h.bridge.pendingWire()).not.toBeNull());
    await h.bridge.handle(phoneKey, h.sender, answer(h.request(), Buffer.from("synthetic-secret-123")));
    const result = await run;
    expect(result.content[0].text).toContain(h.dir);
    expect(result.content[0].text).toContain("without printing");
    expect(JSON.stringify(result)).not.toContain("synthetic-secret-123");
  });
});
