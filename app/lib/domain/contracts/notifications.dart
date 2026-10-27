import 'service.dart';
import '../entities/notification_preferences.dart';
export '../entities/notification_preferences.dart';

abstract class Notifications extends Service {
  NotificationPreferences get preferences;
  String get permission;
  String get status;
  Map<String, String> get peerSyncStates => const {};
  bool get supported;
  Stream<void> get changes;
  Stream<NotificationTarget> get taps;
  Future<void> start();
  Future<void> update(NotificationPreferences preferences);
  Future<void> requestPermission();
  Future<void> refresh();
  Future<void> openSettings();
  Future<void> visibleTarget(String? peer, String? room);
  Future<bool> acceptTap(NotificationTarget target);
  Future<bool> isKnownRoom(NotificationTarget target);
}
