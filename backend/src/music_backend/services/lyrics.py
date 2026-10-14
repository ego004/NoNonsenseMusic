"""Fetch lyrics from every source in turn, answered as parsed lines.

LYRICS_SOURCES lists them in the order they are asked (LRCLIB first: it answers in ~0.6 s; YouTube Music takes
~1.6 s). Timed lyrics from any source win at once. Plain ones are kept, in case no source has timed ones. A
source with no lines (an instrumental, says LRCLIB) does not stop the search. Nothing found is not an error: the
reply has no lines, and the app says "Couldn't find lyrics".
"""
import asyncio
import logging
import re
from collections.abc import AsyncIterator

from music_backend.core.http_client import SharedClient
from music_backend.models import LyricLine, LyricsRequest, LyricsResponse
from music_backend.services.matching import normalise
from music_backend.services.video_titles import without_video_labels
from music_backend.sources import jiosaavn, ytmusic

LRCLIB_URL = "https://lrclib.net/api/get"
# an LRC timestamp: [mm:ss.xx]. Tag lines like [ar: Someone] have letters, so they never match
STAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")

logger = logging.getLogger(__name__)
http = SharedClient(timeout=3, headers={"User-Agent": "NoNonsenseMusic (https://github.com/ego004/NoNonsenseMusic)"})


class LyricsNotFound(Exception):
    """This source has no lyrics for this song: an answer, not a failure."""


async def get_lyrics_lrclib(song: LyricsRequest) -> LyricsResponse:
    r = await http.client.get(LRCLIB_URL, params={"track_name": song.song_name, "artist_name": song.artist_name,
                                                  "duration": song.song_duration})
    # a miss is a 404 one time and a 503 "ServerOverloaded" the next: both mean "not here"
    if r.status_code in (404, 503):
        raise LyricsNotFound(f"LRCLIB answered {r.status_code}")
    r.raise_for_status()                         # anything else is unexpected: a 400 means a malformed request
    found = r.json()
    if found["syncedLyrics"]:
        return LyricsResponse(lyrics_source="lrclib", synced=True, lines=parse_lrc(found["syncedLyrics"]))
    if found["plainLyrics"]:
        return LyricsResponse(lyrics_source="lrclib", synced=False, lines=plain_lines(found["plainLyrics"]))
    return LyricsResponse(lyrics_source="lrclib", synced=False, lines=[])


async def get_lyrics_ytmusic(song: LyricsRequest) -> LyricsResponse:
    if song.youtube_id is None:
        raise LyricsNotFound("the song has no YouTube copy")
    found = await asyncio.to_thread(youtube_lyrics, song.youtube_id)    # the function and its argument, separately
    if found["hasTimestamps"]:
        lines = [LyricLine(start_ms=line.start_time, text=line.text) for line in found["lyrics"]]
        return LyricsResponse(lyrics_source="ytmusic", synced=True, lines=lines)
    return LyricsResponse(lyrics_source="ytmusic", synced=False, lines=plain_lines(found["lyrics"]))


def youtube_lyrics(video_id: str) -> dict:
    """Make the blocking ytmusicapi calls (they use requests): run this with asyncio.to_thread.

    The client is this thread's own (ytmusic.client): a requests.Session is not thread-safe, and two lyrics lookups
    run on two worker threads at once.
    """
    yt = ytmusic.client()
    browse_id = yt.get_watch_playlist(videoId=video_id)["lyrics"]
    if browse_id is None:
        raise LyricsNotFound("YouTube Music has no lyrics for this video")
    try:
        return yt.get_lyrics(browse_id, timestamps=True)
    except KeyError:                             # 'cueRange' on some songs (ytmusicapi #1002): untimed still works
        return yt.get_lyrics(browse_id, timestamps=False)


# Sources are asked in this order; like SOURCES in main.py, adding a source is one more line. Each takes the
# whole request and raises LyricsNotFound when it has nothing
LYRICS_SOURCES = {"lrclib": get_lyrics_lrclib, "ytmusic": get_lyrics_ytmusic}
# seconds the identified song may differ from the video for its timed lyrics to still fit it
TIMING_SLACK = 10
# a video's title with more than a song's name in it: "Lomtre - slow days", "Coke Studio | Season 14 | Pasoori"
_SEVERAL_PARTS = re.compile(r"\s-\s|:\s|\|")
_DASH = re.compile(r"\s+-\s+")


