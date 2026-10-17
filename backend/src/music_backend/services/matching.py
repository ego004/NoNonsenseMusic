"""Match and rank music listings from several sources.

Listings that represent the same recording are grouped into one song, album or artist, and the
groups are ordered by Reciprocal Rank Fusion over the sources' ranked lists.
"""
import re
import statistics
import unicodedata
from collections import defaultdict
from functools import lru_cache
from rapidfuzz import fuzz, process
from music_backend.models import Album, AlbumRef, Artist, ArtistRef, Listing, Song

# The same recording differs by 0-4 s across sources and releases in real data (200/201/202/204 for
# Blinding Lights, 261/262/263 for Tum Hi Ho); different edits sit further apart (Rosalia remix 206 vs 217)
DURATION_TOLERANCE = 5
# Reciprocal Rank Fusion constant (Cormack et al., 2009): score = sum of 1 / (RRF_K + position)
RRF_K = 60
FUZZ_THRESHOLD = 90
# Lower = preferred: JioSaavn serves 320 kbps AAC from URLs that do not expire; YouTube Music serves
# ~133 kbps Opus from URLs that expire and only work from one IP; plain YouTube comes last because its
# raw titles and fan uploads rank below the music sources
SOURCE_PREFERENCE = {"jiosaavn" : 0, "ytmusic" : 1, "youtube" : 2}
# the cover's own order: YouTube Music's art is the release people recognise (the owner's call), then JioSaavn's,
# then a video thumbnail
COVER_PREFERENCE = {"ytmusic" : 0, "jiosaavn" : 1, "youtube" : 2}
# A search's ranking (#25) counts more than the sources' own order. JioSaavn matches the typed words literally and fills
# its list with namesakes and covers ("tadipar": four other artists' "Tadipar" above MC Stan's "Tadipaar", 14 Oct), so
# its order counts half. Each source's list counts again ordered by play count, which compares only within one source
# (that "Tadipaar" has 40 million plays on YouTube Music; the namesake YouTube Music put first, 870 thousand)
ORDER_WEIGHT = {"jiosaavn" : 0.5}
# Votes count copies and places, not how far apart play counts are: three copies of a 3,500-play lofi mix outvoted the
# one copy of Ali Sethi and Shae Gill's "Pasoori", a video with a billion views (#25). So YouTube Music's top result
# goes first, after only the songs with this many times its plays there: the top result a server in India gets for
# "tadipar" is that 870-thousand-play namesake of the 40-million "Tadipaar"
OUTPLAYED = 10
# A typed word this long or longer also matches a word this alike (rapidfuzz ratio, 0-100): "tadipar" and "tadipaar"
# score 93, "kesriya" and "kesariya" 93, "light" and "lights" 91, "shap" and "shape" 89. "black" and "block" (80),
# "money" and "honey" (80) stay apart; a shorter word must be exact ("hi" and "ho": 67)
TYPO_MIN_LENGTH = 4
TYPO_SIMILARITY = 85
# who a title names as featured: "Drowning (feat. Kodak Black)", "Song ft. Someone"
_FEATURED = re.compile(r"\s*[(\[]\s*(?:feat|ft|featuring)\b[^)\]]*[)\]]|\s+(?:feat|ft|featuring)\b.*$", re.IGNORECASE)

@lru_cache(maxsize=16384)   # pure, and asked about the same few titles thousands of times per search's matching
def normalise(title : str) -> str:
    """Normalise a title for comparison: lower case, strip diacritics and punctuation, collapse whitespace."""
    title = unicodedata.normalize("NFKD", title.lower())
    title = "".join([c for c in title if not unicodedata.combining(c)])

    title = "".join([ch if ch.isalnum() or ch.isspace() else " " for ch in title])
    return " ".join(title.split())

def artists_match(a: list[str], b: list[str]) -> bool:
    """Return True if any name in a matches any name in b after normalisation.

    Two names match when they are equal, when one's words are a subset of the other's
    ("The Weeknd" against "the weeknd ft"), or when their fuzzy ratio exceeds FUZZ_THRESHOLD.
    """
    a, b = [normalise(name) for name in a], [normalise(name) for name in b]
    for source in a:
        for target in b:
            if source == "" or target == "":
                continue
            if source == target or set(source.split()) <= set(target.split()) or set(source.split()) >= set(target.split()) or fuzz.ratio(source, target) > FUZZ_THRESHOLD:
                return True
    return False

