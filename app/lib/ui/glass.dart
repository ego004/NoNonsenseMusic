import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/accent.dart';
import '../core/settings.dart';

/// A restrained backdrop for phone screens, tinted by Colours › Background (the playing cover's colour, by default) as
/// strongly as Surfaces › Main area › Colour strength asks.
class PhoneBackdrop extends StatelessWidget {
  const PhoneBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final look = Look.of(context);
    final dark = scheme.brightness == Brightness.dark;
    final base = dark ? const Color(0xFF10131C) : scheme.surface;
    final colour = switch (look.background) {
      ColourMode.system => null,
      // the accent, as before Background could be chosen: the cover's colour, made readable, or the app's blue
      ColourMode.song => look.song == null ? Accent.standard(scheme.brightness) : Accent.readable(look.song!, scheme.brightness),
      ColourMode.custom => look.backgroundColour,
    };
    // The tint is laid on the surface, not left see-through: nothing is behind this on Android, so a see-through
    // middle drew as black and the light theme's dark text could not be read on it (13 Oct)
    final tint = colour == null ? base : Color.alphaBlend(colour.withValues(alpha: Look.strong(look.artStrength, dark ? 0.16 : 0.12)), base);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? [const Color(0xFF10131C), tint, const Color(0xFF10131C)]
                : [const Color(0xFFF8FAFF), tint, const Color(0xFFF0F3FA)],
            stops: const [0, 0.48, 1],
          ),
        ),
      ),
    );
  }
}

/// Frosted surface for the few floating phone elements: the bottom bar and the player bar over the lists (blurred and
/// filled as Settings › Appearance › Surfaces › Bottom bar asks), cards and panels over the phone's still backdrop (never
/// blurred: under them is only the backdrop, smooth already).
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.blur = 0,
    this.solid = 0,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// The blur of what is under it, as a Gaussian's sigma. At 0 none is drawn: a blur is drawn again with every frame
  /// anything under it moves (a blur of 0 still put a backdrop layer under each card on a phone's Home).
  final double blur;

  /// How much of the see-through part of its tint is filled in: 0, its own (0.76 to 0.72 opaque; 0.82 to 0.72 in the
  /// light theme), to 1, solid ([Look.barSolid]).
  final double solid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    double fill(double own) => own + (1 - own) * solid;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        // a light surface on a light backdrop: an ink line marks its edge, a white one would not show
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.07),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  const Color(0xFF343B50).withValues(alpha: fill(0.76)),
                  const Color(0xFF1B2233).withValues(alpha: fill(0.72)),
                ]
              : [
                  Colors.white.withValues(alpha: fill(0.82)),
                  const Color(0xFFE8EEFA).withValues(alpha: fill(0.72)),
                ],
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.24 : 0.09),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: blur > 0 ? BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: surface) : surface,
      ),
    );
  }
}

/// Phone-only slide and fade used by overlays and tab content.
Widget phoneRevealTransition(
  Widget child,
  Animation<double> animation, {
  double dy = 0.06,
}) {
  final curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset(0, dy),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
  );
}
