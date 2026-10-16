import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/download_store.dart';
import '../core/models.dart';
import '../core/reveal.dart';
import 'browse_nav.dart';
import 'cover.dart';
import 'glass_menu.dart';
import 'layout.dart';
import 'playlist_screen.dart';
import 'scope.dart';
import 'waiting.dart';

/// A single song row: cover, title, explicit badge, artists, like button and length.
///
/// Double-clicking the row plays the song with the rest of [queue] as the queue.
/// Right-clicking opens a menu: Play, Play Next, Add to Queue, Like.
class SongRow extends StatefulWidget {
  final List<Track> queue;
  final int index;

  /// In a playlist: its item ids and queue name, so its edits reach the playing queue, plus a "Remove from …" entry.
  final List<String>? keys;
  final String? source;
  final ({String name, VoidCallback remove})? removeFrom;
  const SongRow({
    super.key,
    required this.queue,
    required this.index,
    this.keys,
    this.source,
    this.removeFrom,
    this.number,
  });

  /// An album's track number, shown in place of the cover (every cover on an album is the same).
  final int? number;

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
    final phone = isPhone(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    void play() => s.player.play(
      widget.queue,
      startAt: widget.index,
      keys: widget.keys,
      source: widget.source,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: GestureDetector(
        // a touch screen plays on a tap, a mouse on a double-click: by platform, not width (layout.dart)
        onTap: isTouchDevice ? play : null,
        onDoubleTap: isTouchDevice ? null : play,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition, track, play),
        onLongPressStart: (d) => _menu(
          context,
          d.globalPosition,
          track,
          play,
        ), // a phone has no right button
        // Aligned to the top so the row keeps its own height: a list gives each row its whole extent, and the row
        // filled it, leaving no gap between a phone's cards
        child: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder(
          valueListenable: s.player.currentId,
          builder: (context, _, row) => AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: songRowExtent(context) - songRowGap(context),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            // the concept (13 Oct): an album's playing song is picked out in the accent, as in Apple Music
            color: widget.number != null && (s.player.current?.isSameSong(track) ?? false)
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : phone
                ? theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.38 : 0.7,
                  )
                : hovering
                ? theme.colorScheme.onSurface.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(phone ? 16 : widget.number != null ? 12 : 8),
            border: phone
                ? Border.all(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.055),
                  )
                : null,
          ),
          child: row,
          ),
          child: Row(
            children: [
              // The cover plays the song on tap; the overlay marks the song that is currently playing.
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: play,
                  child: widget.number != null
                      ? _Number(number: widget.number!, track: track, hovering: hovering)
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            Cover(track.image, size: 40),
                            _PlayingMark(track: track, hovering: hovering),
                          ],
                        ),
                ),
              ),
              SizedBox(width: widget.number != null ? 10 : 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: _Title(track: track)),
                        if (track.isExplicit)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: ExplicitBadge(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _DownloadedMark(track: track, color: muted),
                        Expanded(
                          child: Text(
                            track.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // One copy: where it plays from, in the place "N listings" takes for songs found on several sources.
              // Left out on a phone, where the title needs the room.
              if (!phone)
                _Listings(
                  track: track,
                  queue: widget.queue,
                  index: widget.index,
                  keys: widget.keys,
                  source: widget.source,
                ),
              ListenableBuilder(
                listenable: s.library,
                builder: (context, _) => Opacity(
                  opacity: s.library.isLiked(track) || hovering || phone ? 1 : 0,
                  child: LikeButton(track: track, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: textWidth(context, 44, 12.5),
                child: Text(
                  formatTime(track.duration.toDouble()),
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  void _menu(BuildContext context, Offset at, Track track, VoidCallback play) => showSongMenu(
    context,
    at,
    track,
    play: play,
    queueable: true,
    remove: widget.removeFrom == null
        ? null
        : (label: 'Remove from “${widget.removeFrom!.name}”', run: widget.removeFrom!.remove),
  );
}

/// A song's menu, the same wherever a song is offered: a row (right-click, long-press), an Up Next row, the playing
/// song's "…". [play] comes first, with Play Next and Add to Queue when [queueable]; [remove] comes last.
Future<void> showSongMenu(
  BuildContext context,
  Offset at,
  Track track, {
  VoidCallback? play,
  bool queueable = false,
  ({String label, VoidCallback run})? remove,
}) async {
  final s = Scope.of(context);
  final liked = s.library.isLiked(track);
  // the concept (15 Oct): on the player's glass, coming in as the Genius window does (glass_menu.dart)
  final chosen = await showGlassMenu<String>(context, at, [
    if (play != null) ...[
      const GlassMenuEntry('play', 'Play'),
      if (queueable) ...[
        const GlassMenuEntry('next', 'Play Next'),
        const GlassMenuEntry('queue', 'Add to Queue'),
      ],
      const GlassMenuEntry.divider(),
    ],
    GlassMenuEntry('like', liked ? 'Remove from Liked' : 'Like'),
    const GlassMenuEntry('playlist', 'Add to Playlist…'),
    const GlassMenuEntry.divider(),
    if (DownloadStore.shared.folder != null)
      if (DownloadStore.shared.isDownloading(track))
        const GlassMenuEntry.disabled('Downloading…')
      else
        GlassMenuEntry('download', DownloadStore.shared.isDownloaded(track) ? 'Remove Download' : 'Download'),
    if (canShowInFolder && DownloadStore.shared.folder != null && DownloadStore.shared.isDownloaded(track))
      const GlassMenuEntry('reveal', 'Show in Folder'),
    if (track.artists.isNotEmpty) const GlassMenuEntry('artist', 'Go to Artist'),
    if (track.albumTitle != null) const GlassMenuEntry('album', 'Go to Album'),
    if (remove != null) ...[
      const GlassMenuEntry.divider(),
      GlassMenuEntry('remove', remove.label),
    ],
  ]);
  if (!context.mounted) return;
  switch (chosen) {
    case 'play':
      play?.call();
    case 'next':
      s.player.playNext(track);
    case 'queue':
      s.player.addToQueue(track);
    case 'like':
      s.library.toggleLike(track);
    case 'download':
      DownloadStore.shared.isDownloaded(track)
          ? DownloadStore.shared.remove(track)
          : DownloadStore.shared.download(track);
    case 'reveal':
      final file = DownloadStore.shared.fileFor(track);
      if (file != null) showInFolder(file);
    case 'artist':
      openBrowse(context, ArtistNamed(track.artists.first));
    case 'album':
      openBrowse(
        context,
        AlbumNamed(track.albumTitle!, track.artists.firstOrNull ?? ''),
      );
    case 'remove':
      remove?.run();
    case 'playlist':
      final to = await showGlassMenu<String>(context, at, [
        const GlassMenuEntry('+', 'New Playlist…'),
        const GlassMenuEntry.divider(),
        // Only playlists the user can edit: a viewer cannot add songs, and the server answers 403.
        for (final p in s.library.playlists.where((p) => p.canEdit)) GlassMenuEntry(p.id, p.name),
      ]);
      if (to == null || !context.mounted) return;
      if (to == '+') {
        final name = await askName(
          context,
          title: 'New Playlist with “${track.title}”',
        );
        if (name != null) await s.library.createPlaylist(name, adding: track);
      } else {
        await s.library.add(track, to);
      }
  }
}

/// The heart: liked or not, a click switches it.
class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.track, this.size = 20});
  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final library = Scope.of(context).library;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final liked = library.isLiked(track);
        return IconButton(
          icon: Icon(
            liked ? FluentIcons.heart_24_filled : FluentIcons.heart_24_regular,
            size: size,
          ),
          color: liked
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
          tooltip: liked ? 'Remove from Liked' : 'Like',
          onPressed: () => library.toggleLike(track),
        );
      },
    );
  }
}

