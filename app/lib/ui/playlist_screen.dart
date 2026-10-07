import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'home.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// One playlist: cover, name, count, Play, Shuffle, ⋯ (Rename, Delete), the songs. Drag a song by its grip to move
/// it; double-click plays; right-click has Remove from the playlist.
class PlaylistScreen extends StatefulWidget {
  final String id;
  final VoidCallback onDeleted;
  const PlaylistScreen({super.key, required this.id, required this.onDeleted});
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  bool gone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Scope.of(context).library.loadPlaylist(widget.id).then((ok) {
      if (mounted && !ok) setState(() => gone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    if (gone) return const Center(child: Text('This playlist is gone. It was deleted, maybe on another device.'));
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final d = s.library.details[widget.id];
        if (d == null) return const Center(child: Waiting(size: 28));
        final tracks = d.tracks;
        final covers = tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList();
        final minutes = (d.items.fold<int>(0, (a, i) => a + i.$2.duration) / 60).round();
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
            sliver: SliverToBoxAdapter(
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                PlaylistCover(covers: covers, size: 172, name: d.summary.name),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('PLAYLIST', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
                    Text(d.summary.name, maxLines: 2, style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
                    Text('${d.items.length} songs · $minutes min', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    Row(children: [
                      FilledButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource),
                          icon: const Icon(FluentIcons.play_24_filled, size: 18), label: const Text('Play')),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource, shuffled: true),
                          icon: const Icon(FluentIcons.arrow_shuffle_24_regular, size: 18), label: const Text('Shuffle')),
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        icon: const Icon(FluentIcons.more_horizontal_24_regular),
                        itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename…')), PopupMenuItem(value: 'delete', child: Text('Delete…'))],
                        onSelected: (v) async {
                          if (v == 'rename') {
                            final name = await askName(context, title: 'Rename Playlist', initial: d.summary.name);
                            if (name != null) await s.library.renamePlaylist(d.summary.id, name);
                          } else if (await confirm(context, 'Delete “${d.summary.name}”?', 'Its songs stay in your library.')) {
                            await s.library.deletePlaylist(d.summary.id);
                            widget.onDeleted();
                          }
                        },
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No songs yet. Right-click any song › Add to Playlist.'))))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
              sliver: SliverReorderableList(
                itemCount: d.items.length,
                onReorderItem: (from, to) => s.library.moveItem(d.summary.id, from, to),
                itemBuilder: (_, i) => Row(
                  key: ValueKey(d.items[i].$1),
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: const MouseRegion(cursor: SystemMouseCursors.grab, child: Padding(padding: EdgeInsets.all(6), child: Icon(FluentIcons.re_order_dots_vertical_24_regular, size: 16))),
                    ),
                    Expanded(
                      child: SizedBox(height: 58, child: SongRow(queue: tracks, index: i, keys: d.keys, source: d.queueSource,
                          removeFrom: (name: d.summary.name, remove: () => s.library.remove(d.items[i].$1, d.summary.id)))),
                    ),
                  ],
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// New Playlist and Rename: a name, or null.
Future<String?> askName(BuildContext context, {required String title, String initial = ''}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: field, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, field.text.trim().isEmpty ? null : field.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String detail) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(title: Text(title), content: Text(detail), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
      ]),
    ) ??
    false;
