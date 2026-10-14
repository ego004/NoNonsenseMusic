import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'cover.dart';
import 'glass.dart';
import 'layout.dart';
import 'scope.dart';

/// The first screen, laid out as on the Mac: a greeting, then "Jump back in" as a sideways shelf of recently played
/// covers, the user's playlists, and Liked Songs as compact rows three high. Shelves scroll only sideways; nothing
/// animates.
class Home extends StatelessWidget {
  final void Function(String playlistId) openPlaylist;
  const Home({super.key, required this.openPlaylist});

  static String greeting(DateTime t) => t.hour < 5
      ? 'Good night'
      : t.hour < 12
      ? 'Good morning'
      : t.hour < 17
      ? 'Good afternoon'
      : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final lib = s.library;
        final recent = lib.recent.map((x) => x.track).take(20).toList();
        final liked = lib.liked.map((x) => x.track).toList();
        final phone = isPhone(context);
        final cardSize = phone
            ? (MediaQuery.sizeOf(context).width - 52) / 2
            : 148.0;
        final side = gutter(context);
        // The list itself has no side padding: the shelves scroll to the window's edge, and everything else is
        // inset by the gutter. Inside padded sides, a shelf's cards were cut off short of the edge (13 Oct)
        Widget inset(Widget child) => Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: child,
        );
        // a tile's two lines of text under its cover, at the user's text size
        final scaler = MediaQuery.textScalerOf(context);
        final tileText = (scaler.scale(14) + scaler.scale(12)) * 1.45;
        Widget title(String t) => Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 10),
          child: Text(
            t,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        return ListView(
          padding: EdgeInsets.only(
            top: phone ? phoneTop : 28,
            bottom: bottomClearance(context),
          ),
          children: [
            inset(
              Text(
                greeting(DateTime.now()),
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SizedBox(height: phone ? 20 : 28),
            if (!lib.reachable)
              inset(
                const _Note(
                  'Can\'t reach your server',
                  'Your library lives on it.',
                  FluentIcons.plug_disconnected_24_regular,
                ),
              )
            else if (recent.isEmpty && liked.isEmpty && lib.playlists.isEmpty)
              inset(
                const _Note(
                  'Your music lives here',
                  'Search for a song you love, then play it, like it, or add it to a playlist.',
                  FluentIcons.music_note_2_24_regular,
                ),
              ),
            if (recent.isNotEmpty) ...[
              title('Jump back in'),
              SizedBox(
                // the cover and the gaps around it, then the text
                height: 172 + tileText,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none, // a card's shadow falls below the shelf: cut off, it drew as a band
                  padding: EdgeInsets.symmetric(horizontal: side),
                  itemCount: recent.length,
                  separatorBuilder: (_, _) => SizedBox(width: phone ? 12 : 20),
                  itemBuilder: (_, i) => _CoverTile(
                    track: recent[i],
                    onPlay: () => s.player.play(
                      lib.recent.map((x) => x.track).toList(),
                      startAt: i,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
            if (lib.ownPlaylistsOnly.isNotEmpty) ...[
              title('Your playlists'),
              inset(
                Wrap(
                  spacing: phone ? 12 : 22,
                  runSpacing: phone ? 12 : 22,
                  children: [
                    for (final p in lib.ownPlaylistsOnly)
                      _PlaylistCard(
                        playlist: p,
                        size: cardSize,
                        onOpen: () => openPlaylist(p.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
            if (lib.pinnedAlbums.isNotEmpty) ...[
              title('Pinned Albums'),
              inset(
                Wrap(
                  spacing: phone ? 12 : 22,
                  runSpacing: phone ? 12 : 22,
                  children: [
                    for (final p in lib.pinnedAlbums)
                      _PlaylistCard(
                        playlist: p,
                        size: cardSize,
                        onOpen: () => openPlaylist(p.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
            if (lib.sharedPlaylists.isNotEmpty) ...[
              title('Shared with you'),
              inset(
                Wrap(
                  spacing: phone ? 12 : 22,
                  runSpacing: phone ? 12 : 22,
                  children: [
                    for (final p in lib.sharedPlaylists)
                      _PlaylistCard(
                        playlist: p,
                        size: cardSize,
                        onOpen: () => openPlaylist(p.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
            if (liked.isNotEmpty) ...[
              title('Liked Songs'),
              SizedBox(
                height: 3 * 62,
                child: GridView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: side),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    // a phone shows most of a column and a clear part of the next (a 300-point column left a clipped
                    // cover)
                    mainAxisExtent: phone ? (MediaQuery.sizeOf(context).width - 2 * side) * 0.86 : 300,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: liked.take(24).length,
                  itemBuilder: (_, i) => _CompactTile(
                    track: liked[i],
                    onPlay: () => s.player.play(liked, startAt: i),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _CoverTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  const _CoverTile({required this.track, required this.onPlay});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onPlay,
    child: isPhone(context)
        ? GlassSurface(
            blur: false,
            radius: 20,
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: 148,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Cover(track.image, size: 148, radius: 14),
                  const SizedBox(height: 8),
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    track.artistLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          )
        : SizedBox(
            width: 148,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Cover(track.image, size: 148, radius: 10),
                const SizedBox(height: 8),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
  );
}

class _PlaylistCard extends StatefulWidget {
  final PlaylistSummary playlist;
  final VoidCallback onOpen;
  final double size;
  const _PlaylistCard({
    required this.playlist,
    required this.size,
    required this.onOpen,
  });
  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  PlaylistSummary get playlist => widget.playlist;
  VoidCallback get onOpen => widget.onOpen;

  // The cover is made from the songs' covers, so the songs are loaded when the card first shows and again when the
  // count changes, as on the Mac. Only pinned albums loaded theirs: a playlist of 121 songs showed a blank cover (13 Oct)
  @override
  void initState() {
    super.initState();
    _loadIfStale();
  }

  @override
  void didUpdateWidget(_PlaylistCard old) {
    super.didUpdateWidget(old);
    if (old.playlist.songCount != playlist.songCount) _loadIfStale();
  }

  void _loadIfStale() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final library = Scope.of(context).library;
    if (library.details[playlist.id]?.tracks.length != playlist.songCount) {
      library.loadPlaylist(playlist.id);
    }
  });

  @override
  Widget build(BuildContext context) {
    final detail = Scope.of(context).library.details[playlist.id];
    final covers =
        detail?.tracks
            .map((t) => t.image)
            .whereType<String>()
            .toSet()
            .take(4)
            .toList() ??
        [];
    return GestureDetector(
      onTap: onOpen,
      child: isPhone(context)
          ? GlassSurface(
              blur: false,
              radius: 20,
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: widget.size - 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlaylistCover(
                      covers: covers,
                      size: widget.size - 16,
                      name: playlist.name,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      songCount(playlist.songCount),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          : SizedBox(
              width: widget.size,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlaylistCover(
                    covers: covers,
                    size: widget.size,
                    name: playlist.name,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    songCount(playlist.songCount),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
    );
  }
}

/// Show a playlist's cover art as up to four covers in a 2x2 grid.
///
/// With one to three covers, show the first alone; with none, show a soft gradient whose hue is derived from the
/// playlist name.
class PlaylistCover extends StatelessWidget {
  final List<String> covers;
  final double size;
  final String name;
  const PlaylistCover({
    super.key,
    required this.covers,
    required this.size,
    required this.name,
  });
  @override
  Widget build(BuildContext context) {
    if (covers.length >= 4) {
      final h = size / 2;
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: size,
          height: size,
          child: Wrap(
            children: [
              for (final c in covers.take(4)) Cover(c, size: h, radius: 0),
            ],
          ),
        ),
      );
    }
    if (covers.isNotEmpty) return Cover(covers.first, size: size, radius: 10);
    final hue = (name.codeUnits.fold(0, (a, b) => a + b) * 37 % 360).toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: [
            HSLColor.fromAHSL(1, hue, 0.45, 0.45).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.3).toColor(),
          ],
        ),
      ),
      child: Icon(
        FluentIcons.music_note_2_24_regular,
        color: Colors.white70,
        size: size * 0.3,
      ),
    );
  }
}

class _CompactTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  const _CompactTile({required this.track, required this.onPlay});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onPlay,
    child: Row(
      children: [
        Cover(track.image, size: 48),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Text(
                track.artistLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  const _Note(this.title, this.detail, this.icon);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      children: [
        Icon(icon, size: 44),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        Text(detail, textAlign: TextAlign.center),
      ],
    ),
  );
}
