// Private credential handoff — cross-language primitives (mirror of
// app/lib/data/credentials/credential_crypto.dart). Standard Node crypto only:
// Ed25519 (existing paired identities), X25519 ephemeral ECDH, HKDF-SHA256,
// AES-256-GCM. Canonical byte strings are ordered JSON arrays after a
// domain-separation line, never object key order.
import { createCipheriv, createDecipheriv, createHash, createPrivateKey, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, timingSafeEqual } from "node:crypto";
import { ed25519Sign, ed25519Verify } from "../pairing/crypto.js";

export const REQUEST_DOMAIN = "remote-pi-credential-request-v1\n";
export const RESPONSE_DOMAIN = "remote-pi-credential-response-v1\n";
export const HKDF_SALT = Buffer.from("remote-pi-credential-v1-salt", "utf8");
export const HKDF_INFO_PREFIX = "remote-pi-credential-v1-key\n";
export const MAX_SECRET_BYTES = 16 * 1024;
export const NONCE_BYTES = 12;
export const TAG_BYTES = 16;

export interface CredentialRequestFields {
  mac_key: string;     // paired Mac Ed25519 public key, base64 std
  room: string;
  session: string;     // per-session nonce (regenerated on every session start)
  id: string;          // request id
  expires_at: number;  // epoch ms
  label: string;
  reference: string;   // "1Password → vault → item → field" or op://…
  purpose: string;
  mac_epk: string;     // ephemeral X25519 public key (raw 32B, base64 std)
}

export interface CredentialResponseFields {
  id: string;
  phone_key: string;   // paired phone Owner Ed25519 public key, base64 std
  phone_epk: string;   // phone ephemeral X25519 public key, base64 std
  nonce: string;       // 12B base64
  ciphertext: string;  // AES-256-GCM ciphertext || 16B tag, base64
}

/** Signed request bytes; also the AES-GCM associated data. */
export function canonicalRequest(r: CredentialRequestFields): Buffer {
  return Buffer.from(REQUEST_DOMAIN + JSON.stringify([r.mac_key, r.room, r.session, r.id, r.expires_at, r.label, r.reference, r.purpose, r.mac_epk]), "utf8");
}

/** Signed response bytes. `request_hash` binds the exact canonical request. */
export function canonicalResponse(requestHash: Buffer, r: CredentialResponseFields, macEpk: string): Buffer {
  return Buffer.from(RESPONSE_DOMAIN + JSON.stringify([requestHash.toString("base64"), r.id, r.phone_key, macEpk, r.phone_epk, r.nonce, r.ciphertext]), "utf8");
}

export function sha256(data: Buffer): Buffer { return createHash("sha256").update(data).digest(); }

export function signRequest(macSecretKey: Uint8Array, r: CredentialRequestFields): string {
  return Buffer.from(ed25519Sign(macSecretKey, canonicalRequest(r))).toString("base64");
}
export function verifyRequest(macPublicKey: Uint8Array, r: CredentialRequestFields, sig: string): boolean {
  try { return ed25519Verify(macPublicKey, canonicalRequest(r), Buffer.from(sig, "base64")); } catch { return false; }
}
export function signResponse(phoneSecretKey: Uint8Array, request: CredentialRequestFields, r: CredentialResponseFields): string {
  return Buffer.from(ed25519Sign(phoneSecretKey, canonicalResponse(sha256(canonicalRequest(request)), r, request.mac_epk))).toString("base64");
}
export function verifyResponse(phonePublicKey: Uint8Array, request: CredentialRequestFields, r: CredentialResponseFields, sig: string): boolean {
  try { return ed25519Verify(phonePublicKey, canonicalResponse(sha256(canonicalRequest(request)), r, request.mac_epk), Buffer.from(sig, "base64")); } catch { return false; }
}

export interface X25519Keypair { publicKey: Buffer; secretKey: Buffer }
const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const X25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

export function generateX25519(): X25519Keypair {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  return {
    publicKey: Buffer.from(publicKey.export({ type: "spki", format: "der" })).subarray(X25519_SPKI_PREFIX.length),
    secretKey: Buffer.from(privateKey.export({ type: "pkcs8", format: "der" })).subarray(X25519_PKCS8_PREFIX.length),
  };
}
export function x25519FromSeed(seed: Buffer): X25519Keypair {
  const privateKey = createPrivateKey({ key: Buffer.concat([X25519_PKCS8_PREFIX, seed]), format: "der", type: "pkcs8" });
  return { publicKey: Buffer.from(createPublicKey(privateKey).export({ type: "spki", format: "der" })).subarray(X25519_SPKI_PREFIX.length), secretKey: Buffer.from(seed) };
}

/** HKDF-SHA256(ECDH(mine, theirs)) → 32B AES key, bound to both ephemerals and the request id. */
export function deriveKey(mine: X25519Keypair, theirPublic: Buffer, macEpk: string, phoneEpk: string, requestId: string): Buffer {
  if (theirPublic.length !== 32) throw new Error("bad ephemeral key");
  const shared = diffieHellman({
    privateKey: createPrivateKey({ key: Buffer.concat([X25519_PKCS8_PREFIX, mine.secretKey]), format: "der", type: "pkcs8" }),
    publicKey: createPublicKey({ key: Buffer.concat([X25519_SPKI_PREFIX, theirPublic]), format: "der", type: "spki" }),
  });
  if (shared.every(b => b === 0)) throw new Error("low-order ephemeral key");
  const info = Buffer.from(HKDF_INFO_PREFIX + JSON.stringify([macEpk, phoneEpk, requestId]), "utf8");
  return Buffer.from(hkdfSync("sha256", shared, HKDF_SALT, info, 32));
}

export function encrypt(key: Buffer, aad: Buffer, plaintext: Buffer, nonce = randomBytes(NONCE_BYTES)): { nonce: Buffer; ciphertext: Buffer } {
  const c = createCipheriv("aes-256-gcm", key, nonce);
  c.setAAD(aad);
  const body = Buffer.concat([c.update(plaintext), c.final()]);
  return { nonce, ciphertext: Buffer.concat([body, c.getAuthTag()]) };
}
export function decrypt(key: Buffer, aad: Buffer, nonce: Buffer, ciphertext: Buffer): Buffer {
  if (nonce.length !== NONCE_BYTES || ciphertext.length < TAG_BYTES || ciphertext.length > MAX_SECRET_BYTES + TAG_BYTES) throw new Error("bad ciphertext");
  const d = createDecipheriv("aes-256-gcm", key, nonce);
  d.setAAD(aad);
  d.setAuthTag(ciphertext.subarray(ciphertext.length - TAG_BYTES));
  return Buffer.concat([d.update(ciphertext.subarray(0, ciphertext.length - TAG_BYTES)), d.final()]);
}

export function keysEqual(a: Uint8Array, b: Uint8Array): boolean { return a.length === b.length && timingSafeEqual(a, b); }
