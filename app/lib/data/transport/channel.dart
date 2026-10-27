import 'package:app/protocol/protocol.dart';

/// Abstract channel — testable interface over [PlainPeerChannel].
abstract class IChannel {
  Stream<ServerMessage> get serverMessages;
  Future<void> send(ClientMessage msg);
  Future<void> close();
}

/// Narrow fanout over the existing authenticated socket. Never changes chat
/// selection or creates another Owner/main connection.
class RoutedNotificationReply {
  final String peer, room;
  final NotificationRegistration reply;
  const RoutedNotificationReply({
    required this.peer,
    required this.room,
    required this.reply,
  });
}

abstract class INotificationRoutes {
  Stream<RoutedNotificationReply> get notificationReplies;
  Future<void> sendNotificationTo(
    ClientMessage message, {
    required String peer,
    required String room,
  });
}

/// Optional capability mixed into a channel that also speaks raw relay
/// control frames (subscribe_presence, peer_online, etc — see plano 12).
/// ConnectionManager does an `is IControlLink` cast to drive presence;
/// channels that don't implement it simply skip the subsystem.
abstract class IControlLink {
  Stream<ControlInbound> get controlFrames;
  void sendControl(Map<String, dynamic> json);
}
