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
      title: const Text('Desktop authorization required'),
      content: SingleChildScrollView(
        child: Text(
          'Read the requesting pane’s notice for the exact approval needed.\n\n'
          'Integrations intended to run remotely should use unattended credentials scoped to that integration, configured on the Mac.\n\n'
          'This app does not transfer passwords or approve desktop Touch ID. Unlocking 1Password on your phone does not unlock your Mac.\n\n'
          'If interactive authorization is required, complete it on the affected Mac, then retry from the pane. This notice alone does not unblock the task.\n\n'
          'Do not paste passwords, API keys or recovery codes into chat.',
          style: context.typo.mono.copyWith(color: colors.text, fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          child: const Text('Back to pane'),
        ),
      ],
    );
  }
}
