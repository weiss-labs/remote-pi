import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Generic credential blocker (no structured request yet). Instructions only:
/// this view never collects or transmits a secret. [onAskPane] sends an
/// ordinary, non-secret instruction so the pane names the exact item through
/// `request_credential`, which opens the private masked form instead.
class CredentialNeededDialog extends StatelessWidget {
  final Future<void> Function()? onAskPane;
  const CredentialNeededDialog({super.key, this.onAskPane});

  /// Plain text the phone sends to the pane. Contains no secret.
  static const askPaneMessage =
      'A credential is blocked. Use the request_credential tool to name the '
      'exact 1Password vault, item and field you need; I will supply it '
      'privately from my phone. Do not ask for the 1Password account '
      'password or Secret Key.';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: const Text('Credential needed'),
      content: SingleChildScrollView(
        child: Text(
          'A pane is blocked on a sign-in or credential and has not named '
          'the exact item yet.\n\n'
          'Ask the pane for the exact 1Password item. It will open a private '
          'form here where you paste that one value; it is encrypted for the '
          'Mac and the relay never sees it.\n\n'
          'This app never asks for your 1Password account password or Secret '
          'Key, and cannot approve desktop Touch ID. Do not paste secrets '
          'into chat.',
          style: context.typo.mono.copyWith(color: colors.text, fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          child: const Text('Back to pane'),
        ),
        if (onAskPane != null)
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await onAskPane!();
            },
            style: FilledButton.styleFrom(minimumSize: const Size(44, 44)),
            child: const Text('Ask pane for exact item'),
          ),
      ],
    );
  }
}
