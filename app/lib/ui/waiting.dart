import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// "Working on it", still. Flutter's spinner (CircularProgressIndicator) redraws at the screen's full rate: a song
/// loading for a few seconds took ~40% of a core (measured 8 Oct, Release). A still mark costs nothing.
class Waiting extends StatelessWidget {
  final double size;
  final String tooltip;
  const Waiting({super.key, this.size = 18, this.tooltip = 'Loading…'});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Icon(FluentIcons.hourglass_half_24_regular, size: size, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
      );
}
