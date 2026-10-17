import 'api.dart';
import 'models.dart';

// Albums and artists: read-only pages from the sources, nothing stored until an album is pinned. The names and rules
// match the Mac app (mac/NoNonsense/Models/Models.swift, Services/API.swift).

/// One source's copy of an album: enough to open it (GET /album/{source}/{id}).
class AlbumRef {
  final String source, id, title;
  final List<String> artists;
  final int? year, songCount;
  final String? image;
  const AlbumRef(
      {required this.source,
      required this.id,
      required this.title,
      this.artists = const [],
      this.year,
      this.image,
      this.songCount});

  factory AlbumRef.fromJson(Map<String, dynamic> j) => AlbumRef(
        source: j['source'] as String,
        id: j['id'] as String,
        title: j['title'] as String,
        artists: [...(j['artists'] as List? ?? const []).cast<String>()],
        year: (j['year'] as num?)?.toInt(),
        image: j['image'] as String?,
        songCount: (j['song_count'] as num?)?.toInt(),
      );

  @override
  bool operator ==(Object other) => other is AlbumRef && other.source == source && other.id == id;
  @override
  int get hashCode => Object.hash(source, id);
}

/// One source's copy of an artist: enough to open it (GET /artist/{source}/{id}).
class ArtistRef {
  final String source, id, name;
  final String? image;
  const ArtistRef({required this.source, required this.id, required this.name, this.image});

  factory ArtistRef.fromJson(Map<String, dynamic> j) => ArtistRef(
      source: j['source'] as String, id: j['id'] as String, name: j['name'] as String, image: j['image'] as String?);

  @override
  bool operator ==(Object other) => other is ArtistRef && other.source == source && other.id == id;
  @override
  int get hashCode => Object.hash(source, id);
}

/// An album found on one or more sources; [best] is the copy to open.
class SearchAlbum {
  final String title;
  final AlbumRef best;
  const SearchAlbum(this.title, this.best);
  factory SearchAlbum.fromJson(Map<String, dynamic> j) =>
      SearchAlbum(j['title'] as String, AlbumRef.fromJson(j['best'] as Map<String, dynamic>));
}

/// An artist found on one or more sources; [best] is the copy to open.
class SearchArtist {
  final String name;
  final String? image;
  final ArtistRef best;
  const SearchArtist(this.name, this.image, this.best);
  factory SearchArtist.fromJson(Map<String, dynamic> j) => SearchArtist(
      j['name'] as String, j['image'] as String?, ArtistRef.fromJson(j['best'] as Map<String, dynamic>));

  /// The picture to draw: the merged artist's own, else the opened copy's.
  String? get picture => image ?? best.image;
}

/// What GET /search answers: songs, and (for the filters that ask for them) artists and albums.
class SearchResult {
  final List<Track> songs;
  final List<SearchArtist> artists;
  final List<AlbumRef> albums;
  final List<({String source, bool healthy})> sources;

  /// How many of [songs], from the first, are the user's own: liked, in their playlists or downloaded (#26). The server
  /// lists them first and marks them in_library; a search without the server finds only these.
  final int yours;
  const SearchResult(
      {this.songs = const [], this.artists = const [], this.albums = const [], this.sources = const [], this.yours = 0});

  bool get isEmpty => songs.isEmpty && artists.isEmpty && albums.isEmpty;

  /// Sources whose results are missing because they did not answer, by name, for the line above the results.
  List<String> get unavailable => [for (final s in sources) if (!s.healthy) Listing.nameOfSource(s.source)];

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        songs: [for (final s in (j['songs'] as List? ?? const [])) Track.fromSong(s as Map<String, dynamic>)],
        yours: (j['songs'] as List? ?? const []).takeWhile((s) => (s as Map)['in_library'] == true).length,
        artists: [
          for (final a in (j['artists'] as List? ?? const [])) SearchArtist.fromJson(a as Map<String, dynamic>),
        ],
        albums: [
          for (final a in (j['albums'] as List? ?? const []))
            SearchAlbum.fromJson(a as Map<String, dynamic>).best,
        ],
        sources: [
          for (final s in (j['sources'] as List? ?? const []))
            (source: (s as Map)['source'] as String, healthy: s['healthy'] as bool? ?? true),
        ],
      );
}

/// GET /album/{source}/{id}: the album and its tracks, in track order.
class AlbumDetail {
  final String source, id, title;
  final List<String> artists;
  final int? year;
  final String? image;
  final List<Track> songs;
  const AlbumDetail(
      {required this.source,
      required this.id,
      required this.title,
      required this.artists,
      this.year,
      this.image,
      required this.songs});

  factory AlbumDetail.fromJson(Map<String, dynamic> j) => AlbumDetail(
        source: j['source'] as String,
        id: j['id'] as String,
        title: j['title'] as String,
        artists: [...(j['artists'] as List? ?? const []).cast<String>()],
        year: (j['year'] as num?)?.toInt(),
        image: j['image'] as String?,
        songs: [for (final s in j['songs'] as List) Track.fromSong(s as Map<String, dynamic>)],
      );

