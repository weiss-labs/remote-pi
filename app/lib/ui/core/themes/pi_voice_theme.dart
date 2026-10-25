import 'package:flutter/material.dart';
import 'themes.dart';

/// Ported from pi-voice/ui/style.css dark variables, not the Herdr palette.
ThemeData buildPiVoiceTheme() {
  final colors = AppColors.dark.copyWith(
    bg: const Color(0xff212121),
    text: const Color(0xffececec),
    muted: const Color(0xff9a9aa0),
    muted2: const Color(0xff9a9aa0),
    border: const Color(0xff38383a),
    surface: const Color(0xff2a2a2c),
    inputFill: const Color(0xff2c2c2e),
    userBubble: const Color(0xff323234),
    accent: const Color(0xff2f5fe3),
    success: const Color(0xff4ade80),
    error: const Color(0xfff87171),
  );
  return buildDarkTheme().copyWith(
    scaffoldBackgroundColor: colors.bg,
    extensions: [
      colors,
      AppTypography(
        mono: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 12,
          height: 1.5,
          color: colors.text,
        ),
        monoSmall: TextStyle(
          fontFamily: '.SF Pro Text',
          fontFamilyFallback: const ['Helvetica Neue', 'sans-serif'],
          fontSize: 12,
          height: 1.5,
          color: colors.muted,
        ),
        sansBody: TextStyle(
          fontFamily: '.SF Pro Text',
          fontFamilyFallback: const ['Helvetica Neue', 'sans-serif'],
          fontSize: 15,
          height: 1.5,
          color: colors.text,
        ),
      ),
    ],
  );
}

/// Exact canvas gradient stops from Pi Voice's draw() function.
const piVoiceCloudBlue = [
  Color(0xff123be7),
  Color(0xff345dec),
  Color(0xff7595ff),
];
const piVoiceCloudWhite = Color(0xffffffff);