async def find_lyrics(song: LyricsRequest) -> tuple[LyricsResponse, bool]:
    """Ask every source in turn: the first timed lyrics, else the first plain ones, else an empty reply. A
    source's failure never raises. The bool is True when every source answered, meaning the reply is the best
    available; the cache stores an untimed reply only in that case (LyricsCache in cache.py).

    Nothing found for a song named by its video ("Lomtre - slow days" by the channel Ikigai): asked again under the
    names it may have (_other_names).
    """
    found, complete = await _ask_sources(song)
    if found.lines:
        return found, complete
    async for named in _other_names(song):
        again, complete_again = await _ask_sources(named)
        if not again.lines:
            continue
        if again.synced and abs(named.song_duration - song.song_duration) > TIMING_SLACK:
            # timed for another cut (a music video with an intro): the words are right, the times are not
            again = again.model_copy(update={"synced": False, "lines": [l.model_copy(update={"start_ms": None}) for l in again.lines]})
        return again, complete and complete_again
    return found, complete


async def _other_names(song: LyricsRequest) -> AsyncIterator[LyricsRequest]:
    """The names a video's song may have, each only a question: a source answers just its own song. First the
    catalogues' copy, searched by the video's title (_catalog_copy). Then both readings of "A - B": LRCLIB matches the
    title, the artist and the length (±5 s), so the wrong order finds nothing ("The Weeknd" by "Blinding Lights" did
    not, 14 Oct). Nothing for a title that is a name alone ("Kesariya" by Arijit Singh)."""
    if not _SEVERAL_PARTS.search(song.song_name):
        return
    copy = await _catalog_copy(song, song.song_name)
    if copy:
        yield copy
    sides = _DASH.split(without_video_labels(song.song_name.split("|")[0]))
    if len(sides) == 2 and all(s.strip() for s in sides):
        for name, artist in ((sides[1], sides[0]), (sides[0], sides[1])):
            yield LyricsRequest(song_name=name.strip(), artist_name=artist.strip(), song_duration=song.song_duration)


async def _catalog_copy(song: LyricsRequest, query: str) -> LyricsRequest | None:
    """A catalogue result whose title and artist are both written in the video's title or channel: "Blinding Lights"
    by The Weeknd for his video. A length that agrees is no evidence: searched by title alone, "Taiko - Leaves" (150 s)
    found "leaves" by PROVIDENCE144 (149 s), and "Pasoori" another band's (13 Oct)."""
    written = f" {normalise(song.song_name)} {normalise(song.artist_name)} "

    def named(text: str) -> bool:
        return f" {normalise(text)} " in written

    for source in (ytmusic, jiosaavn):
        try:
            results = await source.search(query)
        except Exception as e:                    # a catalogue down: the title's reading is used instead
            logger.info("lyrics: %s search failed (%s)", source.__name__.rsplit(".", 1)[-1], type(e).__name__)
            continue
        for found in results:
            if named(found.title) and any(named(a) for a in found.artists):
                return LyricsRequest(song_name=found.title, artist_name=found.artists[0], song_duration=found.duration,
                                     youtube_id=found.id if found.source == "ytmusic" else None)
    return None


async def _ask_sources(song: LyricsRequest) -> tuple[LyricsResponse, bool]:
    untimed = None
    every_source_answered = True
    for name, source in LYRICS_SOURCES.items():
        try:
            found = await source(song)
        except LyricsNotFound as e:              # "not here": an answer rather than a failure
            logger.info("%s: no lyrics for a song: %s", name, e)
            continue
        # lyrics are optional: a failing source is skipped. CancelledError is not an Exception, so a cancelled
        # request still stops (a bare `except:` would swallow it)
        except Exception as e:
            logger.warning("%s: lyrics failed: %s", name, type(e).__name__)
            every_source_answered = False
            continue
        if found.synced:                         # timed: nothing better to find
            return found, every_source_answered
        if found.lines:                          # plain: keep the first, in case no source has timed ones
            untimed = untimed or found
        # no lines (LRCLIB says "instrumental"): keep looking, another source may have words
    return untimed or LyricsResponse(lyrics_source=None, synced=False, lines=[]), every_source_answered


def parse_lrc(text: str) -> list[LyricLine]:
    """Convert LRC text into timed lines, in time order. A line with two stamps is sung twice: two lines.
    A stamp with no words yields "" (a gap: the line before stops being lit)."""
    lines = []
    for raw in text.splitlines():
        words = STAMP.sub("", raw).strip()
        for minutes, seconds in STAMP.findall(raw):
            lines.append(LyricLine(start_ms=round((int(minutes) * 60 + float(seconds)) * 1000), text=words))
    return sorted(lines, key=lambda line: line.start_ms)


def plain_lines(text: str) -> list[LyricLine]:
    """Convert plain lyrics into lines with no times. Blank lines stay: they are the gaps between verses."""
    return [LyricLine(start_ms=None, text=line.strip()) for line in text.strip().splitlines()]
