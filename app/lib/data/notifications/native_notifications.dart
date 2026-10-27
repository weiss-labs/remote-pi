import 'package:flutter/services.dart';

abstract class NotificationPlatform {
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> requestPermission();
  Future<List<dynamic>> takeTaps();
  Future<void> openSettings();
  Future<void> visibleTarget(String? peer, String? room);
  void listen(void Function(String, dynamic) listener);
}

class NativeNotifications implements NotificationPlatform {
  static const channel = MethodChannel('ai.weisslabs.remotepi/notifications');
  Future<Map<String, dynamic>> _call(String method) async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>(method) ?? {},
      );
  @override
  Future<Map<String, dynamic>> status() => _call('status');
  @override
  Future<Map<String, dynamic>> requestPermission() =>
      _call('requestPermission');
  @override
  Future<List<dynamic>> takeTaps() async =>
      await channel.invokeListMethod<dynamic>('takeTaps') ?? [];
  @override
  Future<void> openSettings() => channel.invokeMethod('openSettings');
  @override
  Future<void> visibleTarget(String? peer, String? room) =>
      channel.invokeMethod('visibleTarget', {'peer': peer, 'room': room});
  @override
  void listen(void Function(String, dynamic) listener) {
    channel.setMethodCallHandler(
      (call) async => listener(call.method, call.arguments),
    );
  }
}
