import 'dart:convert';
import 'dart:typed_data';

import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';

/// Private credential handoff primitives, mirrored byte-for-byte by
/// `pi-extension/src/credentials/crypto.ts` (vectors in
/// `test/data/credentials/vectors.json`). Standard algorithms only: Ed25519
/// (paired identities), X25519 ephemeral ECDH, HKDF-SHA256, AES-256-GCM with
/// the canonical signed request as associated data. Canonical bytes are an
/// ordered JSON array after a domain line, never object key order.
const requestDomain = 'remote-pi-credential-request-v1\n';
const responseDomain = 'remote-pi-credential-response-v1\n';
const hkdfInfoPrefix = 'remote-pi-credential-v1-key\n';
const maxSecretBytes = 16 * 1024;
final hkdfSalt = utf8.encode('remote-pi-credential-v1-salt');

Uint8List canonicalRequestBytes(CredentialRequest r) => Uint8List.fromList(
  utf8.encode(requestDomain + jsonEncode(r.canonicalFields)),
);

Uint8List canonicalResponseBytes({
  required List<int> requestHash,
  required String requestId,
  required String phoneKey,
  required String macEpk,
  required String phoneEpk,
  required String nonce,
  required String ciphertext,
}) => Uint8List.fromList(
  utf8.encode(
    responseDomain +
        jsonEncode([
          base64Encode(requestHash),
          requestId,
          phoneKey,
          macEpk,
          phoneEpk,
          nonce,
          ciphertext,
        ]),
  ),
);

/// True only when the paired Mac's Ed25519 key signed exactly these fields.
Future<bool> verifyCredentialRequest(
  List<int> macKey,
  CredentialRequest r,
) async {
  final Uint8List sig;
  try {
    sig = base64Decode(r.sig);
    if (base64Decode(r.macKey).length != 32 || macKey.length != 32) {
      return false;
    }
  } on FormatException {
    return false;
  }
  if (sig.length != 64) return false;
  return Ed25519().verify(
    canonicalRequestBytes(r),
    signature: Signature(
      sig,
      publicKey: SimplePublicKey(macKey, type: KeyPairType.ed25519),
    ),
  );
}

/// HKDF-SHA256(X25519(phone ephemeral, mac ephemeral)) bound to both
/// ephemeral keys and the request id.
Future<SecretKey> deriveCredentialKey({
  required SimpleKeyPair phoneEphemeral,
  required List<int> macEpk,
  required String macEpkB64,
  required String phoneEpkB64,
  required String requestId,
}) async {
  if (macEpk.length != 32) throw const FormatException('bad ephemeral key');
  final shared = await X25519().sharedSecretKey(
    keyPair: phoneEphemeral,
    remotePublicKey: SimplePublicKey(macEpk, type: KeyPairType.x25519),
  );
  final sharedBytes = await shared.extractBytes();
  if (sharedBytes.every((b) => b == 0)) {
    throw const FormatException('low-order ephemeral key');
  }
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: hkdfSalt,
    info: utf8.encode(
      hkdfInfoPrefix + jsonEncode([macEpkB64, phoneEpkB64, requestId]),
    ),
  );
}

/// Encrypts [secret] for [request] and signs the response with the phone's
/// Owner key. [phoneEphemeral]/[nonce] are injectable for test vectors only.
/// The caller owns clearing [secret]; this function keeps no copy.
Future<CredentialResponse> encryptCredentialResponse({
  required CredentialRequest request,
  required List<int> secret,
  required SimpleKeyPair ownerKey,
  required String messageId,
  SimpleKeyPair? phoneEphemeral,
  List<int>? nonce,
}) async {
  if (secret.isEmpty || secret.length > maxSecretBytes) {
    throw const FormatException('secret size');
  }
  final ephemeral = phoneEphemeral ?? await X25519().newKeyPair();
  final phoneEpk = (await ephemeral.extractPublicKey()).bytes;
  final phoneEpkB64 = base64Encode(phoneEpk);
  final key = await deriveCredentialKey(
    phoneEphemeral: ephemeral,
    macEpk: base64Decode(request.macEpk),
    macEpkB64: request.macEpk,
    phoneEpkB64: phoneEpkB64,
    requestId: request.id,
  );
  final aad = canonicalRequestBytes(request);
  final cipher = AesGcm.with256bits();
  final box = await cipher.encrypt(
    secret,
    secretKey: key,
    nonce: nonce ?? cipher.newNonce(),
    aad: aad,
  );
  final ciphertextB64 = base64Encode([...box.cipherText, ...box.mac.bytes]);
  final nonceB64 = base64Encode(box.nonce);
  final phoneKeyB64 = base64Encode((await ownerKey.extractPublicKey()).bytes);
  final requestHash = (await Sha256().hash(aad)).bytes;
  final sig = await Ed25519().sign(
    canonicalResponseBytes(
      requestHash: requestHash,
      requestId: request.id,
      phoneKey: phoneKeyB64,
      macEpk: request.macEpk,
      phoneEpk: phoneEpkB64,
      nonce: nonceB64,
      ciphertext: ciphertextB64,
    ),
    keyPair: ownerKey,
  );
  return CredentialResponse(
    id: messageId,
    requestId: request.id,
    phoneKey: phoneKeyB64,
    phoneEpk: phoneEpkB64,
    nonce: nonceB64,
    ciphertext: ciphertextB64,
    sig: base64Encode(sig.bytes),
  );
}
