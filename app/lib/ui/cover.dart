import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/download_store.dart';

/// A square cover image with rounded corners, decoded at the size it is shown at.
///
/// A full-size decode per list row is the largest memory cost in a scrolling list of covers,
/// so the decode size is capped to the displayed size in device pixels. Shows a grey square
/// with a music note while the image loads, when the URL is missing, or when decoding fails.
/// A cover's image: the file a download keeps for it when there is one (it shows offline), else the network.
ImageProvider coverProvider(String url) {
  final kept = DownloadStore.shared.keptCover(url);
  return kept != null ? FileImage(kept) : NetworkImage(url);
}

class Cover extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  final BoxFit fit;
  const Cover(this.url, {super.key, required this.size, this.radius = 6, this.fit = BoxFit.cover});

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
          : Image(image: ResizeImage.resizeIfNeeded(px, px, coverProvider(url!)), width: size, height: size, fit: fit,
              // gaplessPlayback keeps the previous frame while the new one decodes, so rapid
              // scrolling does not flash the placeholder.
              gaplessPlayback: true, errorBuilder: (_, _, _) => placeholder, frameBuilder: (_, child, frame, sync) => frame == null && !sync ? placeholder : child),
    );
  }
}
