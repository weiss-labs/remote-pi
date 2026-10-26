import 'package:app/ui/home/states/home_state.dart';

/// Weiss Labs: the Herdr path of a pane, e.g. ["ZachOS", "ZachOS Pi Agent", "Main"].
/// The Mac extension names each pane "Workspace›Tab›Pane" with underscores
/// for spaces (the mesh rejects spaces and slashes). A plain name yields [name].
List<String> panePath(HomeItem it) {
  final r = it.room;
  var raw = (r.name != null && r.name!.isNotEmpty)
      ? r.name!
      : it.peer.sessionName;
  if (raw.isEmpty && r.cwd != null) {
    raw = r.cwd!.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
  }
  final parts = raw
      .split('›')
      .map((s) => s.replaceAll('_', ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? [raw] : parts;
}
