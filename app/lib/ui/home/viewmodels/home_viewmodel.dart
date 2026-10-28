import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/pane_path.dart';

/// HomeViewModel — passive list of paired peers + live presence dots
/// + rooms discovered on each peer (plan 17). A single tile per
/// (peer, room).
///
/// The WS connection is owned by [ConnectionManager] from app boot (plano
/// 12). Home only:
///   - reads the peer list from storage
///   - watches `presenceStream` + `roomsStream` to render dots / rooms
///     in real time
///   - writes [Preferences.selectedRoom] when the user taps a tile so
///     `/chat` knows which (peer, room) to address
class HomeViewModel extends ViewModel<HomeState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  bool _relayConnected = false;
  bool _disposed = false;

  HomeViewModel(this._storage, this._prefs, this._conn)
    : super(const HomeLoading()) {
    _relayConnected = _conn.status is StatusOnline;
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _statusSub = _conn.statusStream.listen(_onStatus);
    // Settings (rename / revoke) and pairing flow both write through
    // PairingStorage; listening here keeps Home in sync without manual
    // notifications between screens.
    _storage.addListener(_onStorageChanged);
  }

  void _onStorageChanged() {
    if (_disposed) return;
    _load();
  }

  /// `true` when the app's WS to the relay is alive (StatusOnline).
  /// When `false`, every room dot should render in the "reconnecting"
  /// colour (amber) regardless of `isRoomLive`, because the app has
  /// no fresh signal on any room.
  bool get isRelayConnected => _relayConnected;

  /// `true` when `(epk, roomId)`'s agent is currently mid-turn. Drives
  /// the blue "working" dot on the Home tile.
  ///
  /// Plan/32 — single source of truth: the relay broadcasts `meta.working`
  /// (turn_start/turn_end from the Pi-extension) to ALL subscribed rooms,
  /// exactly like presence, so this reflects EVERY session — connected or
  /// not. We deliberately do NOT OR the DB session index here: that row is
  /// only kept fresh for the currently-connected room (the SyncService
  /// writer follows the active connection), so a session that finishes
  /// while the app is on a DIFFERENT chat would never get its index idled
  /// and the dot would stay blue forever. The relay flag has no such blind
  /// spot.
  bool isRoomWorking(String epk, String roomId) =>
      _conn.isRoomWorking(epk, roomId);

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Make sure the relay is pushing updates for everyone we know about;
    // the call is idempotent so this is safe even mid-session. The same
    // subscribe also covers rooms (plan 17 — replay block in
    // ConnectionManager sends both presence and rooms subscribes).
    _conn.subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    final prev = state;
    emit(
      HomeList(
        peers: peers,
        statusByEpk: _conn.presenceSnapshot,
        roomsByPeer: _conn.roomsSnapshot,
        // Keep the user's tab across reloads (pull-to-refresh, storage edits).
        filter: prev is HomeList ? prev.filter : HomeFilter.online,
      ),
    );
  }

  void _onPresence(Map<String, PresenceState> snapshot) {
    if (_refreshing) return; // applied in one go when refresh() finishes
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(statusByEpk: snapshot));
  }

  // Rooms seen working on the last snapshot; a false→true flip counts as use.
  final Set<String> _wasWorking = {};

  void _onRooms(Map<String, List<RoomInfo>> snapshot) {
    for (final e in snapshot.entries) {
      for (final r in e.value) {
        final k = '${e.key}|${r.roomId}';
        if (r.working && _wasWorking.add(k)) {
          unawaited(_prefs.touch(e.key, r.roomId));
        }
        if (!r.working) _wasWorking.remove(k);
      }
    }
    if (_refreshing) return; // applied in one go when refresh() finishes
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(roomsByPeer: snapshot));
  }

  void _onStatus(ConnectionStatus status) {
    // Pull-to-refresh tears the socket down on purpose; keep the list steady
    // until it's back instead of flashing every pane offline.
    if (_refreshing) return;
    final next = status is StatusOnline;
    if (next == _relayConnected) return;
    _relayConnected = next;
    // Trigger a re-render of any HomeList so tiles re-evaluate dot
    // colour (room-live vs reconnecting).
    final s = state;
    if (s is HomeList) {
      // emit a duplicate-looking HomeList so context.watch() triggers
      // even though peers / roomsByPeer / presence didn't change.
      // Preserve `filter` — otherwise a status flip would silently reset
      // the user's tab back to the Online default (and, because the new
      // object would then differ, actually fire that reset).
      emit(
        HomeList(
          peers: s.peers,
          statusByEpk: s.statusByEpk,
          roomsByPeer: s.roomsByPeer,
          filter: s.filter,
        ),
      );
    }
  }

  /// Plan-38 Fase 3 — switch the presence tab. No reload: it only swaps the
  /// `filter` in state so [visibleItems] re-derives. No-op when the state
  /// isn't a list or the filter is unchanged.
  void setFilter(HomeFilter filter) {
    final s = state;
    if (s is! HomeList) return;
    if (s.filter == filter) return;
    emit(s.copyWith(filter: filter));
  }

  /// `true` when `(epk, roomId)` is live on the relay AND the relay itself
  /// is reachable. The single source of truth for the Online/Offline split.
  /// [ConnectionManager.isRoomLive] is already gated on `StatusOnline`, so
  /// the `_relayConnected &&` is belt-and-suspenders that also documents
  /// intent: "online" requires a live relay.
  bool _online(HomeItem it) =>
      _relayConnected && _conn.isRoomLive(it.peer.remoteEpk, it.room.roomId);

  /// Plan-38 Fase 3 — the items the current [HomeList.filter] keeps. A pure
  /// view over `state.items()`; returns `const []` outside a list state.
  List<HomeItem> get visibleItems {
    final s = state;
    if (s is! HomeList) return const [];
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    final byTab = switch (s.filter) {
      HomeFilter.all => all,
      HomeFilter.online => all.where(_online).toList(),
      HomeFilter.offline => all.where((i) => !_online(i)).toList(),
    };
    // Every typed word must appear somewhere in the pane's path, in any
    // order; path separators (› → / _) are ignored so a pasted full name works.
    final words = _query.toLowerCase().split(_searchSeparators)
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return byTab;
    return byTab.where((i) {
      final path = panePath(i).join(' ').toLowerCase();
      return words.every(path.contains);
    }).toList();
  }

  // Weiss Labs: pull-to-refresh.
  bool _refreshing = false;
  Future<void> refresh() async {
    _refreshing = true;
    try {
      await _load();
      // Returns once the fresh rooms snapshot landed (or timed out).
      await _conn.resync(preferredEpk: _prefs.selectedPeerEpk);
    } finally {
      _refreshing = false;
      // One rebuild with the fresh relay view (presence, rooms, status).
      _relayConnected = _conn.status is StatusOnline;
      final s = state;
      if (s is HomeList && !_disposed) {
        emit(
          HomeList(
            peers: s.peers,
            statusByEpk: _conn.presenceSnapshot,
            roomsByPeer: _conn.roomsSnapshot,
            filter: s.filter,
          ),
        );
      }
    }
  }

  /// Weiss Labs: most recently used first; untouched panes keep [order].
  List<HomeItem> byRecency(List<HomeItem> items) {
    final idx = {for (var i = 0; i < items.length; i++) items[i]: i};
    return [...items]..sort((a, b) {
      final c = lastActive(b).compareTo(lastActive(a));
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
    });
  }

  int lastActive(HomeItem it) => _prefs.lastActive(
    normalizeEpkForLookup(it.peer.remoteEpk),
    it.room.roomId,
  );

  // Weiss Labs: pins.
  bool isPinned(HomeItem it) =>
      _prefs.isPinned(it.peer.remoteEpk, it.room.roomId);
  Future<void> togglePin(HomeItem it) async {
    await _prefs.togglePinned(it.peer.remoteEpk, it.room.roomId);
    notifyListeners();
  }

  // Weiss Labs: drag-to-reorder Herdr workspaces. Known names keep their saved
  // slot; new ones go after, alphabetically.
  List<String> orderWorkspaces(Iterable<String> names) {
    final saved = _prefs.workspaceOrder;
    int rank(String n) {
      final i = saved.indexOf(n);
      return i < 0 ? saved.length : i;
    }

    return names.toSet().toList()..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.toLowerCase().compareTo(b.toLowerCase());
    });
  }

  /// [to] is the final index (onReorderItem already adjusted for the removal).
  void moveWorkspace(List<String> names, int from, int to) {
    final next = [...names];
    next.insert(to, next.removeAt(from));
    // Workspaces hidden by the filter/search keep their slots; the visible
    // ones are re-dealt into the slots they occupied.
    final full = orderWorkspaces({..._prefs.workspaceOrder, ...names});
    var i = 0;
    final merged = [for (final n in full) names.contains(n) ? next[i++] : n];
    unawaited(_prefs.setWorkspaceOrder(merged));
    notifyListeners();
  }

  // Weiss Labs: search box over the pane list.
  static final _searchSeparators = RegExp(r'[\s›→/_>]+');
  String _query = '';
  String get query => _query;
  void setQuery(String q) {
    if (q == _query) return;
    _query = q;
    notifyListeners();
  }

  /// Plan-38 Fase 3 — per-tab counts for the filter badges. Independent of
  /// the active tab (each badge always shows its own slice's size).
  ({int all, int online, int offline}) get counts {
    final s = state;
    if (s is! HomeList) return (all: 0, online: 0, offline: 0);
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    final online = all.where(_online).length;
    return (all: all.length, online: online, offline: all.length - online);
  }

  /// Remember which (peer, room) the user picked. Falls back to
  /// `roomId='main'` when the caller doesn't supply one (legacy /
  /// pre-room-announce). Also flips the ConnectionManager's active
  /// room so subsequent sends carry the right outer envelope.
  ///
  /// Plan-24 follow-up: when the peer record in storage has no
  /// `roomId` yet (post-mesh-restore: the mesh blob doesn't carry
  /// per-device room data, so `PeerRecord.roomId` is null until the
  /// relay announces the room and `ConnectionManager._maybeAdoptLegacyRoom`
  /// catches up), persist the tapped roomId on the PeerRecord too.
  /// Without this, the next cold-start reads `peer.roomId=null` →
  /// `ConnectionManager._connect` falls back to room `'main'` → Pi
  /// never sees the frame → ChatViewModel sits on Connecting/offline
  /// even though the WS is alive.
  Future<void> openSession(String epk, {String? roomId}) async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) return;
    final peer = match.first!;
    final effectiveRoom = (roomId == null || roomId.isEmpty) ? 'main' : roomId;
    await _prefs.setSelectedRoom(epk: epk, roomId: effectiveRoom);
    unawaited(_prefs.touch(normalizeEpkForLookup(epk), effectiveRoom));
    if (peer.roomId != effectiveRoom) {
      // ignore: unawaited_futures
      _storage.savePeer(peer.copyWith(roomId: effectiveRoom));
    }
    // Tell the manager which Pi-side room to address. Safe to call
    // even if the manager is mid-connect (room is applied on the next
    // send and any active StatusOnline channel).
    _conn.switchRoom(effectiveRoom);
  }

  /// Helper for widgets: pass a peer's url-safe epk → returns standard
  /// for indexing into [HomeList.roomsByPeer] / [HomeList.statusByEpk].
  static String normalizeEpkForLookup(String epk) => toStandardB64(epk);

  /// Plan-17 follow-up — `true` if `(epk, roomId)` is currently live on
  /// the relay. Drives the presence dot on each tile (per-room, not
  /// per-peer anymore).
  bool isRoomLive(String epk, String roomId) => _conn.isRoomLive(epk, roomId);

  /// Long-press menu — rename a single room locally (Pi never sees it).
  Future<void> renameRoom(String epk, String roomId, String? name) =>
      _conn.setRoomLocalName(epk, roomId, name);

  /// Long-press menu — delete a cached room locally. Caller should
  /// gate on `!isRoomLive` (only offline rooms can be removed).
  Future<void> deleteRoom(String epk, String roomId) =>
      _conn.deleteCachedRoom(epk, roomId);

  @override
  void dispose() {
    _disposed = true;
    _presenceSub?.cancel();
    _roomsSub?.cancel();
    _statusSub?.cancel();
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }
}
