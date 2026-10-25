/**
 * Weiss Labs, plan 71: Pi Voice on the phone.
 *
 * The phone is a second window for the Mac's Pi Voice. Pi Voice (a separate
 * extension in the same Pi process) runs a local HTTP API on 127.0.0.1 that
 * its own WebView window uses; it publishes `globalThis.__piVoice` so we can
 * open a session without spawning that window. This module only forwards the
 * phone's calls to that API. It holds no voice logic, and the API token and
 * origin never leave the Mac.
 *
 * Audio does not come through here: the phone does WebRTC straight to OpenAI
 * with the SDP answer Pi Voice returns from `/session`.
 */

export interface PiVoiceApi {
  openRemote(): Promise<{ origin: string; token: string; label?: string; ratePerMinute?: number }>;
  stop(reason?: string): Promise<void>;
  isActive(): boolean;
}

export type VoiceClientMessage =
  | { type: "voice_open"; id: string }
  | { type: "voice_rpc"; id: string; path: string; body?: unknown }
  | { type: "voice_close"; id: string };

export type VoiceServerMessage =
  | { type: "voice_opened"; in_reply_to: string; label: string; rate_per_minute: number }
  | { type: "voice_error"; in_reply_to: string; code: string; message: string }
  | { type: "voice_rpc_result"; in_reply_to: string; status: number; body: unknown };

/** Pi Voice endpoints the phone may reach. Everything else is refused. */
const ALLOWED: Record<string, number> = {
  "/info": 1_000,
  "/session": 60_000, // SDP offer, same cap as the server
  "/heartbeat": 1_000,
  "/text": 20_000,
  "/approve": 2_000,
  "/draft-seen": 2_000,
  "/cancel-work": 1_000,
  "/stop": 1_000,
  "/attachment": 2_000, // draft attachment previews
};
/** Relay frames stay small; a bigger reply (a large attachment) is refused. */
const MAX_REPLY_BYTES = 4_000_000;
const RPC_TIMEOUT_MS = 25_000; // /session waits on OpenAI (server allows 20s)

type Send = (msg: VoiceServerMessage) => void;

export interface VoiceBridgeDeps {
  api?: () => PiVoiceApi | undefined;
  fetch?: typeof fetch;
}

const defaultApi = () => (globalThis as { __piVoice?: PiVoiceApi }).__piVoice;

export class VoiceBridge {
  private session: { origin: string; token: string } | null = null;
  private readonly api: () => PiVoiceApi | undefined;
  private readonly fetchFn: typeof fetch;

  constructor(deps: VoiceBridgeDeps = {}) {
    this.api = deps.api ?? defaultApi;
    this.fetchFn = deps.fetch ?? fetch;
  }

  static handles(type: string): type is VoiceClientMessage["type"] {
    return type === "voice_open" || type === "voice_rpc" || type === "voice_close";
  }

  async handle(msg: VoiceClientMessage, send: Send): Promise<void> {
    switch (msg.type) {
      case "voice_open":
        return this.open(msg.id, send);
      case "voice_rpc":
        send({ type: "voice_rpc_result", in_reply_to: msg.id, ...(await this.rpc(msg.path, msg.body)) });
        return;
      case "voice_close": {
        const r = this.session ? await this.rpc("/stop", {}) : { status: 200, body: { phase: "stopped" } };
        this.session = null;
        send({ type: "voice_rpc_result", in_reply_to: msg.id, ...r });
        return;
      }
    }
  }

  private async open(id: string, send: Send): Promise<void> {
    const api = this.api();
    if (!api) {
      send({ type: "voice_error", in_reply_to: id, code: "unavailable", message: "Pi Voice isn't loaded in this pane. Run /reload on the Mac." });
      return;
    }
    try {
      const s = await api.openRemote();
      this.session = { origin: s.origin, token: s.token };
      send({ type: "voice_opened", in_reply_to: id, label: s.label ?? "", rate_per_minute: s.ratePerMinute ?? 0.05 });
    } catch (err) {
      const e = err as { code?: string; message?: string };
      send({ type: "voice_error", in_reply_to: id, code: e.code ?? "unavailable", message: e.message ?? String(err) });
    }
  }

  async rpc(path: string, body: unknown): Promise<{ status: number; body: unknown }> {
    const cap = ALLOWED[path];
    if (cap === undefined) return { status: 403, body: { error: "Not available from the phone" } };
    const s = this.session;
    if (!s) return { status: 409, body: { error: "No voice session. Start one from the phone." } };
    const json = JSON.stringify(body ?? {});
    if (json.length > cap) return { status: 413, body: { error: "Request too large" } };
    let res: Response;
    try {
      res = await this.fetchFn(s.origin + path, {
        method: "POST",
        headers: { Authorization: `Bearer ${s.token}`, Origin: s.origin, "Content-Type": "application/json" },
        body: json,
        signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
      });
    } catch {
      // The Pi Voice server is gone: session stopped on the Mac, watchdog, reload.
      this.session = null;
      return { status: 410, body: { error: "Voice session ended on the Mac" } };
    }
    const text = await res.text();
    if (text.length > MAX_REPLY_BYTES) return { status: 413, body: { error: "Reply too large for the relay" } };
    let parsed: unknown;
    try {
      parsed = text ? JSON.parse(text) : {};
    } catch {
      parsed = { error: "Invalid reply from Pi Voice" };
    }
    if (path === "/stop") this.session = null;
    return { status: res.status, body: parsed };
  }
}
