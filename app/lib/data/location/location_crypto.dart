import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/credentials/credential_crypto.dart'
    show deriveCredentialKey;
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';

/// Phone location reply crypto, mirrored byte-for-byte by
/// `pi-extension/src/location/crypto.ts` (vectors in
/// `test/data/location/vectors.json`). Same primitives as the credential
/// handoff under distinct domain lines, HKDF salt and info, so a credential
/// request or reply can never verify, derive or decrypt as a location one.
const locationRequestDomain = 'remote-pi-location-request-v1\n';
const locationResponseDomain = 'remote-pi-location-response-v1\n';
const locationHkdfInfoPrefix = 'remote-pi-location-v1-key\n';
final locationHkdfSalt = utf8.encode('remote-pi-location-v1-salt');

Uint8List canonicalLocationRequestBytes(LocationRequest r) =>
    Uint8List.fromList(
      utf8.encode(locationRequestDomain + jsonEncode(r.canonicalFields)),
    );

/// True only when the paired Mac's Ed25519 key signed exactly these fields.
Future<bool> verifyLocationRequest(List<int> macKey, LocationRequest r) async {
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
    canonicalLocationRequestBytes(r),
    signature: Signature(
      sig,
      publicKey: SimplePublicKey(macKey, type: KeyPairType.ed25519),
    ),
  );
}

/// Encrypts [payload] (a fix or `{error}`) for [request] and signs the reply
/// with the phone's Owner key. [phoneEphemeral]/[nonce] are test-vector seams.
Future<LocationResponse> encryptLocationResponse({
  required LocationRequest request,
  required List<int> payload,
  required SimpleKeyPair ownerKey,
  required String messageId,
  SimpleKeyPair? phoneEphemeral,
  List<int>? nonce,
}) async {
  final ephemeral = phoneEphemeral ?? await X25519().newKeyPair();
  final phoneEpkB64 = base64Encode((await ephemeral.extractPublicKey()).bytes);
  final key = await deriveCredentialKey(
    phoneEphemeral: ephemeral,
    macEpk: base64Decode(request.macEpk),
    macEpkB64: request.macEpk,
    phoneEpkB64: phoneEpkB64,
    requestId: request.id,
    salt: locationHkdfSalt,
    infoPrefix: locationHkdfInfoPrefix,
  );
  final aad = canonicalLocationRequestBytes(request);
  final cipher = AesGcm.with256bits();
  final box = await cipher.encrypt(
    payload,
    secretKey: key,
    nonce: nonce ?? cipher.newNonce(),
    aad: aad,
  );
  final ciphertextB64 = base64Encode([...box.cipherText, ...box.mac.bytes]);
  final nonceB64 = base64Encode(box.nonce);
  final phoneKeyB64 = base64Encode((await ownerKey.extractPublicKey()).bytes);
  final requestHash = (await Sha256().hash(aad)).bytes;
  final signed = utf8.encode(
    locationResponseDomain +
        jsonEncode([
          base64Encode(requestHash),
          request.id,
          phoneKeyB64,
          request.macEpk,
          phoneEpkB64,
          nonceB64,
          ciphertextB64,
        ]),
  );
  final sig = await Ed25519().sign(signed, keyPair: ownerKey);
  return LocationResponse(
    id: messageId,
    requestId: request.id,
    phoneKey: phoneKeyB64,
    phoneEpk: phoneEpkB64,
    nonce: nonceB64,
    ciphertext: ciphertextB64,
    sig: base64Encode(sig.bytes),
  );
}
