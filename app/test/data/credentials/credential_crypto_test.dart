import 'dart:convert';
import 'dart:io';

import 'package:app/data/credentials/credential_crypto.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors =
      jsonDecode(File('test/data/credentials/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final request = CredentialRequest.fromJson({
    ...vectors['request'] as Map<String, dynamic>,
    'sig': vectors['request_sig'],
  });
  final response = vectors['response'] as Map<String, dynamic>;

  test(
    'canonical request bytes and Mac signature match the Node vectors',
    () async {
      expect(
        utf8.decode(canonicalRequestBytes(request)),
        vectors['canonical_request'],
      );
      final macPk = (await (await Ed25519().newKeyPairFromSeed(
        base64Decode(vectors['mac_seed'] as String),
      )).extractPublicKey()).bytes;
      expect(base64Encode(macPk), request.macKey);
      expect(await verifyCredentialRequest(macPk, request), isTrue);
      final phonePk = (await (await Ed25519().newKeyPairFromSeed(
        base64Decode(vectors['phone_seed'] as String),
      )).extractPublicKey()).bytes;
      expect(await verifyCredentialRequest(phonePk, request), isFalse);
      final altered = CredentialRequest.fromJson({
        ...vectors['request'] as Map<String, dynamic>,
        'reference': 'other',
        'sig': vectors['request_sig'],
      });
      expect(await verifyCredentialRequest(macPk, altered), isFalse);
      expect(
        await verifyCredentialRequest(
          macPk,
          CredentialRequest.fromJson({
            ...vectors['request'] as Map<String, dynamic>,
            'sig': 'not base64!',
          }),
        ),
        isFalse,
      );
    },
  );

  test('phone encrypts and signs exactly like the Node vectors', () async {
    final phoneEphemeral = await X25519().newKeyPairFromSeed(
      base64Decode(vectors['phone_x25519_seed'] as String),
    );
    final ownerKey = await Ed25519().newKeyPairFromSeed(
      base64Decode(vectors['phone_seed'] as String),
    );
    final key = await deriveCredentialKey(
      phoneEphemeral: phoneEphemeral,
      macEpk: base64Decode(request.macEpk),
      macEpkB64: request.macEpk,
      phoneEpkB64: response['phone_epk'] as String,
      requestId: request.id,
    );
    expect(base64Encode(await key.extractBytes()), vectors['key']);
    final out = await encryptCredentialResponse(
      request: request,
      secret: base64Decode(vectors['secret'] as String),
      ownerKey: ownerKey,
      messageId: 'm1',
      phoneEphemeral: phoneEphemeral,
      nonce: base64Decode(response['nonce'] as String),
    );
    expect(out.phoneKey, response['phone_key']);
    expect(out.phoneEpk, response['phone_epk']);
    expect(out.nonce, response['nonce']);
    expect(out.ciphertext, response['ciphertext']);
    expect(out.sig, vectors['response_sig']);
    final wire = jsonEncode(out.toJson());
    expect(wire, isNot(contains('synthetic-secret')));
    expect(wire, isNot(contains(vectors['secret'])));
  });

  test('rejects empty, oversized and low-order inputs', () async {
    final ownerKey = await Ed25519().newKeyPair();
    expect(
      () => encryptCredentialResponse(
        request: request,
        secret: const [],
        ownerKey: ownerKey,
        messageId: 'x',
      ),
      throwsFormatException,
    );
    expect(
      () => encryptCredentialResponse(
        request: request,
        secret: List.filled(maxSecretBytes + 1, 65),
        ownerKey: ownerKey,
        messageId: 'x',
      ),
      throwsFormatException,
    );
    final ephemeral = await X25519().newKeyPair();
    expect(
      () => deriveCredentialKey(
        phoneEphemeral: ephemeral,
        macEpk: List.filled(32, 0),
        macEpkB64: '',
        phoneEpkB64: '',
        requestId: 'r',
      ),
      throwsFormatException,
    );
  });
}
