// Plan/74 — phone → Mac file attachments (video, pasted files, Share sheet).
// The mirror of `artifacts.ts`: bounded sequential chunks over the paired
// channel into a private 0600 file under ~/.pi/remote/attachments (0700).
// The whole file is hash-verified before the agent hears about it, and the
// agent only ever gets the local path plus name/type/size/duration: no claim
// that a model watched the video. Stale rooms, foreign senders, out-of-order
// offsets, oversized chunks and idle transfers fail closed and delete the
// partial file.
import { createHash, randomUUID, type Hash } from "node:crypto";
import { constants } from "node:fs";
import { chmod, mkdir, open, readdir, rename, stat, unlink, type FileHandle } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join } from "node:path";

export const FILE_MAX_SIZE = 200 * 1024 * 1024;
export const FILE_CHUNK_SIZE = 192 * 1024;
/** Idle time between chunks before a partial upload is dropped. */
export const TRANSFER_IDLE_MS = 10 * 60 * 1000;
/** Completed attachments are swept after this age, like credential files but long enough for a working session. */
export const FILE_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_NAME = 120;
const MAX_TEXT = 20000;

export type FileClientMessage =
  | { type: "file_open"; id: string; name: string; mime: string; size: number; sha256: string; duration_ms?: number; text?: string; streaming_behavior?: "steer" }
  | { type: "file_chunk"; id: string; transfer_id: string; offset: number; data: string }
  | { type: "file_close"; id: string; transfer_id: string }
  | { type: "file_cancel"; id: string; transfer_id: string };
export type FileServerMessage =
  | { type: "file_opened"; in_reply_to: string; transfer_id: string }
  | { type: "file_ack"; in_reply_to: string; transfer_id: string; offset: number }
  | { type: "file_done"; in_reply_to: string; transfer_id: string; path: string }
  | { type: "file_error"; in_reply_to: string; code: string; message: string };

export interface Delivered {
  id: string; owner: string; path: string; name: string; mime: string; size: number; duration_ms?: number; text: string; steer: boolean;
}
interface Dependencies {
  authorize(owner: string, sender: object): Promise<boolean>;
  /** Hand the finished private file to the pane. Throwing refuses the close; the file is deleted. */
  deliver(file: Delivered): Promise<void> | void;
  dir?: string;
  now?(): number;
}
interface Transfer {
  id: string; owner: string; sender: object; generation: number; name: string; mime: string; size: number; sha256: string;
  duration_ms?: number; text: string; steer: boolean; file: FileHandle; part: string; received: number; hash: Hash;
  timer: ReturnType<typeof setTimeout>; busy: boolean;
}
class Refused extends Error { constructor(readonly code = "unavailable", message = "This attachment transfer is unavailable. Try again.") { super(message); } }
function requireSafe(value: unknown, code?: string, message?: string): asserts value { if (!value) throw new Refused(code, message); }

/** Keep the extension, drop separators, control/format characters and leading dots. */
export function safeName(raw: unknown): string {
  const text = typeof raw === "string" ? raw.replace(/[\p{Cc}\p{Cf}\/\\:]/gu, "").trim().replace(/^\.+/, "") : "";
  const ext = extname(text).slice(0, 16);
  const base = text.slice(0, text.length - ext.length).replace(/\s+/g, " ").slice(0, MAX_NAME - ext.length) || "attachment";
  return `${base}${ext}`;
}
export function describe(file: Pick<Delivered, "path" | "name" | "mime" | "size" | "duration_ms">): string {
  const mb = file.size >= 1024 * 1024 ? `${(file.size / 1024 / 1024).toFixed(1)} MiB` : `${Math.ceil(file.size / 1024)} KiB`;
  const seconds = file.duration_ms && file.duration_ms > 0 ? Math.round(file.duration_ms / 1000) : null;
  const duration = seconds === null ? "" : `, ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")} long`;
  return `[Attached file from the phone, saved on this Mac at ${file.path} — ${file.name} (${file.mime}, ${mb}${duration}). ` +
    "This is a local path only: nothing has been viewed, transcribed or extracted. Read, inspect or process the file at that path as needed.]";
}

