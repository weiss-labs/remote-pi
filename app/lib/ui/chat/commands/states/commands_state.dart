import 'package:app/domain/contracts/pane_commands.dart';

sealed class CommandsState {
  const CommandsState();
}

class CommandsIdle extends CommandsState {
  const CommandsIdle();
}

class CommandsLoading extends CommandsState {
  const CommandsLoading();
}

class CommandsReady extends CommandsState {
  final List<PaneCommand> commands;
  final String? error;
  const CommandsReady(this.commands, {this.error});
}

class CommandsRunning extends CommandsState {
  final String name;
  const CommandsRunning(this.name);
}

class CommandsUnavailable extends CommandsState {
  final String message;
  const CommandsUnavailable(this.message);
}
