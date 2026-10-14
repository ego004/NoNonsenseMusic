import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/catalog.dart';
import 'browse_nav.dart';
import 'browse_widgets.dart';
import 'cover.dart';
import 'layout.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// The page for a [BrowseTarget]: an artist's or an album's.
class BrowsePage extends StatelessWidget {
  final BrowseTarget target;
  const BrowsePage({super.key, required this.target});

  @override
  Widget build(BuildContext context) => switch (target) {
        ArtistTarget(:final ref) => ArtistPage(key: ValueKey(target), load: () => Catalog.artist(ref)),
        ArtistNamed(:final name) => ArtistPage(
            key: ValueKey(target),
            load: () async {
              final ref = await Catalog.artistNamed(name);
              if (ref == null) throw ApiProblem('No artist called “$name” was found.');
              return Catalog.artist(ref);
            }),
        AlbumTarget(:final ref) => AlbumPage(key: ValueKey(target), load: () => Catalog.album(ref)),
        AlbumNamed(:final title, :final artist) => AlbumPage(
            key: ValueKey(target),
            load: () async {
              final ref = await Catalog.albumNamed(title, artist);
              if (ref == null) throw ApiProblem('No album called “$title” was found.');
              return Catalog.album(ref);
            }),
      };
}

/// A reason a page cannot open that is worded to be shown as it is.
class ApiProblem implements Exception {
  final String text;
  ApiProblem(this.text);
  @override
  String toString() => text;
}

/// Loads a page's data once, then shows it, or says why it cannot.
class _Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final String failTitle;
  final IconData failIcon;
  final Widget Function(T) page;
  const _Loader({required this.load, required this.failTitle, required this.failIcon, required this.page});
  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> {
  late final Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasData) return widget.page(snap.data as T);
          if (!snap.hasError) return const Center(child: Waiting(size: 28));
          final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.failIcon, size: 44, color: muted),
                const SizedBox(height: 10),
                Text(widget.failTitle, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('${snap.error}', textAlign: TextAlign.center, style: TextStyle(color: muted)),
              ]),
            ),
          );
        },
      );
}

/// Opens an artist from [load] and shows [ArtistView].
class ArtistPage extends StatelessWidget {
  final Future<ArtistDetail> Function() load;
  const ArtistPage({super.key, required this.load});
  @override
  Widget build(BuildContext context) => _Loader<ArtistDetail>(
      load: load, failTitle: "Can't open this artist", failIcon: FluentIcons.person_24_regular, page: (a) => ArtistView(artist: a));
}

/// Opens an album from [load] and shows [AlbumView].
class AlbumPage extends StatelessWidget {
  final Future<AlbumDetail> Function() load;
  const AlbumPage({super.key, required this.load});
  @override
  Widget build(BuildContext context) => _Loader<AlbumDetail>(
      load: load, failTitle: "Can't open this album", failIcon: FluentIcons.album_24_regular, page: (a) => AlbumView(album: a));
}

/// The width under which a header stacks its picture above the text.
const _narrow = 560.0;

TextStyle _title(BuildContext context, double size) =>
    TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.15, color: Theme.of(context).colorScheme.onSurface);

Widget _section(BuildContext context, String text, double side) => SliverToBoxAdapter(
    child: Padding(
        padding: EdgeInsets.fromLTRB(side, 22, side, 10),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))));

/// An artist's page: their picture and name, Play and Shuffle for their top songs, the top songs, then their albums.
class ArtistView extends StatelessWidget {
  final ArtistDetail artist;
  const ArtistView({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    final tracks = artist.songs;
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < _narrow;
      final side = narrow ? 20.0 : 32.0;
      final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
      final picture = Cover(artist.image, size: narrow ? 130 : 150, radius: narrow ? 65 : 75);
      final text = Column(
        crossAxisAlignment: narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Text(artist.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: narrow ? TextAlign.center : TextAlign.start, style: _title(context, narrow ? 28 : 34)),
          if (artist.audience != null) ...[
            const SizedBox(height: 6),
            Text(artist.audience!, style: TextStyle(fontSize: 14, color: muted)),
          ],
          const SizedBox(height: 14),
          PlayShuffleButtons(tracks: tracks),
        ],
      );
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 20, side, 6),
          sliver: SliverToBoxAdapter(
            child: narrow
                ? Column(children: [picture, const SizedBox(height: 16), text])
                : Row(children: [picture, const SizedBox(width: 22), Expanded(child: text)]),
          ),
        ),
        if (tracks.isNotEmpty) ...[
          _section(context, 'Top Songs', side),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: narrow ? side : side - 10),
            sliver: SliverFixedExtentList.builder(
              itemExtent: songRowExtent(context),
              itemCount: tracks.length < 10 ? tracks.length : 10,
              itemBuilder: (_, i) => SongRow(queue: tracks, index: i),
            ),
          ),
        ],
        if (artist.albums.isNotEmpty) ...[
          _section(context, 'Albums', side),
          SliverPadding(padding: EdgeInsets.fromLTRB(side, 0, side, bottomClearance(context, extra: 20)), sliver: AlbumGrid(albums: artist.albums)),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 140)), // keeps the last row clear of the player bar
      ]);
    });
  }
}

