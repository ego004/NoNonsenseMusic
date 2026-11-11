import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/catalog.dart';
import '../core/models.dart';
import 'browse_pages.dart';
import 'concept.dart';
import 'glass.dart';
import 'layout.dart';
import 'phone_page.dart';
import 'scope.dart';

/// A page opened from inside a screen: an artist or an album.
sealed class BrowseTarget {
  const BrowseTarget();
}

class ArtistTarget extends BrowseTarget {
  final ArtistRef ref;
  const ArtistTarget(this.ref);
  @override
  bool operator ==(Object other) => other is ArtistTarget && other.ref == ref;
  @override
  int get hashCode => ref.hashCode;
}

class AlbumTarget extends BrowseTarget {
  final AlbumRef ref;
  const AlbumTarget(this.ref);
  @override
  bool operator ==(Object other) => other is AlbumTarget && other.ref == ref;
  @override
  int get hashCode => ref.hashCode;
}

/// An artist known only by name (a copy with no artist ids): the artist of exactly that name from a search opens.
class ArtistNamed extends BrowseTarget {
  final String name;
  const ArtistNamed(this.name);
  @override
  bool operator ==(Object other) => other is ArtistNamed && other.name == name;
  @override
  int get hashCode => name.hashCode;
}

/// An album known by its title and artist (a song's album): the best match from a search opens.
class AlbumNamed extends BrowseTarget {
  final String title, artist;
  const AlbumNamed(this.title, this.artist);
  @override
  bool operator ==(Object other) =>
      other is AlbumNamed && other.title == title && other.artist == artist;
  @override
  int get hashCode => Object.hash(title, artist);
}

/// The sources whose artist and album ids open a page (GET /artist, /album): plain YouTube's copies carry none.
const _paged = {'jiosaavn', 'ytmusic'};

/// The page of [name], one of [track]'s artists: the artist its copies' own source names (the copy that plays first),
/// else the artist of exactly that name (ArtistNamed). A name alone opened whoever a search put first: another artist.
BrowseTarget artistOf(Track? track, String name) {
  final plain = GeniusNotes.plain(name);
  for (final l in [if (track != null) track.best, ...?track?.listings]) {
    final ids = l.artistIds;
    if (ids == null || !_paged.contains(l.source)) continue;
    for (final (i, artist) in l.artists.indexed) {
      final id = i < ids.length ? ids[i] : null;
      if (id != null && GeniusNotes.plain(artist) == plain) {
        return ArtistTarget(ArtistRef(source: l.source, id: id, name: artist));
      }
    }
  }
  return ArtistNamed(name);
}

/// The page of [track]'s album: the release a copy of that album title is on, by its id, else the best match from a
/// search (AlbumNamed).
BrowseTarget albumOf(Track track) {
  final title = GeniusNotes.plain(track.albumTitle ?? '');
  for (final l in [track.best, ...track.listings]) {
    final id = l.albumId;
    if (id != null && _paged.contains(l.source) && GeniusNotes.plain(l.album ?? '') == title) {
      return AlbumTarget(AlbumRef(source: l.source, id: id, title: l.album!));
    }
  }
  return AlbumNamed(track.albumTitle ?? '', track.artists.firstOrNull ?? '');
}

/// The songs downloaded to this device: a page of its own on a phone, where the bottom bar has no room for it
/// (Settings › Storage opens it), as it is a sidebar item in a wide window.
class DownloadsTarget extends BrowseTarget {
  const DownloadsTarget();
  @override
  bool operator ==(Object other) => other is DownloadsTarget;
  @override
  int get hashCode => (DownloadsTarget).hashCode;
}

/// The pages opened over the screen in the content area of a wide window, newest last. On a phone a page is a pushed
/// route instead and this stays empty. It is shared, as the Mac's Navigator is, so Now Playing and the song menus
/// can open a page without being inside the content area.
class BrowseNav extends ChangeNotifier {
  static final shared = BrowseNav();

  final List<BrowseTarget> path = [];

  /// Opens a page over the current screen; the same page twice in a row is not stacked.
  void open(BrowseTarget target) {
    if (path.isNotEmpty && path.last == target) return;
    path.add(target);
    notifyListeners();
  }

  void back() {
    if (path.isEmpty) return;
    path.removeLast();
    notifyListeners();
  }

  /// Choosing a sidebar item starts afresh.
  void clear() {
    if (path.isEmpty) return;
    path.clear();
    notifyListeners();
  }
}

/// Opens the page for [target] over the current screen: inside the content area in a wide window, a pushed route on a
/// phone. Now Playing closes first, since the page would otherwise open behind it.
void openBrowse(BuildContext context, BrowseTarget target) {
  Scope.of(context).player.setShowNowPlaying(false);
  if (isPhone(context)) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => PhoneBrowsePage(target: target),
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 300),
        reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        transitionsBuilder: (_, animation, _, child) =>
            phoneRevealTransition(child, animation, dy: 0.045),
      ),
    );
  } else {
    BrowseNav.shared.open(target);
  }
}

/// The content area of a wide window: the selected screen, and over it the pages opened from it. The screen stays
/// built underneath, so going back finds the search and the scroll position where they were.
class BrowseHost extends StatelessWidget {
  final Widget child;
  const BrowseHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: BrowseNav.shared,
    builder: (context, _) {
      final path = BrowseNav.shared.path;
      return Stack(
        children: [
          Positioned.fill(
            child: Offstage(
              offstage: path.isNotEmpty,
              child: TickerMode(enabled: path.isEmpty, child: child),
            ),
          ),
          for (final (i, target) in path.indexed)
            Positioned.fill(
              key: ValueKey('$i/${target.hashCode}'),
              child: Offstage(
                offstage: i != path.length - 1,
                child: TickerMode(
                  enabled: i == path.length - 1,
                  // the concept (13 Oct): a pushed page slides in once, as on the Mac
                  child: PushIn(child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: BrowseNav.shared.back,
                            icon: const Icon(
                              FluentIcons.chevron_left_24_regular,
                              size: 18,
                            ),
                            label: const Text('Back'),
                          ),
                        ),
                      ),
                      Expanded(child: BrowsePage(target: target)),
                    ],
                  )),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A page on a phone: an album's or an artist's, in the one page scaffold (PhonePage) every pushed page uses.
class PhoneBrowsePage extends StatelessWidget {
  final BrowseTarget target;
  const PhoneBrowsePage({super.key, required this.target});

  @override
  Widget build(BuildContext context) => PhonePage(child: BrowsePage(target: target));
}
