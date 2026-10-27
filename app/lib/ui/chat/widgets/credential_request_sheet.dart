import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compact private credential form. Shows exactly which 1Password item to
/// open, takes the value through a masked field (AutoFill-friendly) or a
/// user-gesture Paste that preserves multiline text exactly, and hands the
/// raw bytes to [onSubmit]. Plaintext lives only in this State and is zeroed
/// on submit, cancel, background and dispose. Nothing here logs or persists.
class CredentialRequestSheet extends StatefulWidget {
  final CredentialRequest request;
  final String? error;
  final bool submitting;
  final Future<void> Function(Uint8List secret) onSubmit;
  final Future<void> Function() onCancel;

  const CredentialRequestSheet({
    super.key,
    required this.request,
    required this.onSubmit,
    required this.onCancel,
    this.error,
    this.submitting = false,
  });

  @override
  State<CredentialRequestSheet> createState() => _CredentialRequestSheetState();
}

class _CredentialRequestSheetState extends State<CredentialRequestSheet>
    with WidgetsBindingObserver {
  final TextEditingController _field = TextEditingController();
  Uint8List? _pasted;
  int _pastedLines = 0;
  String? _localError;
  // Bumped by every wipe: a Clipboard read that completes after the app went
  // to background (or after cancel/dispose) is dropped and zeroed.
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app (e.g. to 1Password) drops any plaintext already typed;
    // the pending request itself stays so the form is still here on return.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wipe();
      if (mounted) setState(() {});
    }
  }

  void _wipe() {
    _epoch++;
    final p = _pasted;
    if (p != null) p.fillRange(0, p.length, 0);
    _pasted = null;
    _pastedLines = 0;
    _field.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wipe();
    _field.dispose();
    super.dispose();
  }

  bool get _hasValue => _pasted != null || _field.text.isNotEmpty;

  Future<void> _paste() async {
    final epoch = _epoch;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || epoch != _epoch) return; // late completion: drop it
    if (text == null || text.isEmpty) {
      setState(() => _localError = 'Clipboard has no text.');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(text));
    setState(() {
      _wipe();
      _localError = null;
      _pasted = bytes;
      _pastedLines = text.trimRight().split('\n').length;
    });
  }

  Future<void> _submit() async {
    if (widget.submitting || !_hasValue) return;
    final bytes = _pasted ?? Uint8List.fromList(utf8.encode(_field.text));
    _pasted = null; // ownership moves to onSubmit, which zeroes it
    _field.clear();
    setState(() {
      _pastedLines = 0;
      _localError = null;
    });
    await widget.onSubmit(bytes);
  }

  Future<void> _cancel() async {
    _wipe();
    await widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final r = widget.request;
    final minutesLeft =
        ((r.expiresAt - DateTime.now().millisecondsSinceEpoch) / 60000)
            .ceil()
            .clamp(0, 60);
    final error = widget.error ?? _localError;

    return PopScope(
      canPop: false,
      // Cancel/back stay available while a submit is unconfirmed: a lost ACK
      // must never trap the user until the request expires.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Material(
        color: colors.bg,
        child: SafeArea(
          child: Scaffold(
            backgroundColor: colors.bg,
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              backgroundColor: colors.bg,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
                onPressed: _cancel,
              ),
              title: const Text('Credential needed'),
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Text(r.label, style: text.titleMedium),
                const SizedBox(height: 10),
                _SourceRow(reference: r.reference),
                const SizedBox(height: 8),
                Text(
                  r.purpose,
                  style: text.bodySmall?.copyWith(color: colors.muted),
                ),
                const SizedBox(height: 16),
                if (_pasted == null)
                  TextField(
                    key: const ValueKey('credential-field'),
                    controller: _field,
                    enabled: !widget.submitting,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    autofillHints: const [AutofillHints.password],
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() => _localError = null),
                    onSubmitted: (_) => _submit(),
                    style: context.typo.mono.copyWith(color: colors.text),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Paste or AutoFill the value',
                      hintStyle: TextStyle(color: colors.muted),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  )
                else
                  _PastedSummary(
                    bytes: _pasted!.length,
                    lines: _pastedLines,
                    onClear: widget.submitting ? null : () => setState(_wipe),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('credential-paste'),
                      onPressed: widget.submitting ? null : _paste,
                      icon: const Icon(LucideIcons.clipboardPaste, size: 16),
                      label: const Text('Paste'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(44, 44),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Keeps multi-line keys exact.',
                        style: text.labelSmall?.copyWith(color: colors.muted),
                      ),
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error,
                    key: const ValueKey('credential-error'),
                    style: text.bodySmall?.copyWith(color: colors.error),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  'Encrypted for this Mac only; the relay never sees it. '
                  'Written to a private temporary file on the Mac and '
                  'deleted after ~15 min. Request expires in $minutesLeft min.',
                  style: text.labelSmall?.copyWith(
                    color: colors.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
            bottomNavigationBar: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('credential-cancel'),
                      onPressed: _cancel,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('credential-use'),
                        onPressed: widget.submitting || !_hasValue
                            ? null
                            : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(44, 44),
                        ),
                        child: widget.submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Use for this task'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final String reference;
  const _SourceRow({required this.reference});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.keyRound, size: 14, color: colors.accent),
              const SizedBox(width: 6),
              Text(
                'Find in 1Password',
                style: text.labelSmall?.copyWith(color: colors.accent),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            reference,
            style: context.typo.monoSmall.copyWith(color: colors.text),
          ),
        ],
      ),
    );
  }
}

class _PastedSummary extends StatelessWidget {
  final int bytes, lines;
  final VoidCallback? onClear;
  const _PastedSummary({
    required this.bytes,
    required this.lines,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('credential-pasted'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.inputFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '•••••••• pasted ($bytes bytes, $lines line${lines == 1 ? '' : 's'})',
              style: text.bodySmall?.copyWith(color: colors.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(minimumSize: const Size(44, 36)),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
