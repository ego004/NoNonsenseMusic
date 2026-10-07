import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// A cover with rounded corners, decoded at the size shown (a full-size decode per list row was the Mac app's
/// biggest memory cost, 7 Oct). A grey square with a note while it loads or when there is none.
class Cover extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  const Cover(this.url, {super.key, required this.size, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      child: Icon(FluentIcons.music_note_2_24_regular, size: size * 0.4, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? placeholder
          : Image.network(url!, width: size, height: size, fit: BoxFit.cover, cacheWidth: px, cacheHeight: px,
              gaplessPlayback: true, errorBuilder: (_, _, _) => placeholder, frameBuilder: (_, child, frame, sync) => frame == null && !sync ? placeholder : child),
    );
  }
}