def same_recording(a : Listing, b : Listing) -> bool:
    """Return True when two listings share a normalised title, matching artists and a close duration."""
    return normalise(a.title) == normalise(b.title) and artists_match(a.artists, b.artists) and abs(a.duration - b.duration) <= DURATION_TOLERANCE


# Official videos drift ~1 min from the album cut (Blinding Lights: 4:23 video vs 3:20 song), so plain
# YouTube matching is looser than same_recording's 5 s; loops and full concerts sit well beyond this
YOUTUBE_DURATION_TOLERANCE = 90


def same_video(song : Song, video : Song) -> bool:
    """Return True when a plain-YouTube video is the same recording as an already-found song.

    Video titles carry prefixes and suffixes the album title does not ("The Weeknd - Blinding Lights
    (Official Video)"), so equality never matches: one normalised title must contain the other on word
    boundaries, the artists must match, and the durations must be within YOUTUBE_DURATION_TOLERANCE.
    """
    a, b = normalise(song.title), normalise(video.title)
    if not a or not b or not (f" {a} " in f" {b} " or f" {b} " in f" {a} "):
        return False
    if not song.artists or not video.artists or not artists_match(song.artists, video.artists):
        return False
    return abs(song.duration - video.duration) <= YOUTUBE_DURATION_TOLERANCE

def interleave(by_source : list[list[Listing]]) -> list[Listing]:
    """Interleave the sources' ranked lists: #1 of each source, then #2 of each, and so on.

    [[j1, j2, j3], [y1]] -> [j1, y1, j2, j3]. Works for any number of sources.
    """
    if not by_source:
        return []
    result = []
    for position in range(max(len(listings) for listings in by_source)):
        for listings in by_source:
            if position < len(listings):
                result.append(listings[position])
    return result

def group_listings(listings: list[Listing]) -> list[list[Listing]]:
    """Group listings that are the same recording, comparing each against the first of each group."""
    groups = []
    for listing in listings:
        added = False
        for i in range(len(groups)):
            if same_recording(listing, groups[i][0]):
                groups[i].append(listing)
                added = True
                break
        if not added:
            groups.append([listing])
    return groups


def pick_best(group: list[Listing]) -> Listing:
    """Return the listing to play from a group whose listings are all the same recording.

    Compared as a tuple, left to right, so each rule only matters when the earlier ones tie:
      1. preferred source (audio quality and URL reliability)
      2. higher popularity: only ever compared between listings of the same source, because
         rule 1 has already separated sources (38 million on JioSaavn and 3.6 billion on
         YouTube Music for the same song are not comparable numbers)
      3. duration closest to the group's median, which steers away from odd edits
      4. the lowest id: JioSaavn gives every release of a recording the same play count and length, so without
         this the pick followed the order the source happened to return them in, which changes between searches
    """
    median = statistics.median(listing.duration for listing in group)
    return min(group, key=lambda listing: (
        SOURCE_PREFERENCE[listing.source],
        -(listing.popularity or 0),
        abs(listing.duration - median),
        listing.id,
    ))


def pick_cover(group: list) -> str | None:
    """The cover for a group of listings that are all the same recording, or None when none has art.

    The listings are the recording's releases (the single, the album, later compilations), each with its own art.
    The choice depends only on the set, never on its order: COVER_PREFERENCE, then the most played (play counts
    compare within one source), then the lowest id. A stored song keeps the cover chosen when it was created
    (songs.image), so copies linked later never change it. Albums and artists are picked the same way (their copies
    have no play count): JioSaavn's artist photo is a 50 px image or a silhouette, YouTube Music's a real one (#27).
    """
    with_art = [listing for listing in group if listing.image]
    if not with_art:
        return None
    return min(with_art, key=lambda listing: (
        COVER_PREFERENCE.get(listing.source, len(COVER_PREFERENCE)),
        -(getattr(listing, "popularity", None) or 0),
        listing.id,
    )).image


