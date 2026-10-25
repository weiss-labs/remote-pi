import { describe, expect, test, vi } from "vitest";
import { VoiceBridge, type PiVoiceApi } from "./bridge.js";

const api = (over: Partial<PiVoiceApi> = {}): PiVoiceApi => ({
  openRemote: async () => ({ origin: "http://127.0.0.1:5555", token: "tok", label: "ZachOS › voice", ratePerMinute: 0.05 }),
  stop: async () => {},
  isActive: () => true,
  ...over,
});

const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

async function opened(fetchFn: typeof fetch, piVoice = api()) {
  const bridge = new VoiceBridge({ api: () => piVoice, fetch: fetchFn });
  const sent: unknown[] = [];
  await bridge.handle({ type: "voice_open", id: "o1" }, (m) => sent.push(m));
  return { bridge, sent };
}

describe("VoiceBridge (plan 71)", () => {
  test("open without Pi Voice loaded says so", async () => {
    const bridge = new VoiceBridge({ api: () => undefined });
    const sent: any[] = [];
    await bridge.handle({ type: "voice_open", id: "o1" }, (m) => sent.push(m));
    expect(sent[0]).toMatchObject({ type: "voice_error", in_reply_to: "o1", code: "unavailable" });
  });

  test("open passes through Pi Voice refusals (busy, not idle)", async () => {
    const err = Object.assign(new Error("Voice already open on the Mac"), { code: "busy" });
    const bridge = new VoiceBridge({ api: () => api({ openRemote: async () => { throw err; } }) });
    const sent: any[] = [];
    await bridge.handle({ type: "voice_open", id: "o1" }, (m) => sent.push(m));
    expect(sent[0]).toMatchObject({ type: "voice_error", code: "busy", message: "Voice already open on the Mac" });
  });

  test("rpc before open is refused; token never needed by the phone", async () => {
    const bridge = new VoiceBridge({ api: () => api(), fetch: vi.fn() as any });
    expect(await bridge.rpc("/heartbeat", {})).toMatchObject({ status: 409 });
  });

  test("forwards allowed paths with the Mac-side token and origin", async () => {
    const fetchFn = vi.fn(async () => ok({ sdp: "v=0 answer" }));
    const { bridge, sent } = await opened(fetchFn as any);
    expect(sent[0]).toMatchObject({ type: "voice_opened", label: "ZachOS › voice", rate_per_minute: 0.05 });
    expect(sent[0]).not.toHaveProperty("token");
    const r = await bridge.rpc("/session", { sdp: "v=0 offer" });
    expect(r).toEqual({ status: 200, body: { sdp: "v=0 answer" } });
    const [url, init] = fetchFn.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://127.0.0.1:5555/session");
    expect(init.headers).toMatchObject({ Authorization: "Bearer tok", Origin: "http://127.0.0.1:5555" });
  });

  test("refuses paths the phone must not reach", async () => {
    const fetchFn = vi.fn();
    const { bridge } = await opened(fetchFn as any);
    for (const p of ["/screen", "/preferences", "/model", "/events", "/capture-result", "/attachment-open", "/../x"]) {
      expect((await bridge.rpc(p, {})).status).toBe(403);
    }
    expect(fetchFn).not.toHaveBeenCalled();
  });

  test("caps request size per path", async () => {
    const fetchFn = vi.fn();
    const { bridge } = await opened(fetchFn as any);
    expect((await bridge.rpc("/session", { sdp: "x".repeat(70_000) })).status).toBe(413);
    expect(fetchFn).not.toHaveBeenCalled();
  });

  test("passes Pi Voice errors through (409 stale approval)", async () => {
    const { bridge } = await opened((async () => ok({ ok: false, reason: "stale" }, 409)) as any);
    expect(await bridge.rpc("/approve", { id: "a", decision: "allow" })).toEqual({ status: 409, body: { ok: false, reason: "stale" } });
  });

  test("server gone → 410 and the session is forgotten", async () => {
    const { bridge } = await opened((async () => { throw new TypeError("ECONNREFUSED"); }) as any);
    expect((await bridge.rpc("/heartbeat", { after: 0 })).status).toBe(410);
    expect((await bridge.rpc("/heartbeat", { after: 0 })).status).toBe(409);
  });

  test("close stops the Mac session and forgets it", async () => {
    const fetchFn = vi.fn(async () => ok({ phase: "stopped", voiceCostUSD: 0.1 }));
    const { bridge } = await opened(fetchFn as any);
    const sent: any[] = [];
    await bridge.handle({ type: "voice_close", id: "c1" }, (m) => sent.push(m));
    expect(sent[0]).toMatchObject({ type: "voice_rpc_result", in_reply_to: "c1", status: 200 });
    expect((fetchFn.mock.calls[0] as unknown as [string])[0]).toBe("http://127.0.0.1:5555/stop");
    expect((await bridge.rpc("/heartbeat", {})).status).toBe(409);
  });
});
