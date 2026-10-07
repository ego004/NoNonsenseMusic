import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import 'cover.dart';
import 'playlist_screen.dart';
import 'scope.dart';

/// One song: cover, title (🅴 when explicit), artists, heart, length. Double-click plays it with the rest of the list
/// as the queue; right-click: Play, Play Next, Add to Queue, Like.
class SongRow extends StatefulWidget {
  final List<Track> queue;
  final int index;
  /// In a playlist: its item ids and queue name (its edits reach a playing queue), and "Remove from …".
  final List<String>? keys;
  final String? source;
  final ({String name, VoidCallback remove})? removeFrom;
  const SongRow({super.key, required this.queue, required this.index, this.keys, this.source, this.removeFrom});

  @override
  State<SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<SongRow> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final track = widget.queue[widget.index];
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    void play() => s.player.play(widget.queue, startAt: widget.index, keys: widget.keys, source: widget.source);
    return MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: GestureDetector(
        onDoubleTap: play,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition, track, play),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: hovering ? theme.colorScheme.onSurface.withValues(alpha: 0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            GestureDetector(onTap: play, child: Cover(track.image, size: 40)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: _Title(track: track)),
                  if (track.isExplicit) const Padding(padding: EdgeInsets.only(left: 4), child: ExplicitBadge()),
                ]),
                Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
            ),
            ListenableBuilder(
              listenable: s.library,
              builder: (context, _) {
                final liked = s.library.isLiked(track);
                return Opacity(
                  opacity: liked || hovering ? 1 : 0,
                  child: IconButton(
                    icon: Icon(liked ? FluentIcons.heart_24_filled : FluentIcons.heart_24_regular, size: 18),
                    color: liked ? theme.colorScheme.primary : muted,
                    tooltip: liked ? 'Remove from Liked' : 'Like',
                    onPressed: () => s.library.toggleLike(track),
                  ),
                );
              },
            ),
            SizedBox(width: 48, child: Text(formatTime(track.duration.toDouble()), textAlign: TextAlign.right, style: theme.textTheme.bodySmall?.copyWith(color: muted))),
          ]),
        ),
      ),
    );
  }

  void _menu(BuildContext context, Offset at, Track track, VoidCallback play) async {
    final s = Scope.of(context);
    final liked = s.library.isLiked(track);
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play')),
        const PopupMenuItem(value: 'next', child: Text('Play Next')),
        const PopupMenuItem(value: 'queue', child: Text('Add to Queue')),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'like', child: Text(liked ? 'Remove from Liked' : 'Like')),
        const PopupMenuItem(value: 'playlist', child: Text('Add to Playlist…')),
        if (widget.removeFrom != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: 'remove', child: Text('Remove from “${widget.removeFrom!.name}”')),
        ],
      ],
    );
    if (!context.mounted) return;
    switch (chosen) {
      case 'play':
        play();
      case 'next':
        s.player.playNext(track);
      case 'queue':
        s.player.addToQueue(track);
      case 'like':
        s.library.toggleLike(track);
      case 'remove':
        widget.removeFrom?.remove();
      case 'playlist':
        final to = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
          items: [
            const PopupMenuItem(value: '+', child: Text('New Playlist…')),
            const PopupMenuDivider(),
            for (final p in s.library.playlists) PopupMenuItem(value: p.id, child: Text(p.name)),
          ],
        );
        if (to == null || !context.mounted) return;
        if (to == '+') {
          final name = await askName(context, title: 'New Playlist with “${track.title}”');
          if (name != null) await s.library.createPlaylist(name, adding: track);
        } else {
          await s.library.add(track, to);
        }
    }
  }
}

/// The title, in the accent colour while this song plays: only this redraws when the song changes.
class _Title extends StatelessWidget {
  final Track track;
  const _Title({required this.track});
  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    return ValueListenableBuilder(
      valueListenable: player.currentId,
      builder: (context, _, _) {
        final playing = player.current?.isSameSong(track) ?? false;
        return Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: playing ? Theme.of(context).colorScheme.primary : null));
      },
    );
  }
}

/// 🅴: the explicit version.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
      child: Text('E', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.surface)),
    );
  }
}
