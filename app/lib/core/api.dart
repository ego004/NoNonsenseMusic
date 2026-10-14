import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'youtube.dart';

/// The app's client for the FastAPI server: every call the app makes to it, the same set as the Mac app's API.swift.
class Api {
  /// Set with `--dart-define=SERVER=http://…` to reach another server; this computer by default. No hosted server's
  /// address belongs in this public code: people type theirs on the sign-in screen (Settings › Server later), and a
  /// quick tunnel's address changes whenever the tunnel restarts.
  static const defaultServer = String.fromEnvironment('SERVER', defaultValue: 'http://127.0.0.1:8000');
  static String base = defaultServer;

  /// One client reused across requests, not one per request. Tests replace it with a MockClient.
  static http.Client client = http.Client();

  /// The signed-in session's token, set by Auth, sent on every request as `Authorization: Bearer …`.
  static String? token;

  /// Called when the server answers 401 to a request that carried the current token: the session ended, because it
  /// expired or the user signed out on another device. Auth drops the token and shows the sign-in screen.
  static void Function()? onSignedOut;

  static Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('$base/$path').replace(queryParameters: q);

  static Map<String, String> _auth(String? t) =>
      t == null ? const {} : {'authorization': 'Bearer $t'};

  static Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final sent = token;
    final r = await client
        .get(_u(path, q), headers: _auth(sent))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r, sent);
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static Future<dynamic> _send(String method, String path, Object body) async {
    final sent = token;
    final req = http.Request(method, _u(path))
      ..headers['content-type'] = 'application/json'
      ..headers.addAll(_auth(sent))
      ..body = jsonEncode(body);
    final r = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    if (r.statusCode >= 300) _fail(r, sent);
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// A GET from another file's API calls (friends, jams): the same token, timeout and errors as every other call.
  static Future<dynamic> getJson(String path, [Map<String, String>? query]) =>
      _get(path, query);

  /// A POST, PUT, PATCH or DELETE from another file's API calls; `null` for an empty answer (204).
  static Future<dynamic> sendJson(
    String method,
    String path, [
    Object body = const {},
  ]) => _send(method, path, body);

  /// Spotify import (core/spotify_import.dart): start one, then ask how far it has got.
  static Future<Map<String, dynamic>> startSpotifyImport(
    List<Map<String, dynamic>> groups,
  ) async =>
      await _send('POST', 'import', {'groups': groups}) as Map<String, dynamic>;
  static Future<Map<String, dynamic>> spotifyImportStatus(String id) async =>
      await _get('import/$id') as Map<String, dynamic>;

  /// Throw the server's answer as an ApiError. A 401 means the session ended only when the request carried the token
  /// still in use; Auth is told then. An older request answering 401 after the user signed in again must not end the
  /// new session.
  static Never _fail(http.Response r, String? sent) {
    if (r.statusCode == 401 && sent != null && sent == token) {
      onSignedOut?.call();
    }
    throw ApiError(r.statusCode, _detail(r.body));
  }

  /// Return the server's own words, meant to be shown. A 422 lists what was wrong with each field:
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
        final name = field.isEmpty
            ? ''
            : '${field[0].toUpperCase()}${field.substring(1).replaceAll('_', ' ')}';
        final msg = '${first['msg'] ?? ''}';
        if (name.isEmpty) return msg;
        return msg.startsWith('String should')
            ? '$name ${msg.substring('String '.length)}'
            : '$name: $msg';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // MARK: accounts (AUTH-1). Sign-up and sign-in send no token; their 401 means "wrong username or password", not a
  // session that ended

  /// Creates the account and signs in. The recovery codes come back this once; the server keeps only their hashes.
  static Future<(String token, AuthUser user, List<String> recoveryCodes)>
  signUp(String username, String password, String device) async {
    final j = await _session('auth/signup', username, password, device);
    return (
      j['token'] as String,
      AuthUser.fromJson(j['user'] as Map<String, dynamic>),
      [...(j['recovery_codes'] as List? ?? const []).cast<String>()],
    );
  }

  static Future<(String token, AuthUser user)> signIn(
    String username,
    String password,
    String device,
  ) async {
    final j = await _session('auth/signin', username, password, device);
    return (
      j['token'] as String,
      AuthUser.fromJson(j['user'] as Map<String, dynamic>),
    );
  }

  static Future<Map<String, dynamic>> _session(
    String path,
    String username,
    String password,
    String device,
  ) async {
    final r = await client
        .post(
          _u(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
            'device_name': device,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw ApiError(r.statusCode, _detail(r.body));
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// The server's own words for an error body, for the calls that make their own requests (see [AccountApi]).
  static String? detailOf(String body) => _detail(body);

  /// Return who the stored token belongs to: the check made at launch. A 401 goes through onSignedOut, so the user
  /// signs in again.
  static Future<AuthUser> me() async =>
      AuthUser.fromJson(await _get('auth/me') as Map<String, dynamic>);

  /// End this device's session on the server; other devices stay signed in.
  static Future<void> signOut() => _send('POST', 'auth/signout', const {});

  /// Rename this device, the session the token belongs to, in the user's list of devices.
  static Future<void> renameDevice(String name) =>
      _send('PATCH', 'auth/me/device', {'device_name': name});

  /// Search the catalogue and return the matches as tracks.
  static Future<List<Track>> search(String q) async {
    final j = await _get('search', {'q': q}) as Map<String, dynamic>;
    return (j['songs'] as List)
        .map((s) => Track.fromSong(s as Map<String, dynamic>))
        .toList();
  }

  /// Return the songs the user liked.
  static Future<List<LibrarySong>> liked() async =>
      ((await _get('liked')) as List)
          .map((s) => LibrarySong.fromJson(s as Map<String, dynamic>))
          .toList();

  /// Return the songs the user played recently.
  static Future<List<LibrarySong>> recent() async =>
      ((await _get('recent')) as List)
          .map((s) => LibrarySong.fromJson(s as Map<String, dynamic>))
          .toList();

  /// Return true only for a 200 answered within 3 seconds.
  static Future<bool> health() async {
    try {
      return (await client
                  .get(_u('health'))
                  .timeout(const Duration(seconds: 3)))
              .statusCode ==
          200;
    } catch (_) {
      return false;
    }
  }

  /// Return the server's address for a copy: it answers with a redirect to the audio. `fresh`: the cached link failed.
  static String playUrl(Listing l, {bool fresh = false}) =>
      '$base/play/${l.source}/${Uri.encodeComponent(l.id)}${fresh ? '?serve_fresh=true' : ''}';

  /// The audio's own address, for the player. /play needs the token; the player is never given it: an HTTP stack that
  /// follows the redirect may carry `Authorization` on to the audio host (YouTube, JioSaavn). So the app asks /play
  /// itself, does not follow the redirect, and hands the player the `Location`. Following the redirect would be the
  /// same two requests.
  ///
  /// A YouTube copy ("ytmusic" or "youtube") is looked up by this device and never through /play: the link then
  /// carries this device's IP, while the one the server fetches plays only from the server's own address. A failed
  /// lookup throws, and the player moves on to the song's next copy.
  static Future<String> audioUrl(Listing l, {bool fresh = false}) async {
    if (YouTubeLookup.resolvesOnDevice(l.source)) {
      return YouTubeLookup.instance.audioUrl(l.id, fresh: fresh);
    }
    final sent = token;
    final req = http.Request('GET', Uri.parse(playUrl(l, fresh: fresh)))
      ..followRedirects = false
      ..headers.addAll(_auth(sent));
    final r = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    final to = r.headers['location'];
    if (r.statusCode >= 300 && r.statusCode < 400 && to != null) {
      return Uri.parse(playUrl(l)).resolve(to).toString();
    }
    _fail(r, sent);
  }

  static Future<String> like(List<Listing> listings) async =>
      (await _send('POST', 'liked', {
            'listings': listings.map((l) => l.toJson()).toList(),
          }))['song_id']
          as String;

  /// Remove a song from the liked list; a 404 means it was not there.
  static Future<void> unlike(String songId) async {
    final sent = token;
    final r = await client.delete(_u('liked/$songId'), headers: _auth(sent));
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r, sent);
  }

  /// Send a playback event. type: play | skip | finish; position: seconds into the song.
  static Future<void> event(
    List<Listing> listings,
    String type,
    int position,
  ) => _send('POST', 'events', {
    'listings': listings.map((l) => l.toJson()).toList(),
    'type': type,
    'position': position < 0 ? 0 : position,
  });

  /// Warm what plays next, ready before the user presses play. YouTube copies are looked up by this device
  /// (YouTubeLookup); the rest (JioSaavn) by the server, which answers 202 at once.
  static Future<void> prefetch(List<Listing> listings) async {
    final others = listings
        .where((l) => !YouTubeLookup.resolvesOnDevice(l.source))
        .take(50)
        .toList();
    if (others.isNotEmpty) {
      await _send('POST', 'prefetch', {
        'listings': others
            .map((l) => {'source': l.source, 'source_id': l.id})
            .toList(),
      });
    }
    await YouTubeLookup.instance.warm(
      listings
          .where((l) => YouTubeLookup.resolvesOnDevice(l.source))
          .map((l) => l.id),
    );
  }

  // Playlists and lyrics
  static Future<List<PlaylistSummary>> playlists() async =>
      ((await _get('playlists'))['playlists'] as List)
          .map((p) => PlaylistSummary.fromJson(p as Map<String, dynamic>))
          .toList();
  static Future<PlaylistDetail> playlist(String id) async =>
      PlaylistDetail.fromJson(
        await _get('playlists/$id') as Map<String, dynamic>,
      );
  static Future<PlaylistSummary> create(String name) async =>
      PlaylistSummary.fromJson(
        await _send('POST', 'playlists', {'name': name}),
      );
  static Future<void> rename(String id, String name) =>
      _send('PATCH', 'playlists/$id', {'name': name});

  // Sharing: the owner shares by username, as a viewer or an editor (the same call again changes the role), and makes
  // a playlist public; a member leaves by removing themselves
  static Future<void> setPublic(String id, bool public) =>
      _send('PATCH', 'playlists/$id', {'public': public});
  static Future<void> share(String id, String username, String role) => _send(
    'PUT',
    'playlists/$id/members',
    {'username': username, 'role': role},
  );

  /// A playlist's link to share: the server's page, which hands over to the app (`nononsense://playlist/<id>`).
  static String playlistLink(String id) => '$base/p/$id';

  /// Return the owner first, then who the playlist is shared with (for the owner and the members).
  static Future<List<PlaylistMember>> members(String id) async =>
      ((await _get('playlists/$id/members')) as List)
          .map((m) => PlaylistMember.fromJson(m as Map<String, dynamic>))
          .toList();
  static Future<void> removeMember(String id, String userId) =>
      _send('DELETE', 'playlists/$id/members/$userId', const {});
  static Future<void> delete(String id) =>
      _send('DELETE', 'playlists/$id', const {});
  static Future<void> add(List<Listing> listings, String to) => _send(
    'POST',
    'playlists/$to/items',
    {'listings': listings.map((l) => l.toJson()).toList()},
  );
  static Future<void> remove(String itemId, String from) =>
      _send('DELETE', 'playlists/$from/items/$itemId', const {});

  /// Name the row's new neighbours (above, below), so only one row changes on the server.
  static Future<void> moveItem(
    String playlist,
    String item,
    String? top,
    String? bottom,
  ) => _send('POST', 'playlists/$playlist/items/$item/move', {
    'top_neighbour_id': top,
    'bottom_neighbour_id': bottom,
  });

  static Future<Lyrics> lyrics(Track t) async {
    final youtube = t.listings
        .where((l) => l.source == 'ytmusic')
        .map((l) => l.id)
        .firstOrNull;
    final j = await _send('POST', 'lyrics', {
      'song_name': t.title,
      'artist_name': t.artists.join(
        ', ',
      ), // every artist: LRCLIB's fuller record (50 lines vs 5)
      'song_duration': t.duration,
      'youtube_id': youtube,
    }) as Map<String, dynamic>;
    return Lyrics.fromJson(j);
  }

  /// Fetch Genius notes (experimental; asked only with Settings › Lyrics › Genius notes on). The main artist alone:
  /// Genius files a song under one. Throws when the server or Genius cannot be asked (502).
  static Future<GeniusNotes> genius(Track t) async {
    final j = await _send('POST', 'genius', {
      'song_name': t.title,
      'artist_name': t.artists.firstOrNull ?? '',
    });
    return GeniusNotes.fromJson(j as Map<String, dynamic>);
  }
}

// MARK: playlists (MUS-2) and lyrics (MUS-12)

/// Someone on a playlist (GET /playlists/{id}/members): its owner, or someone it is shared with.
class PlaylistMember {
  final String userId, username, role; // role: owner, editor or viewer
  const PlaylistMember(this.userId, this.username, this.role);
  factory PlaylistMember.fromJson(Map<String, dynamic> j) => PlaylistMember(
    j['user_id'] as String,
    j['username'] as String,
    j['role'] as String,
  );

  /// The role worded as the share dialog states it.
  String get roleName => role == 'owner'
      ? 'Owner'
      : role == 'editor'
      ? 'Can make changes'
      : 'View only';
}

class PlaylistSummary {
  final String id, name;
  final int songCount, duration;

  /// Anyone signed in can open it by its id.
  final bool public;

  /// 'owner' for the user's own playlist, 'editor' (add, remove, reorder) or 'viewer' (look and play) when it is
  /// shared with them.
  final String role;

  /// 'album' for a pinned album, a read-only copy of a source's album (named by [source] and [sourceId]); otherwise
  /// 'playlist'.
  final String kind;
  final String? source, sourceId;
  PlaylistSummary(
    this.id,
    this.name,
    this.songCount,
    this.duration, {
    this.public = false,
    this.role = 'owner',
    this.kind = 'playlist',
    this.source,
    this.sourceId,
  });
  factory PlaylistSummary.fromJson(Map<String, dynamic> j) => PlaylistSummary(
    j['id'] as String,
    j['name'] as String,
    (j['song_count'] as num).toInt(),
    (j['duration'] as num).toInt(),
    public: j['public'] as bool? ?? false,
    role: j['role'] as String? ?? 'owner',
    kind: j['kind'] as String? ?? 'playlist',
    source: j['source'] as String?,
    sourceId: j['source_id'] as String?,
  );

  bool get isOwner => role == 'owner';
  bool get isAlbum => kind == 'album';

  /// Whether the playlist's songs may be changed: the owner or an editor, and never a pinned album. The server
  /// refuses the rest (403); the app does not offer it.
  bool get canEdit => role != 'viewer' && !isAlbum;
}

/// Who is signed in.
class AuthUser {
  final String id, username;
  const AuthUser(this.id, this.username);
  factory AuthUser.fromJson(Map<String, dynamic> j) =>
      AuthUser(j['id'] as String, j['username'] as String);
  Map<String, String> toJson() => {'id': id, 'username': username};
}

/// One playlist's rows, in order. `itemId` names a row: a song added twice is two rows.
class PlaylistDetail {
  final PlaylistSummary summary;
  final List<(String itemId, Track track)> items;
  PlaylistDetail(this.summary, this.items);
  factory PlaylistDetail.fromJson(Map<String, dynamic> j) =>
      PlaylistDetail(PlaylistSummary.fromJson(j), [
        for (final i in j['items'] as List)
          (
            (i['item_id'] as String),
            Track.fromSong(i['song'] as Map<String, dynamic>),
          ),
      ]);
  List<Track> get tracks => items.map((i) => i.$2).toList();
  List<String> get keys => items.map((i) => i.$1).toList();
  String get queueSource => 'playlist:${summary.id}';
  PlaylistDetail withItems(List<(String, Track)> items) =>
      PlaylistDetail(summary, items);
}

class LyricLine {
  final int? startMs; // null: plain lyrics
  final String text;

  /// The line's translation when the uploader of the lyrics included one; the server splits it off the line.
  final String? translation;
  LyricLine(this.startMs, this.text, {this.translation});
}

class Lyrics {
  final String? source; // "lrclib" | "ytmusic" | null: nobody had them
  final bool synced;
  final List<LyricLine> lines;
  Lyrics(this.source, this.synced, this.lines);

  /// The server's shape, also the file a download keeps its lyrics in.
  factory Lyrics.fromJson(Map<String, dynamic> j) =>
      Lyrics(j['lyrics_source'] as String?, j['synced'] as bool, [
        for (final l in j['lines'] as List)
          LyricLine(
            (l['start_ms'] as num?)?.toInt(),
            l['text'] as String,
            translation: l['translation'] as String?,
          ),
      ]);
  Map<String, dynamic> toJson() => {
    'lyrics_source': source,
    'synced': synced,
    'lines': [
      for (final l in lines)
        {'start_ms': l.startMs, 'text': l.text, 'translation': ?l.translation},
    ],
  };
  String? get sourceName => source == 'lrclib'
      ? 'LRCLIB'
      : source == 'ytmusic'
      ? 'YouTube Music'
      : null;

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

/// A non-2xx answer from the server.
class ApiError implements Exception {
  final int status;
  final String? detail;
  ApiError(this.status, this.detail);
  @override
  String toString() => detail ?? 'The server answered $status.';
}

// ---- Genius notes (experimental): POST /genius. Notes only, never Genius's lyrics ----

class GeniusNote {
  final String fragment; // the song's words it is about, as Genius quotes them
  final String text;
  final bool verified; // written or confirmed by the artist
  const GeniusNote(this.fragment, this.text, {this.verified = false});
}

class GeniusAbout {
  final String? description;
  final List<String> producedBy;
  final List<String> samples;
  const GeniusAbout(this.description, this.producedBy, this.samples);
  bool get isEmpty =>
      description == null && producedBy.isEmpty && samples.isEmpty;
}

class GeniusNotes {
  final String?
  url; // the song's page on Genius (the credit); null: Genius has no such song
  final List<GeniusNote> notes;
  final GeniusAbout? about;
  const GeniusNotes(this.url, this.notes, this.about);

  factory GeniusNotes.fromJson(Map<String, dynamic> j) {
    final a = j['about'] as Map<String, dynamic>?;
    return GeniusNotes(
      j['url'] as String?,
      [
        for (final n in j['notes'] as List)
          GeniusNote(
            n['fragment'] as String,
            n['text'] as String,
            verified: n['verified'] == true,
          ),
      ],
      a == null
          ? null
          : GeniusAbout(
              a['description'] as String?,
              [...(a['produced_by'] as List).cast<String>()],
              [...(a['samples'] as List).cast<String>()],
            ),
    );
  }

  /// Match each note to the lyric line it is about: a line whose words appear in the note's fragment, or a line that
  /// holds a line of the fragment, with case, accents and punctuation ignored. Short pieces (under 8 letters:
  /// "oh oh") match nothing, so a note never lands on every chorus line by chance. A line takes the first note that
  /// fits. The Mac app applies the same rule.
  Map<int, GeniusNote> byLine(List<LyricLine> lines) {
    final found = <int, GeniusNote>{};
    final plainLines = [for (final l in lines) plain(l.text)];
    for (final note in notes) {
      final whole = plain(note.fragment);
      final pieces = note.fragment
          .split('\n')
          .map(plain)
          .where((p) => p.length >= 8)
          .toList();
      for (var i = 0; i < plainLines.length; i++) {
        final line = plainLines[i];
        if (found.containsKey(i) || line.length < 8) continue;
        if (whole.contains(line) || pieces.any(line.contains)) found[i] = note;
      }
    }
    return found;
  }

  static const _accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
  };

  /// Lowercase letters and digits, single spaces: "Don’t—stop!" and "dont stop" read the same.
  static String plain(String text) {
    final out = StringBuffer();
    for (final ch
        in text.toLowerCase().replaceAll(RegExp("['’]"), '').split('')) {
      final c = _accents[ch] ?? ch;
      out.write(RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c) ? c : ' ');
    }
    return out.toString().split(' ').where((w) => w.isNotEmpty).join(' ');
  }
}