/// An album's page: the cover, title and artists, Play, Shuffle and Pin to Home, then the songs in order.
class AlbumView extends StatefulWidget {
  final AlbumDetail album;
  const AlbumView({super.key, required this.album});
  @override
  State<AlbumView> createState() => _AlbumViewState();
}

class _AlbumViewState extends State<AlbumView> {
  bool _pinning = false;

  Future<void> _togglePin() async {
    final library = Scope.of(context).library;
    final ref = widget.album.ref;
    final pinned = library.pinned(ref);
    setState(() => _pinning = true);
    final problem = pinned == null ? await library.pin(ref) : await library.unpin(pinned);
    if (!mounted) return;
    setState(() => _pinning = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(problem ??
            (pinned == null ? 'Pinned “${ref.title}” to Home' : 'Unpinned “${ref.title}”'))));
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final tracks = album.songs;
    final library = Scope.of(context).library;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final facts = [
      if (album.year != null) '${album.year}',
      '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
      if (album.minutes > 0) '${album.minutes} min',
    ].join(' · ');
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < _narrow;
      final side = narrow ? 20.0 : 32.0;
      final cover = DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [
          BoxShadow(blurRadius: 14, offset: const Offset(0, 8), color: Colors.black.withValues(alpha: 0.2)),
        ]),
        child: Cover(album.cover, size: narrow ? 160 : 180, radius: 12),
      );
      final align = narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start;
      final text = Column(crossAxisAlignment: align, mainAxisSize: MainAxisSize.min, children: [
        Text(album.title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: narrow ? TextAlign.center : TextAlign.start, style: _title(context, narrow ? 24 : 30)),
        const SizedBox(height: 4),
        ArtistLinks(artists: album.artists, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface.withValues(alpha: 0.8))),
        const SizedBox(height: 4),
        Text(facts, style: TextStyle(fontSize: 13.5, color: muted)),
        const SizedBox(height: 14),
        ListenableBuilder(
          listenable: library,
          builder: (context, _) {
            final pinned = library.pinned(album.ref) != null;
            return Wrap(spacing: 10, runSpacing: 8, alignment: narrow ? WrapAlignment.center : WrapAlignment.start, children: [
              FilledButton.icon(
                onPressed: tracks.isEmpty ? null : () => Scope.of(context).player.play(tracks, wholeList: true),
                icon: const Icon(FluentIcons.play_24_filled, size: 18),
                label: const Text('Play'),
              ),
              OutlinedButton.icon(
                onPressed: tracks.isEmpty ? null : () => Scope.of(context).player.play(tracks, shuffled: true, wholeList: true),
                icon: const Icon(FluentIcons.arrow_shuffle_24_regular, size: 18),
                label: const Text('Shuffle'),
              ),
              Tooltip(
                message: pinned ? 'Remove this album from Home' : 'Keep this album on Home',
                child: OutlinedButton.icon(
                  onPressed: _pinning ? null : _togglePin,
                  icon: Icon(pinned ? FluentIcons.pin_24_filled : FluentIcons.pin_24_regular, size: 18),
                  label: Text(pinned ? 'Pinned' : 'Pin to Home'),
                ),
              ),
            ]);
          },
        ),
      ]);
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 20, side, 18),
          sliver: SliverToBoxAdapter(
            child: narrow
                ? Column(children: [cover, const SizedBox(height: 16), text])
                : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [cover, const SizedBox(width: 22), Expanded(child: text)]),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(narrow ? side : side - 10, 0, narrow ? side : side - 10, bottomClearance(context, extra: 20)),
          sliver: SliverFixedExtentList.builder(
            itemExtent: songRowExtent(context),
            itemCount: tracks.length,
            itemBuilder: (_, i) => SongRow(queue: tracks, index: i),
          ),
        ),
      ]);
    });
  }
}