  /// The reference the album is pinned and looked up by.
  AlbumRef get ref =>
      AlbumRef(source: source, id: id, title: title, artists: artists, year: year, image: image, songCount: songs.length);

  /// The cover to draw: the album's own, else its first song's.
  String? get cover => image ?? songs.firstOrNull?.image;

  int get minutes => songs.fold<int>(0, (a, t) => a + t.duration) ~/ 60;
}

/// GET /artist/{source}/{id}: the artist, their top songs (best first) and their albums.
class ArtistDetail {
  final String source, id, name;
  final String? image;
  final int? followers, monthlyListeners;
  final List<Track> songs;
  final List<AlbumRef> albums;
  const ArtistDetail(
      {required this.source,
      required this.id,
      required this.name,
      this.image,
      this.followers,
      this.monthlyListeners,
      required this.songs,
      required this.albums});

  factory ArtistDetail.fromJson(Map<String, dynamic> j) => ArtistDetail(
        source: j['source'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        image: j['image'] as String?,
        followers: (j['followers'] as num?)?.toInt(),
        monthlyListeners: (j['monthly_listeners'] as num?)?.toInt(),
        songs: [for (final s in (j['songs'] as List? ?? const [])) Track.fromSong(s as Map<String, dynamic>)],
        albums: [for (final a in (j['albums'] as List? ?? const [])) AlbumRef.fromJson(a as Map<String, dynamic>)],
      );

  /// "1.2M monthly listeners", else "340K followers", else null.
  String? get audience {
    final n = monthlyListeners ?? followers;
    return n == null ? null : '${compactCount(n)} ${monthlyListeners != null ? 'monthly listeners' : 'followers'}';
  }
}

/// 1234 becomes "1.2K", 1500000 becomes "1.5M": the compact form the artist page shows.
String compactCount(int n) {
  String short(double v, String unit) => '${v >= 100 || v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)}$unit';
  if (n >= 1000000000) return short(n / 1000000000, 'B');
  if (n >= 1000000) return short(n / 1000000, 'M');
  if (n >= 1000) return short(n / 1000, 'K');
  return '$n';
}

/// The server calls for browsing and radio, kept apart from [Api]: each is one request through its helpers.
class Catalog {
  /// GET /search. [filter] is "all" (songs, albums and artists), or one of "songs", "artists", "albums" alone, which
  /// asks the sources for less.
  static Future<SearchResult> search(String q, {String filter = 'all'}) async =>
      SearchResult.fromJson(await Api.getJson('search', {'q': q, 'filter': filter}) as Map<String, dynamic>);

  static Future<AlbumDetail> album(AlbumRef ref) async => AlbumDetail.fromJson(
      await Api.getJson('album/${Uri.encodeComponent(ref.source)}/${Uri.encodeComponent(ref.id)}') as Map<String, dynamic>);

  static Future<ArtistDetail> artist(ArtistRef ref) async => ArtistDetail.fromJson(
      await Api.getJson('artist/${Uri.encodeComponent(ref.source)}/${Uri.encodeComponent(ref.id)}') as Map<String, dynamic>);

  /// POST /albums/pin: the album copied into the user's playlists as a pinned album. A 409 means it already is.
  static Future<PlaylistSummary> pinAlbum(AlbumRef ref) async => PlaylistSummary.fromJson(
      await Api.sendJson('POST', 'albums/pin', {'source': ref.source, 'source_id': ref.id}) as Map<String, dynamic>);

  /// POST /radio: songs like [seed], leaving out [exclude] (the server takes 100 at most: the newest, at its end, as
  /// on the Mac) and, with [skipRecent], what the user played lately.
  static Future<List<Track>> radio(Listing seed, List<Listing> exclude, {int limit = 20, required bool skipRecent}) async {
    final newest = exclude.length > 100 ? exclude.sublist(exclude.length - 100) : exclude;
    final j = await Api.sendJson('POST', 'radio', {
      'seed': {'source': seed.source, 'source_id': seed.id},
      'exclude': [for (final l in newest) {'source': l.source, 'source_id': l.id}],
      'limit': limit,
      'skip_recent': skipRecent,
    }) as Map<String, dynamic>;
    return [for (final s in j['songs'] as List) Track.fromSong(s as Map<String, dynamic>)];
  }

  /// The best match for [name] among [found]: the same name first (case and accents ignored), else the first, which
  /// is the search's best. Null when nothing was found.
  static T? bestByName<T>(List<T> found, String name, String Function(T) nameOf) {
    final plain = GeniusNotes.plain(name);
    for (final f in found) {
      if (GeniusNotes.plain(nameOf(f)) == plain) return f;
    }
    return found.firstOrNull;
  }

  /// Resolves an artist known only by name (a song's artist line) to the page to open.
  static Future<ArtistRef?> artistNamed(String name) async {
    final found = (await search(name, filter: 'artists')).artists;
    return bestByName(found, name, (a) => a.name)?.best;
  }

  /// Resolves an album known by its title and artist (a song's album) to the page to open.
  static Future<AlbumRef?> albumNamed(String title, String artist) async {
    final found = (await search('$title $artist'.trim(), filter: 'albums')).albums;
    return bestByName(found, title, (a) => a.title);
  }
}
