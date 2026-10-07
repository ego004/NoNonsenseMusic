import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'cover.dart';
import 'lyrics_panel.dart';
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
    final ink = theme.colorScheme.onSurface;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => p.setShowNowPlaying(false)},
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: p,
          builder: (context, _) {
            final t = p.current;
            if (t == null) return const SizedBox.shrink();
            return Stack(fit: StackFit.expand, children: [
              ColoredBox(color: theme.colorScheme.surface),
              // the cover's colours as a wash: the cover at 12 pixels, stretched by the GPU. A real blur would be
              // redrawn with every frame; this is one small texture
              if (t.image != null)
                Opacity(
                  opacity: theme.brightness == Brightness.dark ? 0.55 : 0.4,
                  child: Image.network(t.image!, fit: BoxFit.cover, cacheWidth: 12, cacheHeight: 12, filterQuality: FilterQuality.high, gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink()),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
                    theme.colorScheme.surface.withValues(alpha: 0.35),
                    theme.colorScheme.surface.withValues(alpha: 0.75),
                  ]),
                ),
              ),
              LayoutBuilder(builder: (context, box) {
                final side = (box.maxHeight - 330).clamp(180.0, 500.0).toDouble();
                return Stack(children: [
                  Positioned(
                    left: 24, top: 18,
                    child: IconButton(tooltip: 'Close (Esc)', iconSize: 20, onPressed: () => p.setShowNowPlaying(false), icon: const Icon(FluentIcons.chevron_down_24_regular)),
                  ),
                  // the panel beside the song; press the showing one again and the song is alone
                  Positioned(
                    right: 24, top: 18,
                    child: Row(children: [
                      for (final (id, icon, label) in [('lyrics', FluentIcons.comment_quote_24_regular, 'Lyrics'), ('upNext', FluentIcons.text_bullet_list_ltr_24_regular, 'Up Next')])
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: IconButton(
                            tooltip: p.panel == id ? 'Hide $label' : 'Show $label',
                            iconSize: 20,
                            style: IconButton.styleFrom(backgroundColor: p.panel == id ? ink.withValues(alpha: 0.1) : Colors.transparent),
                            color: p.panel == id ? theme.colorScheme.primary : ink.withValues(alpha: 0.75),
                            onPressed: () => p.setPanel(id),
                            icon: Icon(icon),
                          ),
                        ),
                    ]),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                          width: side,
                          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            DecoratedBox(
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [
                                BoxShadow(blurRadius: 40, offset: const Offset(0, 18), color: Colors.black.withValues(alpha: 0.35)),
                              ]),
                              child: Cover(t.image, size: side, radius: 14),
                            ),
                            const SizedBox(height: 26),
                            Row(children: [
                              Flexible(child: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.15))),
                              if (t.isExplicit) const Padding(padding: EdgeInsets.only(left: 8), child: ExplicitBadge()),
                            ]),
                            const SizedBox(height: 4),
                            Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: ink.withValues(alpha: 0.62))),
                            const SizedBox(height: 18),
                            Progress(key: ValueKey('np${t.id}')),
                            const SizedBox(height: 10),
                            const Transport(size: 22, play: 52),
                            const SizedBox(height: 14),
                            Center(child: Volume(width: side * 0.45)),
                          ]),
                        ),
                        if (p.panel != 'none') ...[
                          const SizedBox(width: 56),
                          Container(
                            width: 340,
                            height: (box.maxHeight - 140).clamp(300.0, 560.0).toDouble(),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: ink.withValues(alpha: 0.06)),
                            ),
                            padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
                            child: p.panel == 'lyrics' ? const LyricsPanel() : const UpNext(),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ]);
              }),
            ]);
          },
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
    // listens itself: as a const child it kept the queue it was first built with
    return ListenableBuilder(listenable: p, builder: (context, _) {
    final entries = p.queue.upcoming;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(6, 2, 6, 10), child: Text('Up Next', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
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
      ]);
    });
  }
}
