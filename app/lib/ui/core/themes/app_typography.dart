import 'package:flutter/material.dart';

import 'package:app/ui/core/themes/app_colors.dart';

/// Monospace font family — used for code, terminal-style chrome, and most of
/// the app's UI text (the product's "coding agent" identity).
///
/// Resolved by the platform, never bundled or downloaded.
const String kMonoFamily = 'Menlo';

/// Body text inherits the platform-resolved theme family when null.
const String? kSansFamily = null;

/// Brand wordmark preserves the existing mono treatment, using the OS font.
/// Pass the brightness-appropriate color from `context.colors.text`.
TextStyle brandTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w700,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: kMonoFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Typographic styles for the app, themed per brightness (colors baked in so
/// the common case — `context.typo.mono` — is correct without a `.copyWith`).
///
/// This is the SINGLE source of truth for text styles. Widgets read
/// `context.typo.<style>` and `.copyWith(...)` only for one-off size/weight
/// tweaks — never re-declaring `fontFamily`.
///
/// Registered on [ThemeData.extensions]; resolve via
/// `Theme.of(context).extension<AppTypography>()`.
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.mono,
    required this.monoSmall,
    required this.sansBody,
  });

  /// Primary monospace style (chat code, terminal chrome). Was `kMonoStyle`.
  final TextStyle mono;

  /// Small monospace style (captions, metadata). Was `kMonoSmall`.
  final TextStyle monoSmall;

  /// Sans body text. Was `kSansBody`.
  final TextStyle sansBody;

  /// Build the style set for a given color palette so text colors track the
  /// active theme. [monoColor] is the resting mono text color (was the
  /// hardcoded `0xFFE6E6E6` in dark).
  factory AppTypography.fromColors(AppColors c, {required Color monoColor}) {
    return AppTypography(
      mono: TextStyle(
        fontFamily: kMonoFamily,
        fontSize: 13,
        color: monoColor,
        height: 1.5,
        letterSpacing: 0,
      ),
      monoSmall: TextStyle(
        fontFamily: kMonoFamily,
        fontSize: 11.0,
        color: c.muted2,
        height: 1.4,
      ),
      sansBody: TextStyle(
        fontFamily: kSansFamily,
        fontSize: 14.0,
        color: c.text,
        height: 1.5,
        letterSpacing: 0,
      ),
    );
  }

  /// Dark typography — mono text matches the original `0xFFE6E6E6`.
  static final AppTypography dark = AppTypography.fromColors(
    AppColors.dark,
    monoColor: AppColors.dark.text,
  );

  /// Light typography — mono text is a near-black for contrast on white.
  static final AppTypography light = AppTypography.fromColors(
    AppColors.light,
    monoColor: const Color(0xFF1A1A1A),
  );

  @override
  AppTypography copyWith({
    TextStyle? mono,
    TextStyle? monoSmall,
    TextStyle? sansBody,
  }) {
    return AppTypography(
      mono: mono ?? this.mono,
      monoSmall: monoSmall ?? this.monoSmall,
      sansBody: sansBody ?? this.sansBody,
    );
  }

  @override
  AppTypography lerp(ThemeExtension<AppTypography>? other, double t) {
    if (other is! AppTypography) return this;
    return AppTypography(
      mono: TextStyle.lerp(mono, other.mono, t)!,
      monoSmall: TextStyle.lerp(monoSmall, other.monoSmall, t)!,
      sansBody: TextStyle.lerp(sansBody, other.sansBody, t)!,
    );
  }
}
