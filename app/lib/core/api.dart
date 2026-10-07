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
}

class ApiError implements Exception {
  final int status;
  final String? detail;
  ApiError(this.status, this.detail);
  @override
  String toString() => detail ?? 'The server answered $status.';
}
