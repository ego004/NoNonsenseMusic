import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Every call the app makes to the FastAPI server (the same calls as the Mac app's API.swift).
class Api {
  /// `--dart-define=SERVER=http://…` for another server; your Mac's by default.
  static String base = const String.fromEnvironment('SERVER', defaultValue: 'http://127.0.0.1:8000');
  static final _client = http.Client(); // one kept connection, not one per request

  static Uri _u(String path, [Map<String, String>? q]) => Uri.parse('$base/$path').replace(queryParameters: q);

  static Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final r = await _client.get(_u(path, q)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw ApiError(r.statusCode, _detail(r));
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static Future<dynamic> _send(String method, String path, Object body) async {
    final req = http.Request(method, _u(path))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(body);
    final r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
    if (r.statusCode >= 300) throw ApiError(r.statusCode, _detail(r));
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  static String? _detail(http.Response r) {
    try {
      final d = jsonDecode(r.body)['detail'];
      return d is String ? d : null;
    } catch (_) {
      return null;
    }
  }

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
      return (await _client.get(_u('health')).timeout(const Duration(seconds: 3))).statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// The address the player opens: the server answers with a redirect to the audio. `fresh`: the cached link failed.
  static String playUrl(Listing l, {bool fresh = false}) =>
      '$base/play/${l.source}/${Uri.encodeComponent(l.id)}${fresh ? '?serve_fresh=true' : ''}';

  static Future<String> like(List<Listing> listings) async =>
      (await _send('POST', 'liked', {'listings': listings.map((l) => l.toJson()).toList()}))['song_id'] as String;

  static Future<void> unlike(String songId) async {
    final r = await _client.delete(_u('liked/$songId'));
    if (r.statusCode != 204 && r.statusCode != 404) throw ApiError(r.statusCode, _detail(r));
  }

  /// type: play | skip | finish; position: seconds into the song.
  static Future<void> event(List<Listing> listings, String type, int position) =>
      _send('POST', 'events', {'listings': listings.map((l) => l.toJson()).toList(), 'type': type, 'position': position < 0 ? 0 : position});

  /// What plays next, so it starts from the server's cache (answered 202 at once).
  static Future<void> prefetch(List<Listing> listings) async {
    if (listings.isEmpty) return;
    await _send('POST', 'prefetch', {'listings': listings.take(50).map((l) => {'source': l.source, 'source_id': l.id}).toList()});
  }

  // playlists and lyrics
  static Future<List<PlaylistSummary>> playlists() async =>
      ((await _get('playlists'))['playlists'] as List).map((p) => PlaylistSummary.fromJson(p as Map<String, dynamic>)).toList();
  static Future<PlaylistDetail> playlist(String id) async => PlaylistDetail.fromJson(await _get('playlists/$id') as Map<String, dynamic>);
  static Future<PlaylistSummary> create(String name) async => PlaylistSummary.fromJson(await _send('POST', 'playlists', {'name': name}));
  static Future<void> rename(String id, String name) => _send('PATCH', 'playlists/$id', {'name': name});
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
  PlaylistSummary(this.id, this.name, this.songCount, this.duration);
  factory PlaylistSummary.fromJson(Map<String, dynamic> j) =>
      PlaylistSummary(j['id'] as String, j['name'] as String, (j['song_count'] as num).toInt(), (j['duration'] as num).toInt());
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
