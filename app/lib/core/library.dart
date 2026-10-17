import 'package:flutter/foundation.dart';

import 'api.dart';
import 'catalog.dart';
import 'download_store.dart';
import 'models.dart';

/// The user's liked songs, recently played tracks and playlists; the Mac app's equivalent is LibraryStore.
class Library extends ChangeNotifier {
  List<LibrarySong> liked = [];
  List<LibrarySong> recent = [];
  bool reachable = true;
  final Map<String, String> _songIds = {}; // maps a listing key to the song id stored on the server
  Set<String> _likedKeys = {};
  final Map<String, Future<void>> _turns = {}; // likes and unlikes of one song run in sequence, so presses do not race

  // Playlists.
  List<PlaylistSummary> playlists = [];
  final Map<String, PlaylistDetail> details = {};
  final Map<String, int> _localEdits = {}; // per playlist: a response older than an edit on screen is dropped
  /// The player sets this: a playing playlist's queue follows edits made anywhere.
  void Function(PlaylistDetail)? playlistChanged;

  bool isLiked(Track t) => t.listings.any((l) => _likedKeys.contains(l.key));

  /// The songs of yours this app holds when the server cannot be reached: the downloads first (they play with no
  /// server), then the liked songs and the playlists opened since the app started. A search finds yours among them
  /// then, by the server's rule (core/matching.dart, #26).
  Iterable<Track> held(DownloadStore downloads) => [
        for (final item in downloads.items) item.track,
        for (final song in liked) song.track,
        for (final playlist in details.values) ...playlist.tracks,
      ];

  /// The user's own playlists, in their order; the server sends the shared ones after them.
  Iterable<PlaylistSummary> get ownPlaylists => playlists.where((p) => p.isOwner);
  Iterable<PlaylistSummary> get sharedPlaylists => playlists.where((p) => !p.isOwner);

  /// The user's pinned albums (playlists of kind "album"), in their order. They are also in [ownPlaylists], as on the
  /// Mac; Home and the sidebar tell them apart by kind.
  Iterable<PlaylistSummary> get pinnedAlbums => playlists.where((p) => p.isOwner && p.isAlbum);

  /// The user's own playlists that are not pinned albums.
  Iterable<PlaylistSummary> get ownPlaylistsOnly => ownPlaylists.where((p) => !p.isAlbum);

  /// The user's pinned copy of a source's album, if they pinned it.
  PlaylistSummary? pinned(AlbumRef album) {
    for (final p in playlists) {
      if (p.isAlbum && p.source == album.source && p.sourceId == album.id) return p;
    }
    return null;
  }

  /// Copies the album into the user's playlists as a pinned album, shown on Home. Returns null on success, else the
  /// reason. An album already pinned (409), perhaps on another device, counts as pinned: the list is reloaded.
  Future<String?> pin(AlbumRef album) async {
    try {
      await Catalog.pinAlbum(album);
      await _refreshPlaylists();
      return null;
    } on ApiError catch (e) {
      if (e.status == 409) {
        await _refreshPlaylists();
        return null;
      }
      return e.toString();
    } catch (e) {
      return e.toString();
    }
  }

  /// Removes a pinned album; its songs stay in the library. Returns null on success, else the reason.
  Future<String?> unpin(PlaylistSummary album) async {
    try {
      await Api.delete(album.id);
      playlists = playlists.where((p) => p.id != album.id).toList();
      details.remove(album.id);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// On sign-out, nothing of that account stays on screen; the next account's library loads when it signs in.
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

  /// Reloads liked songs, recent plays and playlists from the server; sets reachable to false when that fails.
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
    // the heart changes before the call, so the screen does not wait for the network
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
    if (_turns[t.id] != turn) return; // a newer press took over; that press refreshes
    _turns.remove(t.id);
    await refresh();
  }

  /// Loads a playlist's detail, returning false when it no longer exists for the user.
  Future<bool> loadPlaylist(String id) async {
    final edits = _localEdits[id] ?? 0;
    try {
      final d = await Api.playlist(id);
      if ((_localEdits[id] ?? 0) != edits) return true; // an edit on screen is newer than this response
      details[id] = d;
      playlistChanged?.call(d);
      notifyListeners();
      return true;
    } on ApiError catch (e) {
      if (e.status == 404) {
        // deleted, or no longer shared with the user: it leaves the list too
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

  /// Returns null on success, else the server's reason ("A playlist with this name already exists").
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

  /// Shares a playlist the user owns with an account named by username, as 'viewer' or 'editor'; sharing an existing
  /// member changes their role. Returns null on success, else the server's reason ("No account with that username").
  Future<String?> share(String id, String username, String role) async {
    try {
      await Api.share(id, username, role);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Sets whether anyone signed in may open the playlist by its id, or only the people it is shared with. Owner only.
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

  /// Removes the user from a shared playlist's members; the playlist leaves their list.
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

  /// Moves row `from` to position `to`: the screen updates at once, then the server learns the new neighbours.
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
