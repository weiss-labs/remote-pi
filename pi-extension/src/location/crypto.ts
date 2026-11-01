// Phone location reply crypto (mirror of app/lib/data/location/location_crypto.dart).
// Same primitives as the private credential handoff, under distinct domain lines,
// HKDF salt and info so a credential request/reply can never verify, derive or
// decrypt as a location one (or vice versa).
import { ed25519Sign, ed25519Verify } from "../pairing/crypto.js";
import { deriveKey as deriveWith, sha256, type X25519Keypair } from "../credentials/crypto.js";

export const REQUEST_DOMAIN = "remote-pi-location-request-v1\n";
export const RESPONSE_DOMAIN = "remote-pi-location-response-v1\n";
export const HKDF_SALT = Buffer.from("remote-pi-location-v1-salt", "utf8");
export const HKDF_INFO_PREFIX = "remote-pi-location-v1-key\n";
export const MAX_PLAINTEXT_BYTES = 1024;

export interface LocationRequestFields {
  mac_key: string;     // paired Mac Ed25519 public key, base64 std
  room: string;
  session: string;     // per-session nonce
  id: string;
  expires_at: number;  // epoch ms
  purpose: string;
  mac_epk: string;     // ephemeral X25519 public key, base64 std
}
export interface LocationResponseFields { id: string; phone_key: string; phone_epk: string; nonce: string; ciphertext: string }

export function canonicalRequest(r: LocationRequestFields): Buffer {
  return Buffer.from(REQUEST_DOMAIN + JSON.stringify([r.mac_key, r.room, r.session, r.id, r.expires_at, r.purpose, r.mac_epk]), "utf8");
}
export function canonicalResponse(requestHash: Buffer, r: LocationResponseFields, macEpk: string): Buffer {
  return Buffer.from(RESPONSE_DOMAIN + JSON.stringify([requestHash.toString("base64"), r.id, r.phone_key, macEpk, r.phone_epk, r.nonce, r.ciphertext]), "utf8");
}
export function signRequest(macSecretKey: Uint8Array, r: LocationRequestFields): string {
  return Buffer.from(ed25519Sign(macSecretKey, canonicalRequest(r))).toString("base64");
}
export function verifyRequest(macPublicKey: Uint8Array, r: LocationRequestFields, sig: string): boolean {
  try { return ed25519Verify(macPublicKey, canonicalRequest(r), Buffer.from(sig, "base64")); } catch { return false; }
}
export function signResponse(phoneSecretKey: Uint8Array, request: LocationRequestFields, r: LocationResponseFields): string {
  return Buffer.from(ed25519Sign(phoneSecretKey, canonicalResponse(sha256(canonicalRequest(request)), r, request.mac_epk))).toString("base64");
}
export function verifyResponse(phonePublicKey: Uint8Array, request: LocationRequestFields, r: LocationResponseFields, sig: string): boolean {
  try { return ed25519Verify(phonePublicKey, canonicalResponse(sha256(canonicalRequest(request)), r, request.mac_epk), Buffer.from(sig, "base64")); } catch { return false; }
}
export function deriveKey(mine: X25519Keypair, theirPublic: Buffer, macEpk: string, phoneEpk: string, requestId: string): Buffer {
  return deriveWith(mine, theirPublic, macEpk, phoneEpk, requestId, HKDF_SALT, HKDF_INFO_PREFIX);
}
export { encrypt, decrypt, generateX25519, x25519FromSeed, keysEqual, sha256, type X25519Keypair } from "../credentials/crypto.js";
