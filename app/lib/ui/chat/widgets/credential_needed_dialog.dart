import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Instructions only. This view never collects or transmits a secret.
class CredentialNeededDialog extends StatelessWidget {
  const CredentialNeededDialog({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: const Text('Complete sign-in on your Mac'),
      content: SingleChildScrollView(
        child: Text(
          '1. Open the requesting pane on your Mac.\n\n'
          '2. Complete the sign-in or credential approval there. If 1Password or Touch ID is waiting, approve it on that Mac.\n\n'
          '3. Return to this pane and resume the task.\n\n'
          'Unlocking 1Password on your phone does not unlock your Mac. Do not paste passwords, API keys or recovery codes into chat.',
          style: context.typo.mono.copyWith(color: colors.text, fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          child: const Text('Understood'),
        ),
      ],
    );
  }
}
