import 'dart:io';

import 'package:flutter/material.dart';

import '../core/accent.dart';

/// The look: neutral greys (no tinted surfaces), the accent from the playing cover (else Windows' own blue), no
/// ripples (a desktop app answers a click, it does not splash), quiet hovers, the system's font (Segoe UI Variable
/// on Windows), and type that leans on weight and size rather than colour.
ThemeData buildTheme(Brightness b, Color? song) {
  final dark = b == Brightness.dark;
  final accent = song != null ? Accent.readable(song, b) : (dark ? const Color(0xFF60CDFF) : const Color(0xFF005FB8)); // Windows 11's default accent
  final surface = dark ? const Color(0xFF1B1B1D) : const Color(0xFFF7F7F8);
  final ink = dark ? const Color(0xFFF2F2F3) : const Color(0xFF16161A);
  final scheme = ColorScheme(
    brightness: b,
    primary: accent,
    onPrimary: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black,
    secondary: accent,
    onSecondary: Colors.white,
    error: const Color(0xFFD13438),
    onError: Colors.white,
    surface: surface,
    onSurface: ink,
    surfaceContainerHighest: dark ? const Color(0xFF2A2A2D) : const Color(0xFFFFFFFF),
    outline: ink.withValues(alpha: 0.12),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
    fontFamily: Platform.isWindows ? 'Segoe UI Variable Text' : null,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: ink.withValues(alpha: 0.05),
    focusColor: accent.withValues(alpha: 0.2),
    scaffoldBackgroundColor: surface,
  );
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      bodySmall: t.bodySmall?.copyWith(color: ink.withValues(alpha: 0.58)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: BorderSide(color: ink.withValues(alpha: 0.16)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: ink.withValues(alpha: 0.85))),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: ink.withValues(alpha: 0.14),
      thumbColor: accent,
      trackHeight: 3,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
    ),
    tooltipTheme: TooltipThemeData(waitDuration: const Duration(milliseconds: 600), decoration: BoxDecoration(color: dark ? const Color(0xFF2C2C2E) : const Color(0xFF16161A), borderRadius: BorderRadius.circular(4))),
    dividerTheme: DividerThemeData(color: ink.withValues(alpha: 0.08), space: 1),
    popupMenuTheme: PopupMenuThemeData(color: dark ? const Color(0xFF2C2C2E) : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), elevation: 8),
  );
}