export class AttachmentBridge {
  private generation = 0;
  private transfers = new Map<string, Transfer>();
  private pending = new Map<string, number>();
  private sweeper: ReturnType<typeof setInterval> | null = null;
  constructor(private readonly deps: Dependencies) {}
  private now(): number { return this.deps.now?.() ?? Date.now(); }
  dir(): string { return this.deps.dir ?? join(homedir(), ".pi", "remote", "attachments"); }

  /** Idempotent: ensure the private directory and start the hourly TTL sweep. */
  start(): void {
    void this.sweep();
    if (!this.sweeper) { this.sweeper = setInterval(() => void this.sweep(), 60 * 60 * 1000); this.sweeper.unref(); }
  }
  stop(): void {
    if (this.sweeper) { clearInterval(this.sweeper); this.sweeper = null; }
    this.reset();
  }
  /** Session changed: every in-flight upload is stale. Finished files stay until the TTL sweep. */
  reset(): Promise<void> { this.generation++; return this.dropAll(() => true); }
  detach(owner: string): Promise<void> { return this.dropAll(t => t.owner === owner); }
  private async dropAll(match: (t: Transfer) => boolean): Promise<void> {
    await Promise.all([...this.transfers.values()].filter(match).map(t => this.drop(t.id)));
  }

  async sweep(): Promise<void> {
    const dir = this.dir();
    try {
      await mkdir(dir, { recursive: true, mode: 0o700 });
      await chmod(dir, 0o700);
      const live = new Set([...this.transfers.values()].map(t => t.part));
      for (const entry of await readdir(dir)) {
        const path = join(dir, entry);
        if (live.has(path)) continue;
        try {
          const info = await stat(path);
          if (!info.isFile()) continue;
          const age = this.now() - info.mtimeMs;
          if (age > FILE_TTL_MS || (entry.endsWith(".part") && age > TRANSFER_IDLE_MS)) await unlink(path);
        } catch { /* already gone */ }
      }
    } catch { /* a missing home dir is reported when a transfer starts */ }
  }

  private async drop(id: string): Promise<void> {
    const t = this.transfers.get(id);
    if (!t) return;
    this.transfers.delete(id); clearTimeout(t.timer);
    await t.file.close().catch(() => {});
    await unlink(t.part).catch(() => {});
  }
  private touch(t: Transfer): void {
    clearTimeout(t.timer);
    t.timer = setTimeout(() => void this.drop(t.id), TRANSFER_IDLE_MS); t.timer.unref();
  }
  private current(msg: { transfer_id?: unknown }, owner: string, sender: object, generation: number): Transfer {
    requireSafe(typeof msg.transfer_id === "string");
    const t = this.transfers.get(msg.transfer_id);
    requireSafe(t && t.owner === owner && t.sender === sender && t.generation === generation && !t.busy);
    return t;
  }

