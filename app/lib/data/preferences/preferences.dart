import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:app/ui/core/themes/app_font_scale.dart';

/// App-wide UI preferences (persisted across launches).
///
/// Extends [ChangeNotifier] so widgets can `context.watch<Preferences>()`
/// and rebuild on toggle. Backed by [FlutterSecureStorage] (same store
/// already used by pairing). Call [load] once during bootstrap before
/// the first frame to hydrate the in-memory cache.
class Preferences extends ChangeNotifier {
  final FlutterSecureStorage _store;
  bool _quietMode = true;
  String? _selectedPeerEpk;
  String? _relayUrl;
  bool _onboardingCompleted = false;
  ThemeMode _themeMode = ThemeMode.dark; // Weiss Labs: dark like the terminal
  AppFontScale _fontScale = AppFontScale.extraLarge;

  Preferences([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  static const _kQuietModeKey = 'prefs.quiet_mode';
  // Pre-quiet-mode key, read once to migrate an explicit opt-out.
  static const _kHideToolCallsKey = 'prefs.hide_tool_calls';
  static const _kSelectedPeerEpkKey = 'prefs.selected_peer_epk';
  static const _kRelayUrlKey = 'prefs.relay_url';
  static const _kOnboardingCompletedKey = 'prefs.onboarding_completed';
  static const _kThemeModeKey = 'prefs.theme_mode';
  static const _kFontScaleKey = 'prefs.font_scale';
  static const _kPinnedKey = 'prefs.pinned';
  static const _kWorkspaceOrderKey = 'prefs.workspaceOrder';
  static const _kHideUsageKey = 'prefs.hide_usage';
  static const _kLastActiveKey = 'prefs.last_active';

  /// Quiet mode (plan/75): tool steps fold into one "Worked for…" row with a
  /// live status line; off shows every tool card. App-wide, phone-local,
  /// never synced to the Mac. On by default.
  bool get quietMode => _quietMode;

  /// Epoch of the peer the user last picked from Home — the one
  /// `/chat` will connect to when it mounts. Null = no peer selected yet
  /// (user is still browsing or hasn't paired). Persisted so reopening
  /// the app right into `/chat` (e.g. via deep-link) knows which peer.
  ///
  /// Plan 17: under the new rooms model the persisted value carries an
  /// optional `:roomId` suffix (e.g. `Bz02uLi…:main` or
  /// `Bz02uLi…:room-uuid-xyz`). The getter returns only the EPK; use
  /// [selectedRoomId] for the room half. Legacy values without the
  /// `:room` suffix transparently fall through (the value is the epk
  /// and `selectedRoomId` returns null → falls back to 'main' at the
  /// caller).
  String? get selectedPeerEpk {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    return ix < 0 ? raw : raw.substring(0, ix);
  }

  /// Plan 17 — the room half of the persisted selected target. Returns
  /// null for legacy values (caller defaults to 'main').
  String? get selectedRoomId {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    if (ix < 0) return null;
    final r = raw.substring(ix + 1);
    return r.isEmpty ? null : r;
  }

  /// Composite raw value (epk[:room]). Tests can inspect.
  String? get selectedRoomRaw => _selectedPeerEpk;

  /// User-configured relay URL override. `null` = use the public default
  /// (`kDefaultRelayUrl` in `relay_config.dart`). Set via Settings or
  /// during onboarding step 2 (custom relay).
  String? get relayUrl => _relayUrl;

  /// `true` after the user completed the 3-step onboarding flow at least
  /// once. Drives `/boot` redirect: false → `/onboarding`, true → `/home`.
  bool get onboardingCompleted => _onboardingCompleted;

  /// Preferred app theme. `ThemeMode.system` (default) follows the OS
  /// light/dark setting; `light` / `dark` pin it. Consumed by `MaterialApp`
  /// in `main.dart` and set from the Settings "Display" section.
  ThemeMode get themeMode => _themeMode;

  /// Preferred text size (issue #114). Applied as a `TextScaler` above the
  /// router in `main.dart`, so it scales the whole UI — including the per-widget
  /// `copyWith(fontSize: …)` overrides that a typography-only change would miss.
  AppFontScale get fontScale => _fontScale;

  // Weiss Labs: pinned panes, keyed "epk|roomId", always listed first on Home.
  Set<String> _pinned = {};
  bool isPinned(String epk, String roomId) => _pinned.contains('$epk|$roomId');
  Future<void> togglePinned(String epk, String roomId) async {
    final k = '$epk|$roomId';
    if (!_pinned.remove(k)) _pinned.add(k);
    await _store.write(key: _kPinnedKey, value: _pinned.join('\n'));
    notifyListeners();
  }

  // Weiss Labs: when each pane was last used (opened here or ran a turn), so
  // Home can float the recent ones to the top of their workspace.
  Map<String, int> _lastActive = {};
  int lastActive(String epk, String roomId) => _lastActive['$epk|$roomId'] ?? 0;
  Future<void> touch(String epk, String roomId) async {
    _lastActive['$epk|$roomId'] = DateTime.now().millisecondsSinceEpoch;
    if (_lastActive.length > 200) {
      // ponytail: drop the oldest; fine for a few dozen panes.
      final oldest = _lastActive.entries
          .reduce((a, b) => a.value < b.value ? a : b)
          .key;
      _lastActive.remove(oldest);
    }
    notifyListeners();
    await _store.write(key: _kLastActiveKey, value: jsonEncode(_lastActive));
  }

  // Weiss Labs: usage gauges in the chat header, tucked away or shown.
  bool _hideUsage = false;
  bool get hideUsage => _hideUsage;
  Future<void> setHideUsage(bool value) async {
    if (_hideUsage == value) return;
    _hideUsage = value;
    notifyListeners();
    await _store.write(key: _kHideUsageKey, value: value.toString());
  }

  // Weiss Labs: Herdr workspace order on Home, set by dragging the ≡ handle.
  // Names not in the list (new workspaces) sort after it, alphabetically.
  List<String> _workspaceOrder = [];
  List<String> get workspaceOrder => List.unmodifiable(_workspaceOrder);
  Future<void> setWorkspaceOrder(List<String> order) async {
    _workspaceOrder = [...order];
    await _store.write(key: _kWorkspaceOrderKey, value: order.join('\n'));
    notifyListeners();
  }

  /// Hydrate from secure storage. Safe to call multiple times.
  Future<void> load() async {
    var changed = false;

    final quietRaw = await _store.read(key: _kQuietModeKey);
    // Migration: someone who explicitly turned the old "hide tool calls"
    // switch back OFF wanted full detail; keep that choice. Everyone else
    // (unset, or hid tool calls) starts quiet.
    final legacy = quietRaw == null
        ? await _store.read(key: _kHideToolCallsKey)
        : null;
    final next = quietRaw != null ? quietRaw == 'true' : legacy != 'false';
    if (next != _quietMode) {
      _quietMode = next;
      changed = true;
    }

    final selected = await _store.read(key: _kSelectedPeerEpkKey);
    final cleaned = (selected != null && selected.isNotEmpty) ? selected : null;
    if (cleaned != _selectedPeerEpk) {
      _selectedPeerEpk = cleaned;
      changed = true;
    }

    final relay = await _store.read(key: _kRelayUrlKey);
    final relayCleaned = (relay != null && relay.isNotEmpty) ? relay : null;
    if (relayCleaned != _relayUrl) {
      _relayUrl = relayCleaned;
      changed = true;
    }

    final onboarded = await _store.read(key: _kOnboardingCompletedKey);
    final onboardedBool = onboarded == 'true';
    if (onboardedBool != _onboardingCompleted) {
      _onboardingCompleted = onboardedBool;
      changed = true;
    }

    final theme = await _store.read(key: _kThemeModeKey);
    final themeMode = _themeModeFromString(theme);
    if (themeMode != _themeMode) {
      _themeMode = themeMode;
      changed = true;
    }

    final scale = AppFontScale.fromName(await _store.read(key: _kFontScaleKey));
    if (scale != _fontScale) {
      _fontScale = scale;
      changed = true;
    }

    final lastRaw = await _store.read(key: _kLastActiveKey);
    if (lastRaw != null && lastRaw.isNotEmpty) {
      try {
        _lastActive = (jsonDecode(lastRaw) as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        );
        changed = true;
      } catch (_) {}
    }

    final hideUsage = await _store.read(key: _kHideUsageKey) == 'true';
    if (hideUsage != _hideUsage) {
      _hideUsage = hideUsage;
      changed = true;
    }

    final orderRaw = await _store.read(key: _kWorkspaceOrderKey);
    final order = (orderRaw ?? '')
        .split('\n')
        .where((s) => s.isNotEmpty)
        .toList();
    if (order.join('\n') != _workspaceOrder.join('\n')) {
      _workspaceOrder = order;
      changed = true;
    }

    final pinnedRaw = await _store.read(key: _kPinnedKey);
    final pinned = (pinnedRaw ?? '')
        .split('\n')
        .where((s) => s.isNotEmpty)
        .toSet();
    if (pinned.length != _pinned.length || !pinned.containsAll(_pinned)) {
      _pinned = pinned;
      changed = true;
    }

    if (changed) notifyListeners();
  }

  Future<void> setQuietMode(bool value) async {
    if (_quietMode == value) return;
    _quietMode = value;
    notifyListeners();
    await _store.write(key: _kQuietModeKey, value: value.toString());
  }

  Future<void> setSelectedPeerEpk(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _selectedPeerEpk) return;
    _selectedPeerEpk = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kSelectedPeerEpkKey);
    } else {
      await _store.write(key: _kSelectedPeerEpkKey, value: cleaned);
    }
    notifyListeners();
  }

  /// Plan 17 — persist the composite `epk:roomId` selection. Passing
  /// [roomId] = null falls back to 'main' implicitly via the getter
  /// contract. Null [epk] clears the entire selection.
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    if (epk == null || epk.isEmpty) {
      return setSelectedPeerEpk(null);
    }
    final composite = (roomId == null || roomId.isEmpty) ? epk : '$epk:$roomId';
    return setSelectedPeerEpk(composite);
  }

  /// Set the user-configured relay URL. `null` or empty clears the
  /// override so the app falls back to `kDefaultRelayUrl`. Caller should
  /// validate via `isValidRelayUrl` first when [value] is non-null.
  Future<void> setRelayUrl(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _relayUrl) return;
    _relayUrl = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kRelayUrlKey);
    } else {
      await _store.write(key: _kRelayUrlKey, value: cleaned);
    }
    notifyListeners();
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (_onboardingCompleted == value) return;
    _onboardingCompleted = value;
    await _store.write(key: _kOnboardingCompletedKey, value: value.toString());
    notifyListeners();
  }

  /// Persist the preferred [ThemeMode]. Stored as a stable string key so the
  /// value survives enum reordering.
  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    await _store.write(key: _kThemeModeKey, value: value.name);
    notifyListeners();
  }

  /// Persist the preferred [AppFontScale]. Stored by `name` so the value
  /// survives enum reordering.
  Future<void> setFontScale(AppFontScale value) async {
    if (_fontScale == value) return;
    _fontScale = value;
    await _store.write(key: _kFontScaleKey, value: value.name);
    notifyListeners();
  }

  static ThemeMode _themeModeFromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
