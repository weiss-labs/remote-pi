import 'dart:convert';
import 'dart:io';

import 'package:app/data/credentials/credential_crypto.dart';
import 'package:app/data/location/location_crypto.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors =
      jsonDecode(File('test/data/location/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final credVectors =
      jsonDecode(File('test/data/credentials/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final request = LocationRequest.fromJson({
    ...vectors['request'] as Map<String, dynamic>,
    'sig': vectors['request_sig'],
  });
  final response = vectors['response'] as Map<String, dynamic>;
  Future<List<int>> pub(String seed) async =>
      (await (await Ed25519().newKeyPairFromSeed(
        base64Decode(seed),
      )).extractPublicKey()).bytes;

  test(
    'canonical request bytes and Mac signature match the Node vectors',
    () async {
      expect(
        utf8.decode(canonicalLocationRequestBytes(request)),
        vectors['canonical_request'],
      );
      final macPk = await pub(vectors['mac_seed'] as String);
      expect(await verifyLocationRequest(macPk, request), isTrue);
      expect(
        await verifyLocationRequest(
          await pub(vectors['phone_seed'] as String),
          request,
        ),
        isFalse,
      );
      final altered = LocationRequest.fromJson({
        ...vectors['request'] as Map<String, dynamic>,
        'purpose': 'track me',
        'sig': vectors['request_sig'],
      });
      expect(await verifyLocationRequest(macPk, altered), isFalse);
    },
  );

  test('phone encrypts and signs exactly like the Node vectors', () async {
    final frame = await encryptLocationResponse(
      request: request,
      payload: base64Decode(vectors['plaintext'] as String),
      ownerKey: await Ed25519().newKeyPairFromSeed(
        base64Decode(vectors['phone_seed'] as String),
      ),
      messageId: 'm1',
      phoneEphemeral: await X25519().newKeyPairFromSeed(
        base64Decode(vectors['phone_x25519_seed'] as String),
      ),
      nonce: base64Decode(response['nonce'] as String),
    );
    expect(frame.phoneKey, response['phone_key']);
    expect(frame.phoneEpk, response['phone_epk']);
    expect(frame.ciphertext, response['ciphertext']);
    expect(frame.sig, vectors['response_sig']);
    expect(frame.requestId, request.id);
  });

  test('credential and location domains never cross over', () async {
    final macPk = await pub(vectors['mac_seed'] as String);
    // A credential signature over the same id/room/session is not a location one.
    final asLocation = LocationRequest.fromJson({
      ...vectors['request'] as Map<String, dynamic>,
      'sig': credVectors['request_sig'],
    });
    expect(await verifyLocationRequest(macPk, asLocation), isFalse);
    final asCredential = CredentialRequest.fromJson({
      ...credVectors['request'] as Map<String, dynamic>,
      'sig': vectors['request_sig'],
    });
    expect(await verifyCredentialRequest(macPk, asCredential), isFalse);
    // Same ephemerals and request id derive different keys per domain.
    final phoneE = await X25519().newKeyPairFromSeed(
      base64Decode(vectors['phone_x25519_seed'] as String),
    );
    Future<String> key({List<int>? salt, String? info}) async => base64Encode(
      await (await deriveCredentialKey(
        phoneEphemeral: phoneE,
        macEpk: base64Decode(request.macEpk),
        macEpkB64: request.macEpk,
        phoneEpkB64: response['phone_epk'] as String,
        requestId: request.id,
        salt: salt,
        infoPrefix: info ?? hkdfInfoPrefix,
      )).extractBytes(),
    );
    expect(
      await key(salt: locationHkdfSalt, info: locationHkdfInfoPrefix),
      vectors['key'],
    );
    expect(await key(), isNot(vectors['key']));
  });
}
