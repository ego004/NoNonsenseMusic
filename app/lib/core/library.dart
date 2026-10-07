import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// Liked Songs and Recently Played, and the hearts (the Mac app's LibraryStore, without playlists yet).
class Library extends ChangeNotifier {
  List<LibrarySong> liked = [];
  List<LibrarySong> recent = [];
  bool reachable = true;
  final Map<String, String> _songIds = {}; // listing key → stored song id
  Set<String> _likedKeys = {};
  final Map<String, Future<void>> _turns = {}; // one song's likes and unlikes take turns (the Mac app's like race)

  bool isLiked(Track t) => t.listings.any((l) => _likedKeys.contains(l.key));

  Future<void> refresh() async {
    try {
      final r = await Future.wait([Api.liked(), Api.recent()]);
      liked = r[0];
      recent = r[1];
      reachable = true;
      _likedKeys = {for (final s in liked) ...s.track.listings.map((l) => l.key)};
      for (final s in [...liked, ...recent]) {
        for (final l in s.track.listings) {
          _songIds[l.key] = s.songId;
        }
      }
    } catch (_) {
      reachable = false;
    }
    notifyListeners();
  }

  Future<void> toggleLike(Track t) async {
    final was = isLiked(t);
    // the heart changes at once; the server catches up
    if (was) {
      _likedKeys.removeAll(t.listings.map((l) => l.key));
    } else {
      _likedKeys.addAll(t.listings.map((l) => l.key));
    }
    notifyListeners();
    final previous = _turns[t.id];
    final turn = () async {
      await previous;
      try {
        if (was) {
          final id = t.listings.map((l) => _songIds[l.key]).firstWhere((id) => id != null, orElse: () => null);
          if (id != null) await Api.unlike(id);
        } else {
          final id = await Api.like(t.listings);
          for (final l in t.listings) {
            _songIds[l.key] = id;
          }
        }
      } catch (_) {}
    }();
    _turns[t.id] = turn;
    await turn;
    if (_turns[t.id] != turn) return; // a newer press: it refreshes
    _turns.remove(t.id);
    await refresh();
  }
}