  async handle(owner: string, sender: object, msg: FileClientMessage): Promise<FileServerMessage> {
    const id = typeof msg.id === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(msg.id) ? msg.id : "";
    const generation = this.generation;
    let locked: Transfer | undefined;
    let acquired = false;
    try {
      requireSafe(id && (this.pending.get(owner) ?? 0) < 2);
      this.pending.set(owner, (this.pending.get(owner) ?? 0) + 1); acquired = true;
      requireSafe(await this.deps.authorize(owner, sender) && generation === this.generation, "not_paired", "An active paired pane is required.");
      if (msg.type === "file_open") {
        requireSafe([...this.transfers.values()].every(t => t.owner !== owner), "busy", "Another attachment is still uploading to this pane.");
        requireSafe(this.transfers.size < 4, "busy", "Too many attachments are uploading right now.");
        requireSafe(Number.isSafeInteger(msg.size) && msg.size > 0, "invalid", "Empty attachment.");
        requireSafe(msg.size <= FILE_MAX_SIZE, "too_large", `Attachments are limited to ${FILE_MAX_SIZE / 1024 / 1024} MiB.`);
        requireSafe(typeof msg.sha256 === "string" && /^[a-f0-9]{64}$/.test(msg.sha256), "invalid", "Missing attachment checksum.");
        requireSafe(typeof msg.mime === "string" && /^[a-z0-9!#$&^_.+-]{1,64}\/[a-z0-9!#$&^_.+-]{1,96}$/i.test(msg.mime), "invalid", "Invalid attachment type.");
        const text = typeof msg.text === "string" ? msg.text.replace(/[\p{Cc}]/gu, c => (c === "\n" || c === "\t" ? c : "")).slice(0, MAX_TEXT) : "";
        const duration_ms = Number.isSafeInteger(msg.duration_ms) && (msg.duration_ms as number) > 0 ? msg.duration_ms : undefined;
        const dir = this.dir();
        await mkdir(dir, { recursive: true, mode: 0o700 });
        await chmod(dir, 0o700);
        const transfer_id = randomUUID();
        const part = join(dir, `${transfer_id}.part`);
        const file = await open(part, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        const t: Transfer = {
          id: transfer_id, owner, sender, generation, name: safeName(msg.name), mime: msg.mime.toLowerCase(), size: msg.size, sha256: msg.sha256,
          duration_ms, text, steer: msg.streaming_behavior === "steer", file, part, received: 0, hash: createHash("sha256"),
          timer: setTimeout(() => {}, 0), busy: false,
        };
        this.transfers.set(transfer_id, t); this.touch(t);
        return { type: "file_opened", in_reply_to: id, transfer_id };
      }
      const t = this.current(msg, owner, sender, generation);
      if (msg.type === "file_cancel") { await this.drop(t.id); return { type: "file_error", in_reply_to: id, code: "cancelled", message: "Attachment cancelled." }; }
      t.busy = true; locked = t;
      if (msg.type === "file_chunk") {
        requireSafe(msg.offset === t.received, "invalid", "Attachment chunk out of order.");
        requireSafe(typeof msg.data === "string" && msg.data.length <= Math.ceil(FILE_CHUNK_SIZE / 3) * 4 && /^[A-Za-z0-9+/]*={0,2}$/.test(msg.data));
        const bytes = Buffer.from(msg.data, "base64");
        requireSafe(bytes.length > 0 && bytes.length <= FILE_CHUNK_SIZE && t.received + bytes.length <= t.size, "invalid", "Attachment chunk out of bounds.");
        const { bytesWritten } = await t.file.write(bytes, 0, bytes.length, t.received);
        requireSafe(bytesWritten === bytes.length && this.transfers.get(t.id) === t);
        t.hash.update(bytes); t.received += bytes.length; this.touch(t);
        return { type: "file_ack", in_reply_to: id, transfer_id: t.id, offset: t.received };
      }
      // file_close: verify, move into place, deliver.
      requireSafe(t.received === t.size, "invalid", "Attachment is incomplete.");
      requireSafe(t.hash.digest("hex") === t.sha256, "integrity", "Attachment integrity check failed. Nothing was delivered.");
      await t.file.sync().catch(() => {});
      requireSafe(await this.deps.authorize(owner, sender) && generation === this.generation && this.transfers.get(t.id) === t, "not_paired", "An active paired pane is required.");
      const path = join(this.dir(), `${t.id.slice(0, 8)}-${t.name}`);
      await rename(t.part, path);
      t.part = path;
      await chmod(path, 0o600);
      // The rename/chmod yielded: a session reset or detach meanwhile makes this upload
      // stale. The reset may already have dropped the transfer, so delete the renamed file here.
      if (!(await this.deps.authorize(owner, sender) && generation === this.generation && this.transfers.get(t.id) === t)) {
        await unlink(path).catch(() => {});
        throw new Refused("not_paired", "An active paired pane is required.");
      }
      await this.deps.deliver({ id, owner, path, name: t.name, mime: t.mime, size: t.size, duration_ms: t.duration_ms, text: t.text, steer: t.steer });
      this.transfers.delete(t.id); clearTimeout(t.timer); await t.file.close().catch(() => {});
      return { type: "file_done", in_reply_to: id, transfer_id: t.id, path };
    } catch (error) {
      if (locked) await this.drop(locked.id);
      const refused = error instanceof Refused ? error : new Refused();
      return { type: "file_error", in_reply_to: id, code: refused.code, message: refused.message };
    } finally {
      if (locked) locked.busy = false;
      if (acquired) {
        const count = (this.pending.get(owner) ?? 1) - 1;
        if (count) this.pending.set(owner, count); else this.pending.delete(owner);
      }
    }
  }
}
