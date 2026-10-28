import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AttachmentBridge, FILE_CHUNK_SIZE, FILE_MAX_SIZE, FILE_TTL_MS, describe as describeFile, safeName, type Delivered, type FileServerMessage } from "./attachments.js";

const cleanups: Array<() => Promise<unknown> | void> = [];
afterEach(async () => { for (const clean of cleanups.splice(0).reverse()) await clean(); });

async function setup(opts: { deliver?: (f: Delivered) => Promise<void> | void; onAuthorize?: () => void } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "rp-attachments-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  const sender = {}, other = {};
  let paired = true;
  const delivered: Delivered[] = [];
  let now = 1_000_000;
  const bridge = new AttachmentBridge({
    dir, now: () => now,
    authorize: async (owner, s) => { opts.onAuthorize?.(); return owner === "owner" && s === sender && paired; },
    deliver: async (f) => { delivered.push(f); await opts.deliver?.(f); },
  });
  cleanups.push(() => bridge.stop());
  const video = Buffer.concat([Buffer.alloc(FILE_CHUNK_SIZE, 7), Buffer.alloc(1234, 9)]);
  const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
  async function open(over: Record<string, unknown> = {}, bytes = video) {
    return bridge.handle("owner", sender, { type: "file_open", id: "open", name: "clip.mov", mime: "video/quicktime", size: bytes.length, sha256: sha(bytes), duration_ms: 4200, text: "look at this", ...over } as never);
  }
  async function opened(over: Record<string, unknown> = {}, bytes = video) {
    const r = await open(over, bytes); expect(r.type).toBe("file_opened");
    return (r as Extract<FileServerMessage, { type: "file_opened" }>).transfer_id;
  }
  async function upload(transfer_id: string, bytes = video) {
    for (let offset = 0; offset < bytes.length; offset += FILE_CHUNK_SIZE) {
      const r = await bridge.handle("owner", sender, { type: "file_chunk", id: `c${offset}`, transfer_id, offset, data: bytes.subarray(offset, offset + FILE_CHUNK_SIZE).toString("base64") });
      expect(r).toMatchObject({ type: "file_ack", transfer_id, offset: Math.min(offset + FILE_CHUNK_SIZE, bytes.length) });
    }
    return bridge.handle("owner", sender, { type: "file_close", id: "msg-1", transfer_id });
  }
  return { dir, bridge, sender, other, video, sha, open, opened, upload, delivered, unpair: () => { paired = false; }, advance: (ms: number) => { now += ms; } };
}
const isError = (r: FileServerMessage, code: string) => expect(r).toMatchObject({ type: "file_error", code });

