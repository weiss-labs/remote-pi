import { createHash, randomUUID } from "node:crypto";
import { constants, type BigIntStats } from "node:fs";
import { open, realpath, stat, type FileHandle } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, extname, isAbsolute, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
type ReadonlySessionManager = ExtensionContext["sessionManager"];

export const ARTIFACT_MAX_SIZE = 20 * 1024 * 1024;
export const ARTIFACT_CHUNK_SIZE = 192 * 1024;
const TTL = 120000;
export type ArtifactClientMessage =
  | { type: "artifact_open"; id: string; url: string }
  | { type: "artifact_chunk"; id: string; transfer_id: string; offset: number }
  | { type: "artifact_close"; id: string; transfer_id: string };
export type ArtifactServerMessage =
  | { type: "artifact_opened"; in_reply_to: string; transfer_id: string; name: string; mime: string; size: number; sha256: string }
  | { type: "artifact_chunk"; in_reply_to: string; transfer_id: string; offset: number; data: string; eof: boolean }
  | { type: "artifact_error"; in_reply_to: string; code: string; message: string };
interface Dependencies {
  authorize(owner: string, sender: object): Promise<boolean>;
  session(): ReadonlySessionManager | null;
  /** Only tests override roots. Production uses the fixed approved roots. */
  roots?: readonly string[];
}
interface Transfer {
  owner: string; sender: object; generation: number; session: string; url: string;
  file: FileHandle; path: string; stamp: BigIntStats; size: number;
  expires: number; timer: ReturnType<typeof setTimeout>; busy: boolean;
}
class Refused extends Error {}
function requireSafe(value: unknown): asserts value { if (!value) throw new Refused(); }
function safePath(path: string): boolean {
  return isAbsolute(path) && !/[\p{Cc}\p{Cf}]/u.test(path) && path.split(sep).every(part => !part.startsWith(".") &&
    !/(?:^|[._ -])(?:secrets?|credentials?|passwords?|tokens?|api[-_ ]?keys?|private[-_ ]?keys?|auth(?:key)?|oauth|service[-_ ]?account|keychain|keyring|keystore|id_rsa|id_dsa|id_ecdsa|id_ed25519|authorized_keys|passwd|shadow|netrc|npmrc|config|settings|git|env)(?:[._ -]|$)/i.test(part)) &&
    !/\.(?:pem|key|p12|pfx|keystore)$/i.test(path);
}
function inside(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}
function same(a: BigIntStats, b: BigIntStats): boolean {
  return a.isFile() && b.isFile() && a.dev === b.dev && a.ino === b.ino && a.size === b.size &&
    a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs && b.nlink === 1n;
}
function mimeFor(path: string, b: Buffer): string | null {
  switch (extname(path).toLowerCase()) {
    case ".pdf": return b.subarray(0, 5).toString("ascii") === "%PDF-" ? "application/pdf" : null;
    case ".png": return b.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) && b.subarray(12,16).toString("ascii") === "IHDR" ? "image/png" : null;
    case ".jpg": case ".jpeg": return b[0] === 255 && b[1] === 216 && b[2] === 255 ? "image/jpeg" : null;
    case ".gif": return ["GIF87a", "GIF89a"].includes(b.subarray(0,6).toString("ascii")) ? "image/gif" : null;
    case ".webp": return b.subarray(0,4).toString("ascii") === "RIFF" && b.subarray(8,12).toString("ascii") === "WEBP" && ["VP8 ","VP8L","VP8X"].includes(b.subarray(12,16).toString("ascii")) ? "image/webp" : null;
    default: return null;
  }
}
/** Only text in authoritative active-branch assistant messages grants a URL. */
export function assistantLinked(manager: ReadonlySessionManager, url: string): boolean {
  const branch = manager.getBranch();
  requireSafe(Array.isArray(branch) && branch.length <= 20000);
  return branch.some(entry => entry.type === "message" && entry.message.role === "assistant" &&
    Array.isArray(entry.message.content) && entry.message.content.some(block => {
      if (block.type !== "text" || block.text.length > 2 * 1024 * 1024) return false;
      return [...block.text.matchAll(/file:\/\/[^\s<>\x00-\x1f\x7f\x22'`\]\)]+/g)].some(match => match[0] === url);
    }));
}
/** Filesystem requests never enter the agent, shell, or HTTP fetch path. */
export class ArtifactBridge {
  private generation = 0;
  private transfers = new Map<string, Transfer>();
  private pending = new Map<string, number>();
  private totalPending = 0;
  constructor(private readonly deps: Dependencies) {}
  private close(id: string): void {
    const t = this.transfers.get(id);
    if (!t) return;
    this.transfers.delete(id); clearTimeout(t.timer); void t.file.close().catch(() => {});
  }
  reset(): void { this.generation++; for (const id of this.transfers.keys()) this.close(id); }
  detach(owner: string): void {
    for (const [id, t] of this.transfers) if (t.owner === owner) this.close(id);
  }
  private authority(url: string, generation: number, session?: string): ReadonlySessionManager {
    const manager = this.deps.session();
    requireSafe(generation === this.generation && manager && typeof manager.getBranch === "function" &&
      typeof manager.getSessionId === "function" && (!session || session === manager.getSessionId()) && assistantLinked(manager, url));
    return manager;
  }
  private async validate(t: Transfer): Promise<void> {
    this.authority(t.url, t.generation, t.session);
    requireSafe(t.expires > Date.now() && await realpath(fileURLToPath(t.url)) === t.path &&
      same(t.stamp, await t.file.stat({ bigint: true })) && same(t.stamp, await stat(t.path, { bigint: true })));
  }
  async handle(owner: string, sender: object, msg: ArtifactClientMessage): Promise<ArtifactServerMessage | null> {
    const id = typeof msg.id === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(msg.id) ? msg.id : "";
    const fail = (): ArtifactServerMessage => ({ type: "artifact_error", in_reply_to: id, code: "unavailable", message: "This linked preview is unavailable. Refresh the pane and try again." });
    const generation = this.generation;
    let file: FileHandle | undefined;
    let reading: Transfer | undefined;
    let acquired = false;
    try {
      requireSafe(id && (this.pending.get(owner) ?? 0) < 2 && this.totalPending < 16);
      this.pending.set(owner, (this.pending.get(owner) ?? 0) + 1); this.totalPending++; acquired = true;
      requireSafe(await this.deps.authorize(owner, sender) && generation === this.generation);
      if (msg.type === "artifact_open") {
        requireSafe(typeof msg.url === "string" && msg.url.length <= 8192);
        const manager = this.authority(msg.url, generation);
        const session = manager.getSessionId();
        requireSafe(this.transfers.size + this.totalPending <= 32 && [...this.transfers.values()].filter(t => t.owner === owner).length + (this.pending.get(owner) ?? 0) <= 4);
        const url = new URL(msg.url);
        requireSafe(url.protocol === "file:" && (!url.hostname || url.hostname === "localhost") && !url.search && !url.hash && !url.username && !url.password);
        const raw = fileURLToPath(url);
        requireSafe(safePath(raw));
        const path = await realpath(raw);
        requireSafe(safePath(path));
        const roots = this.deps.roots ?? [join(homedir(), "Documents/programs"), join(homedir(), "Downloads"), tmpdir(), "/tmp"];
        const resolvedRoots = await Promise.all(roots.map(root => realpath(root).catch(() => "")));
        requireSafe(resolvedRoots.some(root => root && inside(root, path)));
        // O_NONBLOCK prevents a replaced FIFO from hanging the process before fstat.
        file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        const stamp = await file.stat({ bigint: true });
        requireSafe(stamp.isFile() && stamp.nlink === 1n && stamp.size > 0n && stamp.size <= BigInt(ARTIFACT_MAX_SIZE));
        const size = Number(stamp.size);
        const header = Buffer.alloc(Math.min(32, size));
        await file.read(header, 0, header.length, 0);
        const mime = mimeFor(path, header); requireSafe(mime);
        const hash = createHash("sha256"), buffer = Buffer.alloc(ARTIFACT_CHUNK_SIZE);
        for (let offset = 0; offset < size;) {
          this.authority(msg.url, generation, session);
          const { bytesRead } = await file.read(buffer, 0, Math.min(buffer.length, size - offset), offset);
          requireSafe(bytesRead > 0); hash.update(buffer.subarray(0, bytesRead)); offset += bytesRead;
        }
        requireSafe(await this.deps.authorize(owner, sender));
        this.authority(msg.url, generation, session);
        requireSafe(await realpath(raw) === path && same(stamp, await file.stat({ bigint: true })) && same(stamp, await stat(path, { bigint: true })));
        requireSafe(await this.deps.authorize(owner, sender));
        this.authority(msg.url, generation, session);
        const transfer_id = randomUUID();
        const timer = setTimeout(() => this.close(transfer_id), TTL); timer.unref();
        this.transfers.set(transfer_id, { owner, sender, generation, session, url: msg.url, file, path, stamp, size, expires: Date.now() + TTL, timer, busy: false });
        file = undefined;
        return { type: "artifact_opened", in_reply_to: id, transfer_id, name: basename(path).replace(/[\p{Cc}\p{Cf}]/gu, "").slice(0,180), mime, size, sha256: hash.digest("hex") };
      }
      requireSafe(typeof msg.transfer_id === "string");
      const t = this.transfers.get(msg.transfer_id);
      requireSafe(t && t.owner === owner && t.sender === sender && t.generation === generation);
      if (msg.type === "artifact_close") { this.close(msg.transfer_id); return null; }
      requireSafe(!t.busy); t.busy = true; reading = t;
      await this.validate(t);
      requireSafe(Number.isSafeInteger(msg.offset) && msg.offset >= 0 && msg.offset < t.size);
      const data = Buffer.alloc(Math.min(ARTIFACT_CHUNK_SIZE, t.size - msg.offset));
      const { bytesRead } = await t.file.read(data, 0, data.length, msg.offset);
      requireSafe(bytesRead === data.length && this.transfers.get(msg.transfer_id) === t && await this.deps.authorize(owner, sender));
      await this.validate(t);
      requireSafe(this.transfers.get(msg.transfer_id) === t);
      return { type: "artifact_chunk", in_reply_to: id, transfer_id: msg.transfer_id, offset: msg.offset, data: data.toString("base64"), eof: msg.offset + bytesRead === t.size };
    } catch {
      if (reading && "transfer_id" in msg) this.close(msg.transfer_id);
      return fail();
    } finally {
      if (reading) reading.busy = false;
      if (file) await file.close().catch(() => {});
      if (acquired) {
        const count = (this.pending.get(owner) ?? 1) - 1;
        if (count) this.pending.set(owner, count); else this.pending.delete(owner);
        this.totalPending--;
      }
    }
  }
}
