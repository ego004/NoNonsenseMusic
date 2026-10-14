import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/catalog.dart';
import 'browse_pages.dart';
import 'glass.dart';
import 'layout.dart';
import 'now_playing.dart';
import 'player_bar.dart';
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

/// An artist known only by name (a song's artist line): the best match from a search opens.
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
                  child: Column(
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
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A page on a phone: a full-screen route with a back button, keeping the player bar and Now Playing in reach.
class PhoneBrowsePage extends StatelessWidget {
  final BrowseTarget target;
  const PhoneBrowsePage({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: PhoneBackdrop()),
          Positioned.fill(child: BrowsePage(target: target)),
          // the same two layers the shell draws over its screens, so a song can be started and opened from here
          const Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Center(child: PlayerBar()),
          ),
          ListenableBuilder(
            listenable: p,
            builder: (context, _) => AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, animation) =>
                  phoneRevealTransition(child, animation, dy: 0.12),
              child: p.showNowPlaying
                  ? const NowPlaying(key: ValueKey('browse-now-playing'))
                  : const SizedBox.shrink(
                      key: ValueKey('browse-now-playing-hidden'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
