import 'package:flutter/material.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Weiss Labs: pane search box with a clear (X) button while it has text.
class PaneSearchField extends StatefulWidget {
  const PaneSearchField({
    super.key,
    required this.query,
    required this.onChanged,
  });
  final String query;
  final ValueChanged<String> onChanged;

  @override
  State<PaneSearchField> createState() => PaneSearchFieldState();
}

class PaneSearchFieldState extends State<PaneSearchField> {
  late final _controller = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        style: context.typo.mono,
        decoration: InputDecoration(
          hintText: 'Search panes',
          hintStyle: TextStyle(color: colors.muted, fontFamily: kMonoFamily),
          prefixIcon: Icon(LucideIcons.search, color: colors.muted, size: 18),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: Icon(LucideIcons.x, color: colors.muted, size: 18),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: colors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: colors.border),
          ),
        ),
      ),
    );
  }
}
