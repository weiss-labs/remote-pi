import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One-shot While-Using location through native CoreLocation (AppDelegate
/// `LocationBridge`). No Always permission, no background updates, nothing
/// stored. Coordinates are never logged.
class PhoneLocation {
  static const _channel = MethodChannel('ai.weisslabs.remotepi/location');
  const PhoneLocation();

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// `authorized` | `denied` | `restricted` | `notDetermined` | `unsupported`.
  Future<String> status() => _call('status');

  /// Shows the iOS While-Using prompt when undecided; returns the new status.
  Future<String> requestPermission() => _call('requestPermission');

  Future<void> openSettings() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException {
      /* nothing to recover */
    }
  }

  /// One fresh fix: `{lat, lng, accuracy_m, captured_at}` or `{error}` with
  /// `denied` | `background` | `unavailable`.
  Future<Map<String, Object?>> current() async {
    if (!supported) return const {'error': 'unavailable'};
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('current');
      return r ?? const {'error': 'unavailable'};
    } on PlatformException {
      return const {'error': 'unavailable'};
    } on MissingPluginException {
      return const {'error': 'unavailable'};
    }
  }

  Future<String> _call(String method) async {
    if (!supported) return 'unsupported';
    try {
      return await _channel.invokeMethod<String>(method) ?? 'unsupported';
    } on PlatformException {
      return 'unsupported';
    } on MissingPluginException {
      return 'unsupported';
    }
  }
}
