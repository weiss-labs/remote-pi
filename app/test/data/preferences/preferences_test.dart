import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('Preferences', () {
    test('quiet mode is on by default, before and after load()', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.quietMode, isTrue);
      await p.load();
      expect(p.quietMode, isTrue);
    });

    test('load() hydrates quiet mode from storage', () async {
      final store = _FakeSecureStorage();
      await store.write(key: 'prefs.quiet_mode', value: 'false');
      final p = Preferences(store);
      await p.load();
      expect(p.quietMode, isFalse);
    });

    test(
      'migrates an explicit hideToolCalls=false to quiet OFF, once',
      () async {
        final store = _FakeSecureStorage();
        await store.write(key: 'prefs.hide_tool_calls', value: 'false');
        final p = Preferences(store);
        await p.load();
        expect(p.quietMode, isFalse);

        // hideToolCalls=true (or unset) keeps the quiet default.
        final hid = _FakeSecureStorage();
        await hid.write(key: 'prefs.hide_tool_calls', value: 'true');
        final q = Preferences(hid);
        await q.load();
        expect(q.quietMode, isTrue);

        // Once quiet_mode is written it wins over the legacy key.
        await store.write(key: 'prefs.quiet_mode', value: 'true');
        final r = Preferences(store);
        await r.load();
        expect(r.quietMode, isTrue);
      },
    );

    test('setQuietMode writes to storage and notifies (round trip)', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      var notifs = 0;
      p.addListener(() => notifs++);

      await p.setQuietMode(false);
      expect(p.quietMode, isFalse);
      expect(await store.read(key: 'prefs.quiet_mode'), 'false');
      expect(notifs, 1);

      // No-op if value unchanged.
      await p.setQuietMode(false);
      expect(notifs, 1);

      await p.setQuietMode(true);
      expect(p.quietMode, isTrue);
      expect(await store.read(key: 'prefs.quiet_mode'), 'true');
      expect(notifs, 2);
    });

    test('relayUrl defaults to null and round-trips via setRelayUrl', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.relayUrl, isNull);

      await p.setRelayUrl('wss://custom.example.com');
      expect(p.relayUrl, 'wss://custom.example.com');
      expect(
        await store.read(key: 'prefs.relay_url'),
        'wss://custom.example.com',
      );

      // Reload from cold start → value survives.
      final p2 = Preferences(store);
      await p2.load();
      expect(p2.relayUrl, 'wss://custom.example.com');

      // Clearing sends null and removes the key.
      await p.setRelayUrl(null);
      expect(p.relayUrl, isNull);
      expect(await store.read(key: 'prefs.relay_url'), isNull);

      // Empty string also clears.
      await p.setRelayUrl('wss://x');
      await p.setRelayUrl('');
      expect(p.relayUrl, isNull);
    });

    test('onboardingCompleted defaults to false and round-trips via '
        'setOnboardingCompleted', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.onboardingCompleted, isFalse);

      await p.setOnboardingCompleted(true);
      expect(p.onboardingCompleted, isTrue);
      expect(await store.read(key: 'prefs.onboarding_completed'), 'true');

      final p2 = Preferences(store);
      await p2.load();
      expect(p2.onboardingCompleted, isTrue);
    });

    test('selectedRoom round-trips epk + roomId composite (plan 17)', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.setSelectedRoom(epk: 'abc123', roomId: 'room-xyz');
      expect(p.selectedPeerEpk, 'abc123');
      expect(p.selectedRoomId, 'room-xyz');
      expect(p.selectedRoomRaw, 'abc123:room-xyz');

      // Reload from cold → preserved
      final p2 = Preferences(store);
      await p2.load();
      expect(p2.selectedPeerEpk, 'abc123');
      expect(p2.selectedRoomId, 'room-xyz');
    });

    test('backward-compat: legacy value (no `:room` suffix) returns epk '
        'and null roomId so caller defaults to "main"', () async {
      final store = _FakeSecureStorage();
      // Pre-populate with legacy format (just the epk, no suffix).
      await store.write(key: 'prefs.selected_peer_epk', value: 'legacy_epk');
      final p = Preferences(store);
      await p.load();
      expect(p.selectedPeerEpk, 'legacy_epk');
      expect(p.selectedRoomId, isNull);
    });

    // Issue #114 — in-app text size.
    test(
      'fontScale defaults to extraLarge and round-trips through storage',
      () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.load();
        expect(p.fontScale, AppFontScale.extraLarge);

        await p.setFontScale(AppFontScale.large);
        expect(p.fontScale, AppFontScale.large);

        final reloaded = Preferences(store);
        await reloaded.load();
        expect(reloaded.fontScale, AppFontScale.large);
      },
    );

    test('an unknown persisted font scale falls back to extraLarge', () async {
      final store = _FakeSecureStorage();
      // A stale/corrupt value must never leave the app at an unreadable size.
      await store.write(key: 'prefs.font_scale', value: 'gigantic');
      final p = Preferences(store);
      await p.load();
      expect(p.fontScale, AppFontScale.extraLarge);
    });

    test('setFontScale notifies listeners only on a real change', () async {
      final p = Preferences(_FakeSecureStorage());
      var calls = 0;
      p.addListener(() => calls++);

      await p.setFontScale(AppFontScale.small);
      expect(calls, 1);
      await p.setFontScale(AppFontScale.small);
      expect(calls, 1);
    });

    test('setSelectedRoom with null epk clears the selection', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.setSelectedRoom(epk: 'abc', roomId: 'r');
      expect(p.selectedPeerEpk, 'abc');
      await p.setSelectedRoom(epk: null);
      expect(p.selectedPeerEpk, isNull);
      expect(p.selectedRoomRaw, isNull);
    });
  });
}
