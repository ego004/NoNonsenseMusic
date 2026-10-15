import 'dart:io';

import 'package:flutter/material.dart';

import '../core/accent.dart';

/// Builds the application theme for the given brightness and playing cover colour.
///
/// Surfaces are neutral greys with no tint. The accent is read from the cover when [song] is provided and falls
/// back to Windows 11's default blue otherwise. Ripples are removed because a desktop app answers a click rather
/// than splashing, and hovers stay quiet. The font is the system's, which is Segoe UI Variable Text on Windows.
/// Type leans on weight and size rather than colour.
ThemeData buildTheme(Brightness b, Color? song) {
  final dark = b == Brightness.dark;
  final mobile = Platform.isAndroid || Platform.isIOS;
  final accent = song != null
      ? Accent.readable(song, b)
      : (dark
            ? const Color(0xFF60CDFF)
            : const Color(0xFF005FB8)); // Windows 11's default accent
  final surface = mobile
      ? (dark ? const Color(0xFF111722) : const Color(0xFFF5F7FC))
      : (dark ? const Color(0xFF1B1B1D) : const Color(0xFFF7F7F8));
  final ink = dark ? const Color(0xFFF2F2F3) : const Color(0xFF16161A);
  final scheme = ColorScheme(
    brightness: b,
    primary: accent,
    onPrimary: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : Colors.black,
    secondary: accent,
    onSecondary: Colors.white,
    error: const Color(0xFFD13438),
    onError: Colors.white,
    surface: surface,
    onSurface: ink,
    surfaceContainerHighest: mobile
        ? (dark ? const Color(0xFF273247) : Colors.white)
        : (dark ? const Color(0xFF2A2A2D) : const Color(0xFFFFFFFF)),
    outline: ink.withValues(alpha: 0.12),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
    fontFamily: Platform.isWindows ? 'Segoe UI Variable Text' : null,
    visualDensity: mobile ? VisualDensity.standard : VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: ink.withValues(alpha: 0.05),
    focusColor: accent.withValues(alpha: 0.2),
    scaffoldBackgroundColor: surface,
  );
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      headlineLarge: t.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleLarge: t.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      // small text needs 4.5 to 1 against the surface: 0.58 gave about 4.4 on the light one, 0.66 gives 5.7
      bodySmall: t.bodySmall?.copyWith(color: ink.withValues(alpha: 0.66)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(mobile ? 16 : 6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: BorderSide(color: ink.withValues(alpha: 0.16)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(mobile ? 16 : 6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: ink.withValues(alpha: 0.85)),
    ),
    inputDecorationTheme: mobile
        ? InputDecorationTheme(
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(
              alpha: dark ? 0.35 : 0.64,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 15,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: ink.withValues(alpha: 0.08)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: ink.withValues(alpha: 0.08)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: accent, width: 1.5),
            ),
          )
        : null,
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: ink.withValues(alpha: 0.14),
      thumbColor: accent,
      trackHeight: 3,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
    ),
    // A tooltip as Windows 11 draws one: a dark bubble with white text in the dark theme, a white one with dark text in
    // the light. Its text colour is set here: left to the scheme's inverse colours, the dark theme's text was as dark as
    // its bubble (unreadable everywhere, #20). An edge and a shadow keep it apart from any backdrop, a cover's included.
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2B2B2E) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.1)),
        boxShadow: [BoxShadow(blurRadius: 12, offset: const Offset(0, 4), color: Colors.black.withValues(alpha: dark ? 0.4 : 0.14))],
      ),
      textStyle: TextStyle(color: dark ? Colors.white : const Color(0xFF1B1B1F), fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: mobile ? 64 : 64,
      elevation: 0,
      backgroundColor: mobile
          ? Colors.transparent
          : Color.alphaBlend(ink.withValues(alpha: 0.04), surface),
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 22,
          color: ink.withValues(
            alpha: s.contains(WidgetState.selected) ? 1 : 0.65,
          ),
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((s) {
        final on = s.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
          color: ink.withValues(alpha: on ? 1 : 0.65),
        );
      }),
    ),
    dividerTheme: DividerThemeData(
      color: ink.withValues(alpha: 0.08),
      space: 1,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: mobile
          ? scheme.surfaceContainerHighest
          : (dark ? const Color(0xFF2C2C2E) : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(mobile ? 18 : 8),
      ),
      elevation: 8,
    ),
  );
}
