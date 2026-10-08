import statistics
import unicodedata
from rapidfuzz import fuzz
from music_backend.models import Listing, Song

# same recording differs 0-4 s across sources and releases in real data (200/201/202/204 for
# Blinding Lights, 261/262/263 for Tum Hi Ho); different edits were further apart (Rosalia remix 206 vs 217)
DURATION_TOLERANCE = 5
# Reciprocal Rank Fusion constant (Cormack et al., 2009): score = sum of 1 / (RRF_K + position)
RRF_K = 60
FUZZ_THRESHOLD = 90
# lower = preferred: JioSaavn serves 320 kbps AAC from URLs that do not expire;
# YouTube Music serves ~133 kbps Opus from URLs that expire and only work from one IP
SOURCE_PREFERENCE = {"jiosaavn" : 0, "ytmusic" : 1}

def normalise(title : str) -> str:
    title = unicodedata.normalize("NFKD", title.lower())
    title = "".join([c for c in title if not unicodedata.combining(c)])

    title = "".join([ch if ch.isalnum() or ch.isspace() else " " for ch in title])
    return " ".join(title.split())

def artists_match(a: list[str], b: list[str]) -> bool:
    a, b = [normalise(name) for name in a], [normalise(name) for name in b]
    for source in a:
        for target in b:
            if source == "" or target == "":
                continue
            if source == target or set(source.split()) <= set(target.split()) or set(source.split()) >= set(target.split()) or fuzz.ratio(source, target) > FUZZ_THRESHOLD:
                return True
    return False

def same_recording(a : Listing, b : Listing) -> bool:
    return normalise(a.title) == normalise(b.title) and artists_match(a.artists, b.artists) and abs(a.duration - b.duration) <= DURATION_TOLERANCE

def interleave(by_source : list[list[Listing]]) -> list[Listing]:
    """Alternate between the sources' ranked lists: #1 of each, then #2 of each, ...

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
    """The listing to play from a group of listings that are all the same recording.

    Compared as a tuple, left to right, so each rule only matters when the earlier ones tie:
      1. preferred source (audio quality and URL reliability)
      2. higher popularity: only ever compared between listings of the SAME source, because
         rule 1 has already separated sources (38 million on JioSaavn and 3.6 billion on
         YouTube Music for the same song are not comparable numbers)
      3. duration closest to the group's median, which steers away from odd edits
    """
    median = statistics.median(listing.duration for listing in group)
    return min(group, key=lambda listing: (
        SOURCE_PREFERENCE[listing.source],
        -(listing.popularity or 0),
        abs(listing.duration - median),
    ))


def rrf_score(group: list[Listing], positions: dict[tuple[str, str], int]) -> float:
    """Reciprocal Rank Fusion: every listing is a vote, worth more the higher its source ranked it.

    A song found 9 times across both sources collects 9 votes; a one-off result collects one.
    Positions, not raw scores, so the sources' incomparable popularity numbers never mix.
    """
    return sum(1 / (RRF_K + positions[(listing.source, listing.id)] + 1) for listing in group)


def rank_songs(by_source: list[list[Listing]]) -> list[Song]:
    """The whole pipeline: interleave, group into songs, order the songs by RRF score."""
    positions = {(listing.source, listing.id) : position
                 for listings in by_source for position, listing in enumerate(listings)}
    groups = group_listings(interleave(by_source))
    songs = [to_song(group, rrf_score(group, positions)) for group in groups]
    # sorted() is stable: songs with equal scores keep their interleaved order
    return sorted(songs, key = lambda song: song.score, reverse = True)


def to_song(group: list[Listing], score: float = 0.0) -> Song:
    """One song from a group: shown with the best listing's details, every listing kept as a fallback."""
    best = pick_best(group)
    return Song(title = best.title, artists = best.artists, duration = best.duration, score = score, best = best, listings = group)
