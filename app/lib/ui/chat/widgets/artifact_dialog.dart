import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app/domain/contracts/artifact_preview.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';

class ArtifactDialog extends StatefulWidget {
  const ArtifactDialog({super.key, required this.url, required this.viewModel});
  final String url;
  final ChatViewModel viewModel;
  @override
  State<ArtifactDialog> createState() => _ArtifactDialogState();
}

class _ArtifactDialogState extends State<ArtifactDialog> {
  double _progress = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await widget.viewModel.previewArtifact(widget.url, (value) {
        if (mounted) setState(() => _progress = value);
      });
      if (mounted) Navigator.of(context).pop();
    } on ArtifactFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  void dispose() {
    unawaited(widget.viewModel.cancelArtifact());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_error == null ? 'File preview' : 'Preview unavailable'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error == null) LinearProgressIndicator(value: _progress),
        const SizedBox(height: 12),
        Text(
          _error ??
              (_progress < 1
                  ? 'Retrieving from your paired pane…'
                  : 'Verifying and opening private preview…'),
          style: context.typo.sansBody,
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(_error == null ? 'Cancel' : 'Close'),
      ),
    ],
  );
}
