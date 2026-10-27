import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:app/protocol/protocol.dart';

/// Wire contract shared with the paired Pi and relay. Field order is signed.
List<int> notificationGrantBytes(
  String peer,
  String phone,
  NotifyRegister message,
) => utf8.encode(
  'remote-pi-notify-device-v${message.showQuestionPreview == null ? 1 : 2}\n${jsonEncode([peer, phone, message.deviceId, message.token, message.environment, message.categories, message.showPaneName, if (message.showQuestionPreview != null) message.showQuestionPreview, message.expiresAt])}',
);

Future<NotifyRegister> signNotificationGrant(
  String peer,
  SimpleKeyPair key,
  NotifyRegister message,
) async {
  final publicKey = await key.extractPublicKey();
  final signature = await Ed25519().sign(
    notificationGrantBytes(peer, base64Encode(publicKey.bytes), message),
    keyPair: key,
  );
  return NotifyRegister(
    id: message.id,
    deviceId: message.deviceId,
    token: message.token,
    environment: message.environment,
    categories: message.categories,
    showPaneName: message.showPaneName,
    showQuestionPreview: message.showQuestionPreview,
    expiresAt: message.expiresAt,
    signature: base64Encode(signature.bytes),
  );
}
