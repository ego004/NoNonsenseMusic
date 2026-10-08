import 'dart:convert';

import 'package:http/http.dart' as http;

/// YouTube audio links asked for by this device itself (8 Oct), not by the server: the same as the Mac app's
/// YouTubeLookup.swift, which explains the why in full. In short: a YouTube link carries the asker's IP, signed, so a
/// link the server fetched plays only on the server's network; asked from here, a server anywhere still plays YouTube
/// songs, and does no YouTube lookups for you. The server's /play stays the fallback (Api.audioUrl).
///
/// One anonymous visitor id from YouTube's home page (kept in memory while the app runs), then one request to the
/// player API as YouTube's visionOS app, the client yt-dlp uses (no JavaScript, no PO token). No cookies are kept.
/// When YouTube changes this client, update [_client] from yt-dlp's `_base.py` ('visionos').
class YouTubeLookup {
  static final instance = YouTubeLookup();

  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _client = {
    'clientName': 'VISIONOS', 'clientVersion': '1.02', 'deviceMake': 'Apple', 'deviceModel': 'RealityDevice17,1',
    'userAgent': _userAgent, 'osName': 'visionOS', 'osVersion': '26.5.23O471', 'hl': 'en',
  };
  /// itag 140: AAC in an MP4 file, which every player here plays (Apple's cannot play YouTube's default Opus in WebM)
  static const _aacItag = 140;

  http.Client client = http.Client(); // a test may swap it
  String? _visitorId;
  final _links = <String, ({String url, DateTime until})>{}; // video id -> its link, until just before it expires

  /// The audio link for a YouTube video id; [fresh] skips the remembered one (it failed to play).
  Future<String> audioUrl(String videoId, {bool fresh = false}) async {
    final known = _links[videoId];
    if (!fresh && known != null && known.until.isAfter(DateTime.now())) return known.url;
    try {
      return await _lookUp(videoId);
    } on YouTubeLookupError catch (e) {
      if (e.status != 'LOGIN_REQUIRED' || _visitorId == null) rethrow;
      _visitorId = null; // the visitor id went stale: one more try with a new one
      return _lookUp(videoId);
    }
  }

  /// A link that failed to play: the next ask looks it up again.
  void forget(String videoId) => _links.remove(videoId);

  /// The next songs looked up ahead of time, one at a time, skipping known ones.
  Future<void> warm(Iterable<String> videoIds) async {
    for (final id in videoIds) {
      final known = _links[id];
      if (known != null && known.until.isAfter(DateTime.now())) continue;
      try {
        await audioUrl(id);
      } catch (_) {}
    }
  }

  Future<String> _lookUp(String videoId) async {
    final visitor = await _currentVisitorId();
    final r = await client
        .post(Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
            headers: {
              'Content-Type': 'application/json', 'User-Agent': _userAgent, 'X-Goog-Visitor-Id': visitor,
              'X-Youtube-Client-Name': '101', 'X-Youtube-Client-Version': '1.02',
            },
            body: jsonEncode({
              'context': {'client': {..._client, 'visitorData': visitor}},
              'videoId': videoId, 'contentCheckOk': true, 'racyCheckOk': true,
            }))
        .timeout(const Duration(seconds: 10));
    final reply = jsonDecode(r.body) as Map<String, dynamic>;
    final status = (reply['playabilityStatus'] as Map?)?['status'] as String? ?? 'no status';
    if (status != 'OK') throw YouTubeLookupError(status);
    final formats = ((reply['streamingData'] as Map?)?['adaptiveFormats'] as List?) ?? const [];
    final aac = formats.cast<Map>().where((f) => f['itag'] == _aacItag && f['url'] is String).firstOrNull;
    if (aac == null) throw YouTubeLookupError('no AAC audio');
    final url = aac['url'] as String;
    _links[videoId] = (url: url, until: _usableUntil(url));
    return url;
  }

  Future<String> _currentVisitorId() async {
    final known = _visitorId;
    if (known != null) return known;
    final page = await client.get(Uri.parse('https://www.youtube.com/'), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 10));
    final m = RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(page.body);
    if (m == null) throw YouTubeLookupError('no visitor id');
    return _visitorId = m.group(1)!;
  }

  /// 10 minutes before the link's own `expire` (seconds since 1970); 1 hour when it has none.
  static DateTime _usableUntil(String url) {
    final expire = int.tryParse(Uri.parse(url).queryParameters['expire'] ?? '');
    return expire == null
        ? DateTime.now().add(const Duration(hours: 1))
        : DateTime.fromMillisecondsSinceEpoch(expire * 1000).subtract(const Duration(minutes: 10));
  }
}

class YouTubeLookupError implements Exception {
  final String status;
  YouTubeLookupError(this.status);
  @override
  String toString() => 'YouTube: $status';
}
