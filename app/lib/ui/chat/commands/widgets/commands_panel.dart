import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import '../viewmodels/commands_viewmodel.dart';

class CommandsPanel extends StatelessWidget {
  final CommandsViewModel? viewModel;
  final String query;
  final ValueChanged<String> onSelect;
  final VoidCallback onRun;
  final String? localError;
  final bool disabled;
  const CommandsPanel({
    super.key,
    required this.viewModel,
    required this.query,
    required this.onSelect,
    required this.onRun,
    this.localError,
    this.disabled = false,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = viewModel;
    final state =
        vm?.state ??
        const CommandsUnavailable('Commands are unavailable in this view.');
    final matches = vm?.matches(query) ?? const <PaneCommand>[];
    final running = state is CommandsRunning;
    final loading = state is CommandsLoading;
    final error =
        localError ??
        switch (state) {
          CommandsUnavailable(:final message) => message,
          CommandsReady(:final error) => error,
          _ => null,
        };
    final textStyle = context.typo.mono.copyWith(
      color: colors.text,
      fontSize: 12,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              'PANE COMMANDS',
              style: textStyle.copyWith(color: colors.muted, fontSize: 10),
            ),
          ),
          if (loading || running)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      running
                          ? 'Dispatching /${state.name}…'
                          : 'Loading commands from this pane…',
                      style: textStyle,
                    ),
                  ),
                ],
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error,
                style: textStyle.copyWith(color: colors.warning),
              ),
            ),
          if (!loading && !running && state is CommandsReady) ...[
            if (matches.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No matching commands on this pane.',
                  style: textStyle.copyWith(color: colors.muted),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final command = matches[index];
                  return Material(
                    color: colors.surface,
                    child: ListTile(
                      minTileHeight: 48,
                      dense: true,
                      title: Text(
                        '/${command.name}',
                        style: textStyle.copyWith(
                          color: command.executable
                              ? colors.text
                              : colors.muted,
                        ),
                      ),
                      subtitle: Text(
                        command.executable
                            ? '${command.description}${command.busyPolicy == 'follow_up'
                                  ? '\nQueues after the current turn'
                                  : command.busyPolicy == 'idle_only'
                                  ? '\nRequires an idle pane'
                                  : ''}'
                            : command.disabledReason ?? command.description,
                        style: textStyle.copyWith(
                          fontSize: 11,
                          color: colors.muted,
                        ),
                      ),
                      onTap: disabled || !command.executable
                          ? null
                          : () => onSelect(command.name),
                    ),
                  );
                },
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: disabled || running || loading || vm == null
                      ? null
                      : vm.refresh,
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  child: const Text('Refresh'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed:
                      disabled || running || loading || state is! CommandsReady
                      ? null
                      : onRun,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    minimumSize: const Size(64, 44),
                  ),
                  child: const Text('Run'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
