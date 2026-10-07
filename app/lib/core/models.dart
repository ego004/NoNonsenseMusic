// Mirrors of the server's JSON, and Track: what every screen and the player use.
// Ported from the Mac app (mac/NoNonsense/Models/Models.swift); the rules match it.

/// One copy of a song on one source.
class Listing {
  final String source; // "jiosaavn" | "ytmusic"
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int duration;
  final int? popularity;
  final String? image;

  /// The explicit version (MUS-19); null: not known.
  final bool? explicit;

  const Listing({
    required this.source,
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    required this.duration,
    this.popularity,
    this.image,
    this.explicit,
  });

  /// Unique across sources: the same id string could exist on two sources.
  String get key => '$source:$id';
  String get sourceName => source == 'jiosaavn' ? 'JioSaavn' : 'YouTube Music';

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        source: j['source'] as String,
        id: j['id'] as String,
        title: j['title'] as String,
        artists: (j['artists'] as List).cast<String>(),
        album: j['album'] as String?,
        duration: (j['duration'] as num).toInt(),
        popularity: (j['popularity'] as num?)?.toInt(),
        image: j['image'] as String?,
        explicit: j['explicit'] as bool?,
      );

  /// Every field, a missing one as null: the server's model needs `album` and `popularity` present even when empty
  /// (it answered 422 "Field required" to the Mac app before that was so, 5 Oct).
  Map<String, dynamic> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        'artists': artists,
        'album': album,
        'duration': duration,
        'popularity': popularity,
        'image': image,
        'explicit': explicit,
      };
}

/// What every screen and the player work with, from a search or the library.
class Track {
  final String id; // the best listing's key
  final Listing best; // the copy to play
  final List<Listing> listings; // every copy: fallbacks, "N versions"

  /// Settings › Playback › Version: true (the default) plays a song's explicit version when it has one.
  static bool prefersExplicit = true;

  Track._(this.best, this.listings) : id = best.key;

  /// Your version first (explicit or clean), in the order: the server's pick, its source, most played. Then the
  /// listings: the default copy, the same source, the rest, most popular first (the fallback order).
  factory Track(Listing serverBest, List<Listing> listings, {bool choosingVersion = true}) {
    int rank(Listing l, Listing ref) => l.source == ref.source ? 0 : 1;
    int byRank(Listing a, Listing b, Listing ref) {
      final r = rank(a, ref).compareTo(rank(b, ref));
      return r != 0 ? r : (b.popularity ?? 0).compareTo(a.popularity ?? 0);
    }

    final inOrder = [serverBest, ...([...listings]..sort((a, b) => byRank(a, b, serverBest)))];
    final best = choosingVersion
        ? inOrder.firstWhere((l) => l.explicit == prefersExplicit, orElse: () => serverBest)
        : serverBest;
    final others = listings.where((l) => l.key != best.key).toList()..sort((a, b) => byRank(a, b, best));
    return Track._(best, [best, ...others]);
  }

  factory Track.fromSong(Map<String, dynamic> j) => Track(
        Listing.fromJson(j['best'] as Map<String, dynamic>),
        (j['listings'] as List).map((l) => Listing.fromJson(l as Map<String, dynamic>)).toList(),
      );

  String get title => best.title;
  List<String> get artists => best.artists;
  String get artistLine => artists.join(', ');
  int get duration => best.duration;
  String? get image => best.image;
  bool get isExplicit => best.explicit == true;

  /// The same song, playing one chosen copy exactly.
  Track playing(Listing listing) => Track(listing, listings, choosingVersion: false);

  /// Same song, whichever copy plays: the same set of listings.
  bool isSameSong(Track other) {
    if (id == other.id) return true;
    if (listings.length != other.listings.length) return false;
    return listings.map((l) => l.key).toSet().containsAll(other.listings.map((l) => l.key));
  }

  @override
  bool operator ==(Object other) => other is Track && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// A stored song (Liked, Recently Played): a Track with its id in your library.
class LibrarySong {
  final String songId;
  final Track track;
  LibrarySong(this.songId, this.track);
  factory LibrarySong.fromJson(Map<String, dynamic> j) => LibrarySong(j['id'] as String, Track.fromSong(j));
}

/// "3:20"
String formatTime(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