def rrf_score(group: list[Listing], votes: dict[tuple[str, str], float]) -> float:
    """Return the Reciprocal Rank Fusion score of a group of listings: the sum of its listings' votes (rank_songs).

    Every listing is a vote, worth more the higher its source ranked it: a song found 9 times across
    both sources collects 9 votes, a one-off result collects one. Positions, not raw scores, so the
    sources' incomparable popularity numbers never mix.
    """
    return sum(votes[(listing.source, listing.id)] for listing in group)


def rank_songs(by_source: list[list[Listing]], *, plays: bool = False, top: Listing | None = None) -> list[Song]:
    """Run the whole song pipeline: interleave, group into songs, order the songs by RRF score.

    Each list votes by position. A search (plays=True) counts as ORDER_WEIGHT says: JioSaavn's order at half weight,
    and every list once more by play count. `top`, YouTube Music's top result, is that source's first, and its song
    goes first as OUTPLAYED says; a music video of a song already found becomes one more copy of it (a fallback, as
    merge_youtube's), not a second row. Radio and imports keep the sources' order.
    """
    lists = list(by_source)
    if top is not None:
        own = next((i for i, listings in enumerate(lists) if listings and listings[0].source == top.source), None)
        if own is None:
            lists.append([top])
        else:
            # the songs list's own copy carries the play count a top-result card lacks
            top = next((listing for listing in lists[own] if listing.id == top.id), top)
            lists[own] = [top] + [listing for listing in lists[own] if listing is not top]
    votes: dict[tuple[str, str], float] = defaultdict(float)
    for listings in lists:
        for position, listing in enumerate(listings):
            votes[(listing.source, listing.id)] += (ORDER_WEIGHT.get(listing.source, 1) if plays else 1) / (RRF_K + position + 1)
        if plays:
            by_plays = sorted((listing for listing in listings if listing.popularity), key = lambda l: -l.popularity)
            for position, listing in enumerate(by_plays):
                votes[(listing.source, listing.id)] += 1 / (RRF_K + position + 1)
    songs = [to_song(group, rrf_score(group, votes)) for group in group_listings(interleave(lists))]
    if top is not None:
        first = next(song for song in songs if any(listing is top for listing in song.listings))
        target = len(first.listings) == 1 and next((song for song in songs if song is not first and same_video(song, first)), None)
        if target:
            songs.remove(first)
            target.listings.append(top)
            target.score += first.score
            first = target
        # only a top result whose plays are known goes first (a song card says none, and one missing from the songs list
        # could not be outplayed); a song with OUTPLAYED times its plays goes before it
        bar = plays_on(first, top.source)
        if bar:
            lift = max(song.score for song in songs)
            first.score += lift
            for song in songs:
                if song is not first and plays_on(song, top.source) >= OUTPLAYED * bar:
                    song.score += 2 * lift
    # sorted() is stable: songs with equal scores keep their interleaved order
    return sorted(songs, key = lambda song: song.score, reverse = True)


def plays_on(song: Song, source: str) -> int:
    """A song's most played copy on one source (play counts compare only within one), 0 when none says."""
    return max((listing.popularity or 0 for listing in song.listings if listing.source == source), default = 0)


def to_song(group: list[Listing], score: float = 0.0) -> Song:
    """Build one Song from a group: shown with the best listing's details, every listing kept as a
    fallback."""
    best = pick_best(group)
    return Song(title = best.title, artists = best.artists, duration = best.duration, score = score, best = best,
                listings = group, image = pick_cover(group))


def found(word: str, have: set[str]) -> bool:
    """Whether a typed word is among a title's and its artists' words: as typed, or as a word TYPO_SIMILARITY alike."""
    return word in have or (len(word) >= TYPO_MIN_LENGTH and
                            process.extractOne(word, have, scorer = fuzz.ratio, score_cutoff = TYPO_SIMILARITY) is not None)


def words_of(names: list[str]) -> set[str]:
    """The words found() looks among: a title's and its artists' (or any names'), normalised, each once. A stored copy
    keeps its own (listings.words), so the library is searched without normalising it again (#26)."""
    return set(normalise(" ".join(names)).split())