/// "…" beside the playing song's heart (Now Playing, the player bar): its menu, as a row's right-click has.
class SongMoreButton extends StatelessWidget {
  const SongMoreButton({super.key, required this.track, this.size = 20});
  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(FluentIcons.more_horizontal_24_regular, size: size),
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
    tooltip: 'More: Add to Playlist, Download',
    onPressed: () {
      final box = context.findRenderObject() as RenderBox;
      showSongMenu(context, box.localToGlobal(box.size.bottomLeft(Offset.zero)), track);
    },
  );
}

/// A small arrow before the artists on a downloaded song, a spinner while it downloads.
class _DownloadedMark extends StatelessWidget {
  final Track track;
  final Color color;
  const _DownloadedMark({required this.track, required this.color});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: DownloadStore.shared,
    builder: (context, _) {
      final store = DownloadStore.shared;
      if (store.isDownloading(track)) {
        // the still hourglass, not a spinner: a spinner redraws at the screen rate for as long as the song
        // downloads, and Download All keeps one on screen for minutes (Waiting has the measurement)
        return const Padding(
          padding: EdgeInsets.only(right: 5),
          child: Waiting(size: 11, tooltip: 'Downloading…'),
        );
      }
      if (!store.isDownloaded(track)) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: 'Downloaded: plays without the server or the internet',
          child: Icon(
            FluentIcons.arrow_circle_down_24_filled,
            size: 13,
            color: color,
          ),
        ),
      );
    },
  );
}

