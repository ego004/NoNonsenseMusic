import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'catalog.dart';
import 'matching.dart';
import 'models.dart';

/// What Search asks the server for: everything, or one kind alone (the server's `filter` parameter).
enum SearchFilter {
  all('All'),
  songs('Songs'),
  artists('Artists'),
  albums('Albums');

  final String title;
  const SearchFilter(this.title);

  /// The value of the `filter` query parameter.
  String get parameter => name;
}

/// The state of the Search screen: what was typed, the chosen filter, and the newest answer.
///
/// A query runs [delay] after typing stops (350 ms, as on the Mac). Choosing another filter asks again at once with
/// that filter. Only the newest question's answer is kept, so a slow older one never replaces a newer one. When the
/// server cannot be asked, the answer is the songs of yours among those [held] gives (Library.held), by the server's
/// rule (#26).
class SearchModel extends ChangeNotifier {
  SearchModel({Future<SearchResult> Function(String query, String filter)? ask, this.delay = const Duration(milliseconds: 350),
      void Function(List<Track> top)? onSongs, Iterable<Track> Function()? held})
      : _ask = ask ?? ((q, f) => Catalog.search(q, filter: f)),
        _onSongs = onSongs ?? _warmTop,
        _held = held ?? (() => const []);

  final Future<SearchResult> Function(String, String) _ask;
  final void Function(List<Track>) _onSongs;
  final Iterable<Track> Function() _held;
  final Duration delay;

  /// How many of each kind "All" shows in its shelves, and a single kind in its grid.
  static const shelfArtists = 8, shelfAlbums = 12, gridLimit = 60;

  String query = '';
  SearchFilter filter = SearchFilter.all;
  SearchResult result = const SearchResult();
  bool loading = false, failed = false;
  Timer? _wait;
  int _asked = 0;

  /// Nothing typed yet: the field sits lower, as the screen's main element.
  bool get isIdle => query.trim().isEmpty;

  /// The "No results" screen: only for a finished search that found nothing.
  bool get showsNoResults => !failed && !isIdle && result.isEmpty && !loading;

  /// How many of [songs], from the first, are yours (SearchResult.yours).
  int get yours => result.yours;

  List<SearchArtist> get artists => result.artists.take(filter == SearchFilter.all ? shelfArtists : gridLimit).toList();
  List<AlbumRef> get albums => result.albums.take(filter == SearchFilter.all ? shelfAlbums : gridLimit).toList();
  List<Track> get songs => result.songs;

  /// The text changed: ask after the pause in typing. Loading shows from the first keystroke, so "No results" does
  /// not flash in the gap.
  void typed(String text) {
    query = text;
    _schedule(delay);
  }

  /// Enter pressed: ask now.
  void submit() => _schedule(Duration.zero);

  /// Another filter was chosen: ask again at once, for that filter.
  void setFilter(SearchFilter next) {
    if (next == filter) return;
    filter = next;
    _schedule(Duration.zero);
    notifyListeners();
  }

  void _schedule(Duration after) {
    _wait?.cancel();
    final q = query.trim();
    final mine = ++_asked;
    if (q.isEmpty) {
      result = const SearchResult();
      loading = failed = false;
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    final asking = filter;
    Future<void> run() async {
      try {
        final found = await _ask(q, asking.parameter);
        if (mine != _asked) return; // a newer question is on its way, so this answer is stale
        result = found;
        loading = failed = false;
        _onSongs(found.songs);
      } catch (_) {
        if (mine != _asked) return;
        // no server: the songs of yours this app holds that match. Songs alone: artists and albums come only from it
        final own = asking == SearchFilter.songs || asking == SearchFilter.all ? matchingSongs(q, _held()) : <Track>[];
        result = SearchResult(songs: own, yours: own.length);
        loading = false;
        failed = true;
      }
      notifyListeners();
    }

    if (after == Duration.zero) {
      run();
    } else {
      _wait = Timer(after, run);
    }
  }

  /// The top result is made ready so playing it does not wait on the network.
  static void _warmTop(List<Track> songs) => Api.prefetch(songs.take(1).map((t) => t.best).toList()).catchError((_) {});

  @override
  void dispose() {
    _wait?.cancel();
    _asked++; // an answer still on its way lands on nothing
    super.dispose();
  }
}
