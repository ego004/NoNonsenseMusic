import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/catalog.dart';
import '../core/models.dart';
import '../core/search_model.dart';
import 'browse_nav.dart';
import 'concept.dart';
import 'cover.dart';
import 'layout.dart';
import 'scope.dart';

/// Artist names, each one a link to that artist's page, separated by commas. One line; a name that does not fit is
/// cut at its end like any text.
class ArtistLinks extends StatefulWidget {
  final List<String> artists;
  final TextStyle? style;
  const ArtistLinks({super.key, required this.artists, this.style});
  @override
  State<ArtistLinks> createState() => _ArtistLinksState();
}

class _ArtistLinksState extends State<ArtistLinks> {
  List<TapGestureRecognizer> _taps = [];
  int? _hovered;

  /// The line for each artist under the pointer (null: none), each made once and given again. The pointer's enter and
  /// exit follow the span object: a span made anew at each build was a new one under a resting pointer, so its exit
  /// and enter set the state again, which built new spans, at every frame, for as long as the pointer rested on a name
  /// in the player bar (15 Oct: 60 frames a second, most of a core under the cover glow). The taps made at each build
  /// were never released either: only the list they were never put in was.
  final _spans = <int?, TextSpan>{};

  void _release() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps = [];
    _spans.clear();
  }

  @override
  void didUpdateWidget(ArtistLinks old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.artists, widget.artists)) _release();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  TextSpan _line(int? hovered) {
    if (_taps.isEmpty) {
      _taps = [for (final name in widget.artists) TapGestureRecognizer()..onTap = () => openBrowse(context, ArtistNamed(name))];
    }
    return TextSpan(children: [
      for (final (i, name) in widget.artists.indexed) ...[
        TextSpan(
          text: name,
          style: hovered == i ? const TextStyle(decoration: TextDecoration.underline) : null,
          recognizer: _taps[i],
          mouseCursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (_hovered != i) setState(() => _hovered = i);
          },
          onExit: (_) {
            if (_hovered == i) setState(() => _hovered = null);
          },
        ),
        if (i < widget.artists.length - 1) const TextSpan(text: ', '),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => Text.rich(
        _spans.putIfAbsent(_hovered, () => _line(_hovered)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
}

/// Play and Shuffle for a list of songs, as on Liked Songs.
class PlayShuffleButtons extends StatelessWidget {
  final List<Track> tracks;
  const PlayShuffleButtons({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    return Wrap(spacing: 10, runSpacing: 8, children: [
      ActionPill(
        icon: FluentIcons.play_24_filled,
        label: 'Play',
        filled: true,
        onTap: tracks.isEmpty ? null : () => player.play(tracks, wholeList: true),
      ),
      ActionPill(
        icon: FluentIcons.arrow_shuffle_24_regular,
        label: 'Shuffle',
        onTap: tracks.isEmpty ? null : () => player.play(tracks, shuffled: true, wholeList: true),
      ),
    ]);
  }
}

/// Search's filter: capsules in a row (they wrap on a narrow screen), the chosen one filled.
class FilterCapsules extends StatelessWidget {
  final SearchFilter selection;
  final ValueChanged<SearchFilter> onChanged;
  const FilterCapsules({super.key, required this.selection, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // On a phone a capsule takes taps 8 above and below what is drawn (48 in all), in place of the gap between lines
    final reach = isPhone(context) ? 8.0 : 0.0;
    return Wrap(spacing: 8, runSpacing: 8 - reach, children: [
      for (final f in SearchFilter.values)
        Semantics(
          button: true,
          selected: f == selection,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(f),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: reach),
                child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: isPhone(context) ? 7 : 6),
                decoration: BoxDecoration(
                  color: f == selection ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(f.title,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: f == selection ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
              ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// The height of a card's text under its picture: [lines] lines at [size] points, scaled with the user's text size.
double _textBlock(BuildContext context, List<double> sizes) {
  final scaler = MediaQuery.textScalerOf(context);
  return sizes.fold<double>(0, (a, s) => a + scaler.scale(s) * 1.45) + 4;
}

/// An album's cover, title, and year or artist. A tap opens it.
class AlbumCard extends StatelessWidget {
  final AlbumRef album;
  final double side;
  const AlbumCard({super.key, required this.album, required this.side});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => openBrowse(context, AlbumTarget(album)),
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            width: side,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Cover(album.image, size: side, radius: 10),
              const SizedBox(height: 8),
              Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(album.year?.toString() ?? album.artists.join(', '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12)),
            ]),
          ),
        ),
      );

  /// The card's height: the cover, the gap and two lines of text.
  static double heightFor(BuildContext context, double side) => side + 8 + _textBlock(context, [14, 12]);
}

/// An artist's round picture with the name under it. A tap opens the artist.
class ArtistBubble extends StatelessWidget {
  final SearchArtist artist;
  final double size;
  const ArtistBubble({super.key, required this.artist, this.size = 96});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => openBrowse(context, ArtistTarget(artist.best)),
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            width: size + 14,
            child: Column(children: [
              Cover(artist.picture, size: size, radius: size / 2),
              const SizedBox(height: 8),
              Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );

  static double heightFor(BuildContext context, double size) => size + 8 + _textBlock(context, [14]);
}

/// Albums as a grid of covers that fills the width; lazy. Used as a sliver.
class AlbumGrid extends StatelessWidget {
  final List<AlbumRef> albums;
  const AlbumGrid({super.key, required this.albums});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, box) {
          const gap = 18.0, wish = 150.0;
          final across = ((box.crossAxisExtent + gap) / (wish + gap)).floor().clamp(1, 12);
          final side = (box.crossAxisExtent - gap * (across - 1)) / across;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: across, crossAxisSpacing: gap, mainAxisSpacing: 22, mainAxisExtent: AlbumCard.heightFor(context, side)),
            itemCount: albums.length,
            itemBuilder: (_, i) => AlbumCard(album: albums[i], side: side),
          );
        },
      );
}

/// Artists as a grid of round pictures that fills the width; lazy. Used as a sliver.
class ArtistGrid extends StatelessWidget {
  final List<SearchArtist> artists;
  const ArtistGrid({super.key, required this.artists});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, box) {
          const gap = 18.0, size = 96.0, cell = size + 14;
          final across = ((box.crossAxisExtent + gap) / (cell + gap)).floor().clamp(1, 20);
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: across, crossAxisSpacing: gap, mainAxisSpacing: 22, mainAxisExtent: ArtistBubble.heightFor(context, size)),
            itemCount: artists.length,
            itemBuilder: (_, i) => Align(alignment: Alignment.topCenter, child: ArtistBubble(artist: artists[i])),
          );
        },
      );
}

/// Albums in one row that scrolls sideways (Search's results); built lazily.
class AlbumShelf extends StatelessWidget {
  final List<AlbumRef> albums;
  const AlbumShelf({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    const side = 128.0;
    return SizedBox(
      height: AlbumCard.heightFor(context, side) + 8,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: isPhone(context) ? gutter(context) : 24),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (_, i) => AlbumCard(album: albums[i], side: side),
      ),
    );
  }
}

/// Artists in one row that scrolls sideways (Search's results): round pictures with the name under them.
class ArtistShelf extends StatelessWidget {
  final List<SearchArtist> artists;
  const ArtistShelf({super.key, required this.artists});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: ArtistBubble.heightFor(context, 96) + 8,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          // a bubble is 7 wider than its picture on each side: the first picture, not its box, stands on the gutter
          padding: EdgeInsets.symmetric(horizontal: isPhone(context) ? gutter(context) - 7 : 24),
          itemCount: artists.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => ArtistBubble(artist: artists[i]),
        ),
      );
}