class Vocabulary:
    """Every word stored copies have (listings.words), by length: the words a typed word may be a typo of.

    Searching the library (#26) asks the database for the copies that hold, for each typed word, one of the words found()
    would take for it. Those words come from here, so no song of the library is compared with what was typed one by
    one, and the cost grows little with the library (library.matching_songs has the measurements).
    """
    def __init__(self) -> None:
        self._known: set[str] = set()
        self._by_length: dict[int, list[str]] = defaultdict(list)

    def add(self, words: list[str]) -> None:
        for word in words:
            if word not in self._known:
                self._known.add(word)
                self._by_length[len(word)].append(word)

    def alike(self, word: str) -> list[str]:
        """The word itself, then every known word found() takes for it: for TYPO_MIN_LENGTH letters or more, those
        TYPO_SIMILARITY alike. Only lengths that can be that alike are compared: a ratio is 200 × the common letters over
        both lengths, so 85 needs the shorter word to be at least 85/115 of the longer."""
        n = len(word)
        if n < TYPO_MIN_LENGTH:
            return [word]
        low, high = -(-n * TYPO_SIMILARITY // (200 - TYPO_SIMILARITY)), n * (200 - TYPO_SIMILARITY) // TYPO_SIMILARITY
        return [word, *(other for length in range(low, high + 1)
                        for other, _, _ in process.extract(word, self._by_length.get(length, ()), scorer = fuzz.ratio,
                                                           score_cutoff = TYPO_SIMILARITY, limit = None)
                        if other != word)]


def coverage(query: str, song: Song, lead: bool = False) -> float:
    """How much of what was typed a song contains: the share of the query's words found (typos allowed) in a title and
    its artists, the best of the song's copies. lead=True leaves out who it features: every artist but the first, and a
    title's "(feat. …)"."""
    words = normalise(query).split()
    if not words:
        return 1.0
    most = 0
    for listing in song.listings:
        have = words_of([_FEATURED.sub("", listing.title), *listing.artists[:1]] if lead else [listing.title, *listing.artists])
        most = max(most, sum(found(word, have) for word in words))
    return most / len(words)


def by_relevance(songs: list[Song], query: str) -> list[Song]:
    """Songs that contain more of what was typed first, in steps of a fifth. Within a step, songs it names by their
    title or first artist before those it names only by a featured artist; within those, the order they had.

    The sources' own order put popular songs that share a word or two above the one asked for: "who cares if you exist
    eisu remix" ranked "Who Cares" (2 of 7 words) and "Wait for You" by I-Exist first (13 Oct). An artist's name put
    their features first: Gucci Mane's "Wake Up in the Sky" (with Kodak Black) for "kodak black", King's "KODAK" for
    "seedhe maut" (#25). A short query that every result contains keeps the order unchanged.
    """
    return sorted(songs, key = lambda song: (-round(coverage(query, song) * 5), -round(coverage(query, song, lead = True) * 5)))


def merge_youtube(songs: list[Song], videos: list[Listing]) -> list[Song]:
    """Merge plain-YouTube results into the ranked songs, below every music-source song.

    A video that is the same recording as an already-found song becomes one more listing on it, a
    playback fallback rather than a second row. Anything new is appended after all music songs
    (score 0, below every RRF score), leaving the music ranking unchanged.
    """
    for group in group_listings(videos):
        video = to_song(group)
        target = next((song for song in songs if same_video(song, video)), None)
        if target is None:
            songs.append(video)
        else:
            # appended last: the app falls back to it only after the music sources' copies fail
            target.listings.append(video.best)
    return songs


def library_first(songs: list[Song], mine: list[Song], query: str) -> list[Song]:
    """The user's own songs that match (library.matching_songs) first, marked in_library, then the sources' songs: each
    song once (#26).

    A source's song that has a copy in common with one of the user's is that song: its copies join the user's row (the
    copy that plays is picked again among them all, as pick_best does; the stored cover stays) and it is not listed again
    below. The user's songs keep the order they came in (those the sources found, in the sources' order, then the most
    recently added), except that those the query names by title or first artist go first (by_relevance, as for the
    rest).
    """
    owner = {(listing.source, listing.id): own for own in mine for listing in own.listings}
    rest = []
    for song in songs:
        own = next((owner[key] for key in ((l.source, l.id) for l in song.listings) if key in owner), None)
        if own is None:
            rest.append(song)
            continue
        for listing in song.listings:
            if (listing.source, listing.id) not in owner:
                owner[(listing.source, listing.id)] = own
                own.listings.append(listing)
        own.score = max(own.score, song.score)
    first = []
    for own in mine:
        song = to_song(own.listings, own.score)
        song.image = own.image or song.image
        song.in_library = True
        first.append(song)
    return by_relevance(first, query) + rest


# ---------- albums and artists: the same pipeline, over AlbumRefs and ArtistRefs ----------

def same_album(a: AlbumRef, b: AlbumRef) -> bool:
    """Return True when two refs are the same album: identical normalised title and matching artists.

    Year is not compared: an edition's year can differ between stores without the album being a
    different album.
    """
    return normalise(a.title) == normalise(b.title) and bool(a.artists) and bool(b.artists) and artists_match(a.artists, b.artists)


def same_artist(a: ArtistRef, b: ArtistRef) -> bool:
    """Return True when two refs are the same artist: the name is the whole identity.

    A plain-YouTube "The Weeknd - Topic" channel still word-matches "The Weeknd".
    """
    return bool(a.name) and bool(b.name) and artists_match([a.name], [b.name])


def group_refs(items: list, same) -> list[list]:
    """Group items that are the same thing (same_album / same_artist): first match wins, order kept."""
    groups = []
    for item in items:
        for group in groups:
            if same(group[0], item):
                group.append(item)
                break
        else:
            groups.append([item])
    return groups


def rank_albums(by_source: list[list[AlbumRef]]) -> list[Album]:
    """Interleave, group the same album across sources, order by RRF: the songs pipeline (rank_songs)."""
    positions = {(ref.source, ref.id) : position
                 for refs in by_source for position, ref in enumerate(refs)}
    groups = group_refs(interleave(by_source), same_album)
    albums = [to_album(group, sum(1 / (RRF_K + positions[(ref.source, ref.id)] + 1) for ref in group))
              for group in groups]
    return sorted(albums, key = lambda album: album.score, reverse = True)


def to_album(group: list[AlbumRef], score: float = 0.0) -> Album:
    """Build one Album from a group: shown with the preferred source's copy, every copy kept."""
    best = min(group, key = lambda ref: SOURCE_PREFERENCE[ref.source])
    return Album(title = best.title, artists = best.artists, year = best.year, image = pick_cover(group),
                 song_count = best.song_count, explicit = best.explicit, score = score,
                 best = best, listings = group)


def rank_artists(by_source: list[list[ArtistRef]]) -> list[Artist]:
    """Run the same pipeline for artists."""
    positions = {(ref.source, ref.id) : position
                 for refs in by_source for position, ref in enumerate(refs)}
    groups = group_refs(interleave(by_source), same_artist)
    artists = [to_artist(group, sum(1 / (RRF_K + positions[(ref.source, ref.id)] + 1) for ref in group))
               for group in groups]
    return sorted(artists, key = lambda artist: artist.score, reverse = True)


def artists_by_name(artists: list[Artist], query: str) -> list[Artist]:
    """Artists whose name has more of what was typed first, then those whose name is more of what was typed (the
    artist named exactly first), in steps of a fifth; within a step, the order they had. "mc stan" ranked an artist named
    "Roderick Frank Standish, James Derrick Richard Standish, …" above MC STAN (15 Oct, #25)."""
    typed = set(normalise(query).split())
    def key(artist: Artist) -> tuple[int, int]:
        name = set(normalise(artist.name).split())
        if not typed or not name:
            return (0, 0)
        return (-round(sum(found(word, name) for word in typed) / len(typed) * 5),
                -round(sum(found(word, typed) for word in name) / len(name) * 5))
    return sorted(artists, key = key)


def to_artist(group: list[ArtistRef], score: float = 0.0) -> Artist:
    """Build one Artist from a group: shown with the preferred source's copy."""
    best = min(group, key = lambda ref: SOURCE_PREFERENCE[ref.source])
    return Artist(name = best.name, image = pick_cover(group), score = score, best = best, listings = group)
