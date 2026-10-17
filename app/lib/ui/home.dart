import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/download_store.dart';
import '../core/models.dart';
import '../core/settings.dart';
import 'concept.dart';
import 'cover.dart';
import 'glass.dart';
import 'layout.dart';
import 'redesign.dart';
import 'scope.dart';

/// The first screen, laid out as on the Mac: a greeting, then "Jump back in" as a sideways shelf of recently played
/// covers, the user's playlists, and Liked Songs as compact rows three high. Shelves scroll only sideways; nothing
/// animates. On a computer (UI v2, 15 Oct) the greeting is one line over the song playing and Up Next (NowHero), and the
/// playlists are one grid with Liked Songs and Downloads (LibraryShelf).
class Home extends StatelessWidget {
  final void Function(String playlistId) openPlaylist;
  final VoidCallback? openRecent; // Jump back in's "See all"
  final VoidCallback? openLibrary; // Your Library's "See all"
  final void Function(Collection)? openCollection;
  const Home({super.key, required this.openPlaylist, this.openRecent, this.openLibrary, this.openCollection});

  /// The day above the greeting, as Apple Music dates its pages: MONDAY, 13 OCTOBER.
  static String today(DateTime t) =>
      '${const ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'][t.weekday - 1]}, ${t.day} '
      '${const ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'][t.month - 1]}';

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
        // a tile's two lines of text under its cover, at the user's text size; the cover at the card size
        final scaler = MediaQuery.textScalerOf(context);
        final tileText = (scaler.scale(14) + scaler.scale(12)) * 1.45;
        final tile = Look.of(context).cardSize;
        Widget title(String t) => Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 10),
          child: Text(
            t,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              fontFamily: displayFont,
              letterSpacing: -0.3,
            ),
          ),
        );
        // the concept (13 Oct): the greeting, then each shelf, come in one after another when Home opens (once)
        Widget section(String key, int order, List<Widget> children) => Stagger(
          key: ValueKey(key),
          order: order,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        );
        return ListView(
          padding: EdgeInsets.only(
            top: phone ? phoneTop : 8,
            bottom: bottomClearance(context),
          ),
          children: [
            // UI v2 (15 Oct): on a computer, one quiet line of greeting, then the song playing with Up Next beside it
            if (!phone)
              section('greeting', 0, [
                inset(
                  Text(
                    [greeting(DateTime.now()), displayName(s.auth.user?.username ?? '')].where((w) => w.isNotEmpty).join(', '),
                    style: TextStyle(fontFamily: displayFont, fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
                  ),
                ),
                const SizedBox(height: 18),
                inset(const NowHero()),
              ])
            else
            section('greeting', 0, [
              inset(
                Text(
                  today(DateTime.now()),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              inset(
                Text(
                  greeting(DateTime.now()),
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFamily: displayFont,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
            ]),
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
            if (recent.isNotEmpty && !phone) section('recent', 1, [
              ShelfHeading('Jump back in', seeAll: openRecent, padding: EdgeInsets.fromLTRB(side, 0, side - 8, 8)),
              ArrowShelf(
                height: tile + 24 + tileText,
                padding: EdgeInsets.symmetric(horizontal: side),
                itemCount: recent.length,
                itemBuilder: (_, i) => _CoverTile(
                  track: recent[i],
                  onPlay: () => s.player.play(lib.recent.map((x) => x.track).toList(), startAt: i),
                ),
              ),
              const SizedBox(height: 32),
            ]),
            if (recent.isNotEmpty && phone) section('recent', 1, [
              title('Jump back in'),
              SizedBox(
                // the cover and the gaps around it, then the text
                height: tile + 24 + tileText,
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
            ]),
            if (!phone && openCollection != null) section('library', 2, [
              ShelfHeading('Your Library', seeAll: openLibrary, padding: EdgeInsets.fromLTRB(side, 0, side - 8, 10)),
              inset(LibraryShelf(openCollection: openCollection!, openPlaylist: openPlaylist)),
              const SizedBox(height: 32),
            ]),
            // a phone keeps its cards; a computer has them in Your Library above
            if (phone && lib.ownPlaylistsOnly.isNotEmpty) section('own', 2, [
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
            ]),
            if (phone && lib.pinnedAlbums.isNotEmpty) section('pinned', 3, [
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
            ]),
            if (phone && lib.sharedPlaylists.isNotEmpty) section('shared', 4, [
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
            ]),
            if (liked.isNotEmpty) section('liked', 5, [
              if (phone)
                title('Liked Songs')
              else
                ShelfHeading('Liked Songs',
                    seeAll: openCollection == null ? null : () => openCollection!(Collection.liked), padding: EdgeInsets.fromLTRB(side, 0, side - 8, 8)),
              // on a computer it is cut off at the margins, as the rest of the page is
              Container(
                height: 3 * (62 + textGrowth(context, 14 + 12)), // three songs, their two lines at any text size (#20)
                padding: EdgeInsets.symmetric(horizontal: phone ? 0 : side),
                child: GridView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: phone ? side : 0),
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
            ]),
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
  Widget build(BuildContext context) {
    final side = Look.of(context).cardSize;
    return GestureDetector(
    onTap: onPlay,
    child: isPhone(context)
        ? GlassSurface(
            radius: 20,
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: side,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Cover(track.image, size: side, radius: 14),
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
            width: side,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Hovering(track: track, size: side, radius: 10, onPlay: onPlay),
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
    final player = Scope.of(context).player;
    return GestureDetector(
      onTap: onOpen,
      child: isPhone(context)
          ? GlassSurface(
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
                  HoverCover(
                    size: widget.size,
                    onTap: onOpen,
                    // the corner button plays the playlist from its start, once its songs have loaded
                    onPlay: detail == null || detail.tracks.isEmpty
                        ? null
                        : () => player.play(detail.tracks, keys: detail.keys, source: detail.queueSource, wholeList: true),
                    child: PlaylistCover(
                      covers: covers,
                      size: widget.size,
                      name: playlist.name,
                    ),
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
        _Hovering(track: track, size: 48, radius: 6, onPlay: onPlay),
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

/// A song's cover on Home: lifts under the pointer with a play button, and marks the song that is playing.
class _Hovering extends StatelessWidget {
  final Track track;
  final double size, radius;
  final VoidCallback onPlay;
  const _Hovering({required this.track, required this.size, required this.radius, required this.onPlay});
  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    return ValueListenableBuilder(
      valueListenable: player.currentId,
      builder: (context, _, _) => HoverCover(
        size: size,
        radius: radius,
        onTap: onPlay,
        onPlay: onPlay,
        playing: player.current?.isSameSong(track) ?? false,
        child: Cover(track.image, size: size, radius: radius),
      ),
    );
  }
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

/// UI v2 (15 Oct): everything the user has, in one place: Liked Songs, Recently Played and Downloads, then the user's
/// playlists, the albums pinned to Home and the playlists shared with them.
class LibraryScreen extends StatelessWidget {
  final void Function(String id) openPlaylist;
  final void Function(Collection) openCollection;
  const LibraryScreen({super.key, required this.openPlaylist, required this.openCollection});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final side = gutter(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, DownloadStore.shared]),
      builder: (context, _) {
        final lib = s.library;
        Widget heading(String t) => Padding(
              padding: const EdgeInsets.only(top: 28, bottom: 12),
              child: Text(t, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontFamily: displayFont, letterSpacing: -0.3)),
            );
        Widget grid(Iterable<PlaylistSummary> playlists) => Wrap(spacing: 22, runSpacing: 22, children: [
              for (final p in playlists) _PlaylistCard(playlist: p, size: Look.of(context).cardSize, onOpen: () => openPlaylist(p.id)),
            ]);
        return ListView(padding: EdgeInsets.fromLTRB(side, 8, side, bottomClearance(context)), children: [
          Text('Library', style: TextStyle(fontFamily: displayFont, fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: -1, color: theme.colorScheme.onSurface)),
          heading('Collections'),
          Wrap(spacing: 22, runSpacing: 22, children: [
            _CollectionCard(kind: Collection.liked, count: lib.liked.length, onOpen: () => openCollection(Collection.liked)),
            _CollectionCard(kind: Collection.recent, count: lib.recent.length, onOpen: () => openCollection(Collection.recent)),
            if (DownloadStore.shared.folder != null)
              _CollectionCard(kind: Collection.downloads, count: DownloadStore.shared.items.length, onOpen: () => openCollection(Collection.downloads)),
          ]),
          if (lib.ownPlaylistsOnly.isNotEmpty) ...[heading('Playlists'), grid(lib.ownPlaylistsOnly)],
          if (lib.pinnedAlbums.isNotEmpty) ...[heading('Pinned Albums'), grid(lib.pinnedAlbums)],
          if (lib.sharedPlaylists.isNotEmpty) ...[heading('Shared with you'), grid(lib.sharedPlaylists)],
        ]);
      },
    );
  }
}

/// Liked Songs, Recently Played or Downloads as a card: its coloured tile, its name and how many songs.
class _CollectionCard extends StatelessWidget {
  final Collection kind;
  final int count;
  final VoidCallback onOpen;
  const _CollectionCard({required this.kind, required this.count, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final side = Look.of(context).cardSize;
    return GestureDetector(
      onTap: onOpen,
      child: SizedBox(
        width: side,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HoverCover(size: side, onTap: onOpen, child: CollectionTile(kind, size: side)),
          const SizedBox(height: 8),
          Text(kind.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(songs(count), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
