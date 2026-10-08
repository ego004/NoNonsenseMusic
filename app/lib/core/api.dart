import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'youtube.dart';

/// Every call the app makes to the FastAPI server (the same calls as the Mac app's API.swift).
class Api {
  /// `--dart-define=SERVER=http://…` for another server; your Mac's by default.
  static String base = const String.fromEnvironment('SERVER', defaultValue: 'http://127.0.0.1:8000');
  /// One kept connection, not one per request. Replaceable in tests (a MockClient).
  static http.Client client = http.Client();

  /// The signed-in session's token (AUTH-1, set by Auth), sent on every request as `Authorization: Bearer …`.
  static String? token;

  /// Called when the server answers 401 to a request that carried the current token: the session ended (it expired,
  /// or you signed out on another device). Auth drops the token and shows the sign-in screen.
  static void Function()? onSignedOut;

  static Uri _u(String path, [Map<String, String>? q]) => Uri.parse('$base/$path').replace(queryParameters: q);

  static Map<String, String> _auth(String? t) => t == null ? const {} : {'authorization': 'Bearer $t'};

  static Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final sent = token;
    final r = await client.get(_u(path, q), headers: _auth(sent)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r, sent);
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static Future<dynamic> _send(String method, String path, Object body) async {
    final sent = token;
    final req = http.Request(method, _u(path))
      ..headers['content-type'] = 'application/json'
      ..headers.addAll(_auth(sent))
      ..body = jsonEncode(body);
    final r = await http.Response.fromStream(await client.send(req).timeout(const Duration(seconds: 20)));
    if (r.statusCode >= 300) _fail(r, sent);
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Throws the server's answer as an ApiError. A 401 to a request sent with the token still in use means the session
  /// ended: Auth is told. Only then: an older request answering 401 after you signed in again must not sign you out.
  static Never _fail(http.Response r, String? sent) {
    if (r.statusCode == 401 && sent != null && sent == token) onSignedOut?.call();
    throw ApiError(r.statusCode, _detail(r.body));
  }

  /// The server's own words, written to be shown. A 422 lists what was wrong with each field:
  /// `[{"loc": ["body", "password"], "msg": "String should have at least 8 characters"}]` →
  /// "Password should have at least 8 characters".
  static String? _detail(String body) {
    try {
      final d = jsonDecode(body)['detail'];
      if (d is String) return d;
      if (d is List && d.isNotEmpty && d.first is Map) {
        final first = d.first as Map;
        final loc = first['loc'];
        final field = loc is List && loc.isNotEmpty ? '${loc.last}' : '';
        final name = field.isEmpty ? '' : '${field[0].toUpperCase()}${field.substring(1).replaceAll('_', ' ')}';
        final msg = '${first['msg'] ?? ''}';
        if (name.isEmpty) return msg;
        return msg.startsWith('String should') ? '$name ${msg.substring('String '.length)}' : '$name: $msg';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // MARK: accounts (AUTH-1). Sign-up and sign-in send no token; their 401 means "wrong username or password", not a
  // session that ended

  static Future<(String token, AuthUser user)> signUp(String username, String password, String device) =>
      _session('auth/signup', username, password, device);
  static Future<(String token, AuthUser user)> signIn(String username, String password, String device) =>
      _session('auth/signin', username, password, device);

  static Future<(String, AuthUser)> _session(String path, String username, String password, String device) async {
    final r = await client
        .post(_u(path), headers: const {'content-type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password, 'device_name': device}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 201) throw ApiError(r.statusCode, _detail(r.body));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['token'] as String, AuthUser.fromJson(j['user'] as Map<String, dynamic>));
  }

  /// Who the stored token belongs to: the launch check. 401 (through onSignedOut): sign in again.
  static Future<AuthUser> me() async => AuthUser.fromJson(await _get('auth/me') as Map<String, dynamic>);

  /// Ends this device's session on the server (other devices stay signed in).
  static Future<void> signOut() => _send('POST', 'auth/signout', const {});

  /// Renames this device (the session the token belongs to) in your list of devices.
  static Future<void> renameDevice(String name) => _send('PATCH', 'auth/me/device', {'device_name': name});

  static Future<List<Track>> search(String q) async {
    final j = await _get('search', {'q': q}) as Map<String, dynamic>;
    return (j['songs'] as List).map((s) => Track.fromSong(s as Map<String, dynamic>)).toList();
  }

  static Future<List<LibrarySong>> liked() async =>
      ((await _get('liked')) as List).map((s) => LibrarySong.fromJson(s as Map<String, dynamic>)).toList();
  static Future<List<LibrarySong>> recent() async =>
      ((await _get('recent')) as List).map((s) => LibrarySong.fromJson(s as Map<String, dynamic>)).toList();

  /// True only for a 200 within 3 s.
  static Future<bool> health() async {
    try {
      return (await client.get(_u('health')).timeout(const Duration(seconds: 3))).statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// The server's address for a copy: it answers with a redirect to the audio. `fresh`: the cached link failed.
  static String playUrl(Listing l, {bool fresh = false}) =>
      '$base/play/${l.source}/${Uri.encodeComponent(l.id)}${fresh ? '?serve_fresh=true' : ''}';

  /// The audio's own address, for the player. /play needs the token; the player is never given it: an HTTP stack that
  /// follows the redirect may carry `Authorization` on to the audio host (YouTube, JioSaavn). So the app asks /play
  /// itself, does not follow the redirect, and hands the player the `Location` (handoff 3.2, 8 Oct). The same two
  /// requests as before: following the redirect was two already.
  ///
  /// A YouTube copy is looked up by this device first (YouTubeLookup: the link then carries this device's IP, so a
  /// server on the web still plays it); the server's /play is the fallback, as it was for every copy (8 Oct).
  static Future<String> audioUrl(Listing l, {bool fresh = false}) async {
    if (l.source == 'ytmusic') {
      try {
        return await YouTubeLookup.instance.audioUrl(l.id, fresh: fresh);
      } catch (_) {}
    }
    final sent = token;
    final req = http.Request('GET', Uri.parse(playUrl(l, fresh: fresh)))
      ..followRedirects = false
      ..headers.addAll(_auth(sent));
    final r = await http.Response.fromStream(await client.send(req).timeout(const Duration(seconds: 20)));
    final to = r.headers['location'];
    if (r.statusCode >= 300 && r.statusCode < 400 && to != null) return Uri.parse(playUrl(l)).resolve(to).toString();
    _fail(r, sent);
  }

  static Future<String> like(List<Listing> listings) async =>
      (await _send('POST', 'liked', {'listings': listings.map((l) => l.toJson()).toList()}))['song_id'] as String;

  static Future<void> unlike(String songId) async {
    final sent = token;
    final r = await client.delete(_u('liked/$songId'), headers: _auth(sent));
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r, sent);
  }

  /// type: play | skip | finish; position: seconds into the song.
  static Future<void> event(List<Listing> listings, String type, int position) =>
      _send('POST', 'events', {'listings': listings.map((l) => l.toJson()).toList(), 'type': type, 'position': position < 0 ? 0 : position});

  /// What plays next, made ready before you press play. YouTube copies are looked up by this device (YouTubeLookup,
  /// 8 Oct); the rest (JioSaavn) by the server, which answers 202 at once.
  static Future<void> prefetch(List<Listing> listings) async {
    final others = listings.where((l) => l.source != 'ytmusic').take(50).toList();
    if (others.isNotEmpty) {
      await _send('POST', 'prefetch', {'listings': others.map((l) => {'source': l.source, 'source_id': l.id}).toList()});
    }
    await YouTubeLookup.instance.warm(listings.where((l) => l.source == 'ytmusic').map((l) => l.id));
  }

  // playlists and lyrics
  static Future<List<PlaylistSummary>> playlists() async =>
      ((await _get('playlists'))['playlists'] as List).map((p) => PlaylistSummary.fromJson(p as Map<String, dynamic>)).toList();
  static Future<PlaylistDetail> playlist(String id) async => PlaylistDetail.fromJson(await _get('playlists/$id') as Map<String, dynamic>);
  static Future<PlaylistSummary> create(String name) async => PlaylistSummary.fromJson(await _send('POST', 'playlists', {'name': name}));
  static Future<void> rename(String id, String name) => _send('PATCH', 'playlists/$id', {'name': name});

  // sharing (AUTH-3): the owner shares by username, as a viewer or an editor (the same call again changes the role),
  // and makes a playlist public; a member leaves by removing themselves
  static Future<void> setPublic(String id, bool public) => _send('PATCH', 'playlists/$id', {'public': public});
  static Future<void> share(String id, String username, String role) =>
      _send('PUT', 'playlists/$id/members', {'username': username, 'role': role});
  static Future<void> removeMember(String id, String userId) => _send('DELETE', 'playlists/$id/members/$userId', const {});
  static Future<void> delete(String id) => _send('DELETE', 'playlists/$id', const {});
  static Future<void> add(List<Listing> listings, String to) =>
      _send('POST', 'playlists/$to/items', {'listings': listings.map((l) => l.toJson()).toList()});
  static Future<void> remove(String itemId, String from) => _send('DELETE', 'playlists/$from/items/$itemId', const {});

  /// A move names the row's new neighbours (above, below), so one row changes on the server.
  static Future<void> moveItem(String playlist, String item, String? top, String? bottom) =>
      _send('POST', 'playlists/$playlist/items/$item/move', {'top_neighbour_id': top, 'bottom_neighbour_id': bottom});

  static Future<Lyrics> lyrics(Track t) async {
    final youtube = t.listings.where((l) => l.source == 'ytmusic').map((l) => l.id).firstOrNull;
    final j = await _send('POST', 'lyrics', {
      'song_name': t.title,
      'artist_name': t.artists.join(', '), // every artist: LRCLIB's fuller record (50 lines vs 5, measured 7 Oct)
      'song_duration': t.duration,
      'youtube_id': youtube,
    }) as Map<String, dynamic>;
    return Lyrics(j['lyrics_source'] as String?, j['synced'] as bool,
        [for (final l in j['lines'] as List) LyricLine((l['start_ms'] as num?)?.toInt(), l['text'] as String)]);
  }
}

// MARK: playlists (MUS-2) and lyrics (MUS-12)

class PlaylistSummary {
  final String id, name;
  final int songCount, duration;
  /// Anyone signed in can open it by its id (AUTH-3).
  final bool public;
  /// Yours: 'owner'. Shared with you: 'editor' (add, remove, reorder) or 'viewer' (look and play).
  final String role;
  PlaylistSummary(this.id, this.name, this.songCount, this.duration, {this.public = false, this.role = 'owner'});
  factory PlaylistSummary.fromJson(Map<String, dynamic> j) => PlaylistSummary(
      j['id'] as String, j['name'] as String, (j['song_count'] as num).toInt(), (j['duration'] as num).toInt(),
      public: j['public'] as bool? ?? false, role: j['role'] as String? ?? 'owner');

  bool get isOwner => role == 'owner';
  /// May change its songs: the owner or an editor. The server refuses the rest (403); the app does not offer it.
  bool get canEdit => role != 'viewer';
}

/// Who is signed in.
class AuthUser {
  final String id, username;
  const AuthUser(this.id, this.username);
  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(j['id'] as String, j['username'] as String);
  Map<String, String> toJson() => {'id': id, 'username': username};
}

/// One playlist's rows, in order. `itemId` names a row: a song added twice is two rows.
class PlaylistDetail {
  final PlaylistSummary summary;
  final List<(String itemId, Track track)> items;
  PlaylistDetail(this.summary, this.items);
  factory PlaylistDetail.fromJson(Map<String, dynamic> j) => PlaylistDetail(PlaylistSummary.fromJson(j), [
        for (final i in j['items'] as List) ((i['item_id'] as String), Track.fromSong(i['song'] as Map<String, dynamic>)),
      ]);
  List<Track> get tracks => items.map((i) => i.$2).toList();
  List<String> get keys => items.map((i) => i.$1).toList();
  String get queueSource => 'playlist:${summary.id}';
  PlaylistDetail withItems(List<(String, Track)> items) => PlaylistDetail(summary, items);
}

class LyricLine {
  final int? startMs; // null: plain lyrics
  final String text;
  LyricLine(this.startMs, this.text);
}

class Lyrics {
  final String? source; // "lrclib" | "ytmusic" | null: nobody had them
  final bool synced;
  final List<LyricLine> lines;
  Lyrics(this.source, this.synced, this.lines);
  String? get sourceName => source == 'lrclib' ? 'LRCLIB' : source == 'ytmusic' ? 'YouTube Music' : null;

  /// The line being sung at `seconds`, or -1 before the first.
  int lineAt(double seconds) {
    final ms = seconds * 1000;
    var found = -1;
    for (var i = 0; i < lines.length; i++) {
      final start = lines[i].startMs;
      if (start == null || start > ms) break;
      found = i;
    }
    return found;
  }
}

class ApiError implements Exception {
  final int status;
  final String? detail;
  ApiError(this.status, this.detail);
  @override
  String toString() => detail ?? 'The server answered $status.';
}
