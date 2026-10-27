import 'repository.dart';

/// A live command advertised by the currently paired pane, never a local guess.
class PaneCommand {
  final String name;
  final String description;
  final bool executable;
  final String? disabledReason;
  final String source;
  final String busyPolicy;
  const PaneCommand({
    required this.name,
    required this.description,
    required this.executable,
    this.disabledReason,
    this.source = 'extension',
    this.busyPolicy = 'idle_only',
  });
}

class PaneCommandFailure implements Exception {
  final String message;
  const PaneCommandFailure(this.message);
  @override
  String toString() => message;
}

abstract class PaneCommands extends Repository {
  /// Changes when the channel, peer or room changes. Old results must be dropped.
  Stream<void> get contextChanges;
  Future<List<PaneCommand>> list();
  Future<void> execute(String name, String arguments);
}
