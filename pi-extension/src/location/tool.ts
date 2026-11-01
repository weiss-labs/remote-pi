import { Type } from "typebox";
import { randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, readdir, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { describeFix, LocationBridge, MAX_PURPOSE, type LocationFix } from "./bridge.js";

export const parameters = Type.Object({
  purpose: Type.String({ maxLength: MAX_PURPOSE, description: "One short phrase shown on the phone, e.g. 'find a nearby minyan'." }),
});

export const FIX_TTL_MS = 15 * 60_000;
const DIR = join(homedir(), ".pi", "remote", "location");
const mine = new Set<string>();

/** Deletes expired `loc-*` files, including ones left by a Pi that exited early. Never reads them. */
export async function sweepFixes(dir = DIR, now = Date.now()): Promise<void> {
  let names: string[];
  try { names = await readdir(dir); } catch { return; }
  for (const name of names) {
    if (!name.startsWith("loc-")) continue;
    const path = join(dir, name);
    try { const st = await lstat(path); if (now - st.mtimeMs >= FIX_TTL_MS) await unlink(path); } catch { /* already gone */ }
  }
}

/**
 * The coordinates never enter the model's context: the chat channel to the phone
 * is relay-readable, so anything the model sees it could echo. They go to a
 * private 0600 file the calling script reads (e.g. `mincha.py --at-file`).
 */
export async function writeFix(fix: LocationFix, dir = DIR): Promise<string> {
  await sweepFixes(dir);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const st = await lstat(dir);
  if (!st.isDirectory() || st.isSymbolicLink()) throw new Error("Location directory is not a private directory.");
  await chmod(dir, 0o700);
  const path = join(dir, `loc-${randomBytes(16).toString("hex")}`);
  const fh = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { await fh.writeFile(`${fix.lat},${fix.lng}\n`); } finally { await fh.close(); }
  mine.add(path);
  setTimeout(() => { mine.delete(path); void unlink(path).catch(() => {}); }, FIX_TTL_MS).unref();
  return path;
}

/** This process's files go when its session ends. */
export async function forgetFixes(): Promise<void> {
  await Promise.all([...mine].map(path => unlink(path).catch(() => {})));
  mine.clear();
}

export function registerLocationTool(pi: ExtensionAPI, bridge: LocationBridge): void {
  void sweepFixes();
  pi.on("session_shutdown", () => forgetFixes());
  pi.registerTool({
    name: "request_location",
    label: "Request phone location",
    description: "Get ONE fresh location fix from the paired phone for a nearby request the user just made (e.g. 'find me a minyan', 'what's near me'). Only call it for such an explicit nearby ask, never to track or speculatively. Works only if the user turned on 'Share location when a pane asks' in the phone app and Remote Pi is open there; waits up to 20 s. On success it returns a private file path holding the coordinates (you never see them): pass that path to the script that needs it, e.g. `mincha.py --at-file PATH`, and say 'near you'. On any error it fails with the reason: then use the home location and label it as home, never as the user's live location. Do not retry automatically after an error.",
    parameters,
    execute: async (_id, args, signal) => {
      const fix = await bridge.request(args, signal);
      const path = await writeFix(fix);
      return { content: [{ type: "text", text: `${describeFix(fix)}. Coordinates saved to ${path} (private, deleted after 15 min); pass this path, e.g. --at-file ${path}.` }], details: {} };
    },
  });
}
