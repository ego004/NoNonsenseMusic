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

  // playlists (MUS-2)
  List<PlaylistSummary> playlists = [];
  final Map<String, PlaylistDetail> details = {};
  final Map<String, int> _localEdits = {}; // per playlist: a load older than an edit on screen is dropped
  /// The player sets this: a playing playlist's queue follows edits made anywhere.
  void Function(PlaylistDetail)? playlistChanged;

  bool isLiked(Track t) => t.listings.any((l) => _likedKeys.contains(l.key));

  /// Yours, in your order; then the ones shared with you (the server sends them in that order, AUTH-3).
  Iterable<PlaylistSummary> get ownPlaylists => playlists.where((p) => p.isOwner);
  Iterable<PlaylistSummary> get sharedPlaylists => playlists.where((p) => !p.isOwner);

  /// Signed out: nothing of that account stays on screen. The next account's library loads when it signs in.
  void clear() {
    liked = [];
    recent = [];
    playlists = [];
    details.clear();
    _songIds.clear();
    _likedKeys = {};
    _localEdits.clear();
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      final r = await Future.wait([Api.liked(), Api.recent()]);
      liked = r[0];
      recent = r[1];
      playlists = await Api.playlists();
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

  Future<bool> loadPlaylist(String id) async {
    final edits = _localEdits[id] ?? 0;
    try {
      final d = await Api.playlist(id);
      if ((_localEdits[id] ?? 0) != edits) return true; // an edit on screen is newer than this answer
      details[id] = d;
      playlistChanged?.call(d);
      notifyListeners();
      return true;
    } on ApiError catch (e) {
      if (e.status == 404) {
        // deleted, or no longer shared with you: it leaves the list too
        details.remove(id);
        await _refreshPlaylists();
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  void _update(PlaylistDetail d) {
    _localEdits[d.summary.id] = (_localEdits[d.summary.id] ?? 0) + 1;
    details[d.summary.id] = d;
    playlistChanged?.call(d);
    notifyListeners();
  }

  Future<void> _refreshPlaylists() async {
    try {
      playlists = await Api.playlists();
      notifyListeners();
    } catch (_) {}
  }

  /// null when it worked; else the server's reason ("A playlist with this name already exists").
  Future<String?> createPlaylist(String name, {Track? adding}) async {
    try {
      final p = await Api.create(name);
      await _refreshPlaylists();
      if (adding != null) await add(adding, p.id);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> renamePlaylist(String id, String name) async {
    try {
      await Api.rename(id, name);
      await _refreshPlaylists();
      await loadPlaylist(id);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Owner: share with someone by username, as 'viewer' or 'editor' (again: changes their role). null when it worked;
  /// else the server's reason ("No account with that username").
  Future<String?> share(String id, String username, String role) async {
    try {
      await Api.share(id, username, role);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Owner: anyone signed in may open it by its id, or only the people it is shared with.
  Future<String?> setPublic(String id, bool public) async {
    try {
      await Api.setPublic(id, public);
      await _refreshPlaylists();
      await loadPlaylist(id);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// A member takes themselves off a playlist shared with them: it leaves their list.
  Future<String?> leave(String id, String myUserId) async {
    try {
      await Api.removeMember(id, myUserId);
      details.remove(id);
      await _refreshPlaylists();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> deletePlaylist(String id) async {
    try {
      await Api.delete(id);
    } catch (_) {}
    details.remove(id);
    await _refreshPlaylists();
  }

  Future<void> add(Track t, String playlist) async {
    try {
      await Api.add(t.listings, playlist);
      await _refreshPlaylists();
      await loadPlaylist(playlist);
    } catch (_) {}
  }

  Future<void> remove(String itemId, String playlist) async {
    final d = details[playlist];
    if (d != null) _update(d.withItems(d.items.where((i) => i.$1 != itemId).toList()));
    try {
      await Api.remove(itemId, playlist);
      await _refreshPlaylists();
    } catch (_) {
      await loadPlaylist(playlist);
    }
  }

  /// Row `from` to place `to` (its place once moved): the screen at once, then the server with the new neighbours.
  Future<void> moveItem(String playlist, int from, int to) async {
    final d = details[playlist];
    if (d == null || from == to || from < 0 || from >= d.items.length) return;
    final items = [...d.items];
    final moved = items.removeAt(from);
    items.insert(to.clamp(0, items.length), moved);
    _update(d.withItems(items));
    final k = items.indexOf(moved);
    try {
      await Api.moveItem(playlist, moved.$1, k > 0 ? items[k - 1].$1 : null, k + 1 < items.length ? items[k + 1].$1 : null);
    } catch (_) {
      await loadPlaylist(playlist);
    }
  }
}