/// The song title, in the accent colour while the song plays. Only this widget redraws when the song changes.
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
        return Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: playing ? Theme.of(context).colorScheme.primary : null,
          ),
        );
      },
    );
  }
}

/// An overlay on the cover: a speaker on the playing song, a play icon under the pointer on the others.
class _PlayingMark extends StatelessWidget {
  final Track track;
  final bool hovering;
  const _PlayingMark({required this.track, required this.hovering});
  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    return ValueListenableBuilder(
      valueListenable: player.currentId,
      builder: (context, _, _) {
        final playing = player.current?.isSameSong(track) ?? false;
        if (!playing && !hovering) return const SizedBox.shrink();
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            playing
                ? FluentIcons.speaker_2_24_filled
                : FluentIcons.play_24_filled,
            size: 18,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

/// An album row's number: the playing song shows bars in the accent instead (still, never animated), and a play
/// icon takes its place under the pointer.
class _Number extends StatelessWidget {
  final int number;
  final Track track;
  final bool hovering;
  const _Number({required this.number, required this.track, required this.hovering});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = Scope.of(context).player.current?.isSameSong(track) ?? false;
    return SizedBox(
      width: 34,
      height: 40,
      child: Center(
        child: playing
            ? Icon(FluentIcons.data_bar_vertical_24_filled, size: 18, color: theme.colorScheme.primary)
            : hovering
                ? Icon(FluentIcons.play_24_filled, size: 16, color: theme.colorScheme.onSurface)
                : Text('$number', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.42), fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    );
  }
}

/// A small "E" badge marking the explicit version of a song.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'E',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.surface,
        ),
      ),
    );
  }
}

/// Where the song plays from. A song with one copy shows its source's name; one found on several sources shows
/// "N listings", and a tap lists every copy, to play exactly the one wanted. The rest of the list still follows it.
class _Listings extends StatelessWidget {
  final Track track;
  final List<Track> queue;
  final int index;
  final List<String>? keys;
  final String? source;
  const _Listings({
    required this.track,
    required this.queue,
    required this.index,
    this.keys,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.6);
    final style = TextStyle(fontSize: 12, color: muted);
    if (track.listings.length <= 1) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(track.best.sourceName, style: style),
      );
    }
    return Builder(
      builder: (context) => TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          foregroundColor: muted,
        ),
        onPressed: () async {
          final box = context.findRenderObject() as RenderBox;
          final at = box.localToGlobal(Offset(0, box.size.height));
          final chosen = await showMenu<Listing>(
            context: context,
            position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
            items: [
              for (final l in track.listings)
                PopupMenuItem(
                  value: l,
                  child: Text(
                    '${l.sourceName} · ${l.quality}${l == track.listings.first ? ' · Default' : ''}\n'
                    '${l.artists.join(', ')} · ${formatTime(l.duration.toDouble())}${l.explicit == true ? ' · Explicit' : ''}',
                  ),
                ),
            ],
          );
          if (chosen == null || !context.mounted) return;
          final list = [...queue];
          list[index] = track.playing(chosen);
          Scope.of(context).player
              .play(list, startAt: index, keys: keys, source: source);
        },
        child: Text('${track.listings.length} listings', style: style),
      ),
    );
  }
}
