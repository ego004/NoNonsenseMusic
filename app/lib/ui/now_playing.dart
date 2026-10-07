import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'cover.dart';
import 'player_bar.dart';
import 'scope.dart';
import 'song_row.dart';

/// Full-window Now Playing: the cover large, the song, progress, controls, and Up Next beside it (drag to reorder,
/// double-click to play, ✕ to remove). Esc or the chevron closes it.
class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => p.setShowNowPlaying(false)},
      child: Focus(
        autofocus: true,
        child: Container(
          color: theme.colorScheme.surface,
          child: ListenableBuilder(
            listenable: p,
            builder: (context, _) {
              final t = p.current;
              if (t == null) return const SizedBox.shrink();
              return LayoutBuilder(builder: (context, box) {
                final side = (box.maxHeight - 300).clamp(160.0, 520.0).toDouble();
                return Stack(children: [
                  Positioned(
                    left: 20, top: 16,
                    child: IconButton.filledTonal(tooltip: 'Close (Esc)', onPressed: () => p.setShowNowPlaying(false), icon: const Icon(FluentIcons.chevron_down_24_regular)),
                  ),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                        width: side,
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Cover(t.image, size: side, radius: 16),
                          const SizedBox(height: 20),
                          Row(children: [
                            Flexible(child: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
                            if (t.isExplicit) const Padding(padding: EdgeInsets.only(left: 6), child: ExplicitBadge()),
                          ]),
                          Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                          const SizedBox(height: 8),
                          Progress(key: ValueKey('np${t.id}')),
                          const Transport(size: 28, play: 44),
                        ]),
                      ),
                      const SizedBox(width: 48),
                      const SizedBox(width: 340, height: 520, child: UpNext()),
                    ]),
                  ),
                ]);
              });
            },
          ),
        ),
      ),
    );
  }
}

class UpNext extends StatelessWidget {
  const UpNext({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final entries = p.queue.upcoming;
    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(6, 4, 6, 8), child: Text('Up Next', style: theme.textTheme.titleMedium)),
        Expanded(
          child: entries.isEmpty
              ? Padding(padding: const EdgeInsets.all(6), child: Text('Nothing queued. Play a list, or right-click a song → Play Next or Add to Queue.', style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.55))))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: entries.length,
                  onReorderItem: (from, to) => p.moveUpNext(from, to), // `to`: its place once moved, as the queue counts
                  itemBuilder: (context, i) {
                    final t = entries[i].track;
                    return ReorderableDragStartListener(
                      key: ValueKey(entries[i].key),
                      index: i,
                      child: GestureDetector(
                        onDoubleTap: () => p.jump(p.queue.index + 1 + i),
                        child: ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                          leading: Cover(t.image, size: 36),
                          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(iconSize: 16, tooltip: 'Remove from Up Next', onPressed: () => p.removeFromUpNext(i), icon: const Icon(FluentIcons.dismiss_circle_24_filled)),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
