import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import 'glass_menu.dart';
import 'scope.dart';

/// Where the playing song plays from ("YouTube Music · AAC 128 kbps"). With more than one copy it is a menu of every
/// copy: choosing one plays it from the same second, and the cover and the queue stay as they are.
class CopyMenu extends StatelessWidget {
  final Track track;
  final TextStyle? style;
  const CopyMenu({super.key, required this.track, this.style});

  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    final base = (style ?? const TextStyle(fontSize: 13)).copyWith(color: muted);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final playing = player.playingListing ?? track.best;
        final label = Text('${playing.sourceName} · ${playing.quality}', maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
        if (track.listings.length < 2) return Tooltip(message: 'The only place this song plays from', child: label);
        return GlassMenuButton<Listing>(
          tooltip: 'Play another copy of this song',
          onSelected: player.switchCopy,
          width: 300,
          entries: () => [
            for (final l in track.listings)
              GlassMenuEntry(l, '${l.sourceName} · ${l.quality}',
                  detail: '${l.artists.join(', ')} · ${formatTime(l.duration.toDouble())}${l.explicit == true ? ' · Explicit' : ''}',
                  checked: l.key == playing.key),
          ],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: label),
            const SizedBox(width: 2),
            Icon(FluentIcons.chevron_down_24_regular, size: 14, color: muted),
          ]),
        );
      },
    );
  }
}