describe("phone → Mac attachments", () => {
  it("a session reset while the finished file is being moved into place delivers nothing and leaves no file", async () => {
    let calls = -1;
    const s = await setup({ onAuthorize: () => { if (calls >= 0 && ++calls === 3) void s.bridge.reset(); } });
    const id = await s.opened();
    const bytes = s.video;
    for (let offset = 0; offset < bytes.length; offset += FILE_CHUNK_SIZE) {
      await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: `c${offset}`, transfer_id: id, offset, data: bytes.subarray(offset, offset + FILE_CHUNK_SIZE).toString("base64") });
    }
    calls = 0; // close: 1 = request start, 2 = before rename, 3 = after rename/chmod (reset lands here)
    isError(await s.bridge.handle("owner", s.sender, { type: "file_close", id: "msg-1", transfer_id: id }), "not_paired");
    expect(calls).toBe(3);
    expect(s.delivered).toEqual([]);
    expect(await readdir(s.dir)).toEqual([]);
  });
  it("writes a hash-verified private file and delivers path + metadata as one message", async () => {
    const s = await setup();
    const id = await s.opened();
    const done = await s.upload(id);
    expect(done).toMatchObject({ type: "file_done", in_reply_to: "msg-1", transfer_id: id });
    const path = (done as Extract<FileServerMessage, { type: "file_done" }>).path;
    expect(path.startsWith(s.dir)).toBe(true);
    expect(path.endsWith("-clip.mov")).toBe(true);
    expect(await readFile(path)).toEqual(s.video);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect((await stat(s.dir)).mode & 0o777).toBe(0o700);
    expect(s.delivered).toEqual([{ id: "msg-1", owner: "owner", path, name: "clip.mov", mime: "video/quicktime", size: s.video.length, duration_ms: 4200, text: "look at this", steer: false }]);
    const note = describeFile(s.delivered[0]);
    expect(note).toContain(path); expect(note).toContain("0:04 long"); expect(note).toContain("nothing has been viewed");
    expect(await readdir(s.dir)).toEqual([path.slice(s.dir.length + 1)]);
    isError(await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "late", transfer_id: id, offset: 0, data: "AA==" }), "unavailable");
  });
  it("refuses out-of-order, oversized and over-cap chunks and deletes the partial file", async () => {
    const s = await setup();
    const id = await s.opened();
    isError(await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "skip", transfer_id: id, offset: 10, data: "AA==" }), "invalid");
    expect(await readdir(s.dir)).toEqual([]);
    const id2 = await s.opened();
    isError(await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "big", transfer_id: id2, offset: 0, data: Buffer.alloc(FILE_CHUNK_SIZE + 1).toString("base64") }), "unavailable");
    const id3 = await s.opened({ size: 3 });
    isError(await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "over", transfer_id: id3, offset: 0, data: "AAAAAA==" }), "invalid");
    expect(s.delivered).toEqual([]);
  });
  it("fails closed on a wrong hash, a short upload, the size cap and bad metadata", async () => {
    const s = await setup();
    isError(await s.open({ size: FILE_MAX_SIZE + 1 }), "too_large");
    isError(await s.open({ sha256: "nope" }), "invalid");
    isError(await s.open({ mime: "not a mime" }), "invalid");
    isError(await s.open({ size: 0 }), "invalid");
    const short = await s.opened();
    isError(await s.bridge.handle("owner", s.sender, { type: "file_close", id: "early", transfer_id: short }), "invalid");
    const wrong = await s.opened({ sha256: s.sha(Buffer.from("other")) });
    isError(await s.upload(wrong), "integrity");
    expect(s.delivered).toEqual([]);
    expect(await readdir(s.dir)).toEqual([]);
  });
  it("binds a transfer to its owner, sender and session generation, and allows one per owner", async () => {
    const s = await setup();
    const id = await s.opened();
    isError(await s.bridge.handle("owner", s.other, { type: "file_chunk", id: "x", transfer_id: id, offset: 0, data: "AA==" }), "not_paired");
    isError(await s.bridge.handle("intruder", s.sender, { type: "file_chunk", id: "x", transfer_id: id, offset: 0, data: "AA==" }), "not_paired");
    isError(await s.open(), "busy");
    await s.bridge.reset();
    isError(await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "stale", transfer_id: id, offset: 0, data: "AA==" }), "unavailable");
    expect(await readdir(s.dir)).toEqual([]);
    const again = await s.opened();
    await s.bridge.detach("owner");
    isError(await s.bridge.handle("owner", s.sender, { type: "file_close", id: "gone", transfer_id: again }), "unavailable");
    s.unpair();
    isError(await s.open(), "not_paired");
  });
  it("cancel drops the partial file, and a refused delivery removes the finished file", async () => {
    const s = await setup({ deliver: () => { throw new Error("agent not bound"); } });
    const id = await s.opened();
    await s.bridge.handle("owner", s.sender, { type: "file_chunk", id: "c", transfer_id: id, offset: 0, data: s.video.subarray(0, FILE_CHUNK_SIZE).toString("base64") });
    isError(await s.bridge.handle("owner", s.sender, { type: "file_cancel", id: "stop", transfer_id: id }), "cancelled");
    expect(await readdir(s.dir)).toEqual([]);
    const id2 = await s.opened();
    isError(await s.upload(id2), "unavailable");
    expect(await readdir(s.dir)).toEqual([]);
  });
  it("sweeps expired attachments and abandoned partials, keeping fresh ones", async () => {
    const s = await setup();
    const old = join(s.dir, "old-clip.mov"), fresh = join(s.dir, "fresh.mov"), part = join(s.dir, "x.part");
    await writeFile(old, "a"); await writeFile(fresh, "b"); await writeFile(part, "c");
    const ago = (ms: number) => new Date(1_000_000 - ms);
    await utimes(old, ago(FILE_TTL_MS + 1000), ago(FILE_TTL_MS + 1000));
    await utimes(part, ago(60 * 60 * 1000), ago(60 * 60 * 1000));
    await utimes(fresh, ago(1000), ago(1000));
    await s.bridge.sweep();
    expect((await readdir(s.dir)).sort()).toEqual(["fresh.mov"]);
  });
  it("sanitises names and keeps the message id, caption and steer flag", async () => {
    expect(safeName("../../etc/passwd")).toBe("etcpasswd");
    expect(safeName(".hidden\u0000.mov")).toBe("hidden.mov");
    expect(safeName("")).toBe("attachment");
    expect(safeName(`${"a".repeat(300)}.mp4`)).toHaveLength(120);
    const s = await setup();
    const id = await s.opened({ name: "my movie/2026:final.MOV", text: "x\u0007y", streaming_behavior: "steer", duration_ms: -5 });
    const done = await s.upload(id);
    expect(done.type).toBe("file_done");
    expect(s.delivered[0]).toMatchObject({ name: "my movie2026final.MOV", text: "xy", steer: true, duration_ms: undefined });
  });
});
