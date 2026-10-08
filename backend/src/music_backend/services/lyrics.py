"""Lyrics (MUS-12): every lyrics source in turn, answered as parsed lines.

LYRICS_SOURCES lists them in the order they are asked (LRCLIB first: it answers in ~0.6 s; YouTube Music takes
~1.6 s). Timed lyrics from any source win at once. Plain ones are kept, in case nobody has timed ones. A source
with no lines (an instrumental, says LRCLIB) does not stop the search. Nothing found is not an error: the reply
has no lines (the app says "Couldn't find lyrics").
"""
import asyncio
import logging
import re

from ytmusicapi import YTMusic

from music_backend.core.http_client import SharedClient
from music_backend.models import LyricLine, LyricsRequest, LyricsResponse

LRCLIB_URL = "https://lrclib.net/api/get"
# an LRC timestamp: [mm:ss.xx]. Tag lines like [ar: Someone] have letters, so they never match
STAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")

logger = logging.getLogger(__name__)
http = SharedClient(timeout=3, headers={"User-Agent": "NoNonsenseMusic (https://github.com/ego004/NoNonsenseMusic)"})
yt = YTMusic()    # no web request when made (measured 6 Oct); its calls block, so they run in a thread


class LyricsNotFound(Exception):
    """This source has no lyrics for this song: an answer, not a failure."""


async def get_lyrics_lrclib(song: LyricsRequest) -> LyricsResponse:
    r = await http.client.get(LRCLIB_URL, params={"track_name": song.song_name, "artist_name": song.artist_name,
                                                  "duration": song.song_duration})
    # a miss is a 404 one time and a 503 "ServerOverloaded" the next (measured 6 Oct): both mean "not here"
    if r.status_code in (404, 503):
        raise LyricsNotFound(f"LRCLIB answered {r.status_code}")
    r.raise_for_status()                         # anything else is unexpected (a 400: we sent a bad request)
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
    """Blocking (ytmusicapi uses requests): run it with asyncio.to_thread."""
    browse_id = yt.get_watch_playlist(videoId=video_id)["lyrics"]
    if browse_id is None:
        raise LyricsNotFound("YouTube Music has no lyrics for this video")
    try:
        return yt.get_lyrics(browse_id, timestamps=True)
    except KeyError:                             # 'cueRange' on some songs (ytmusicapi issue #1002): untimed still works
        return yt.get_lyrics(browse_id, timestamps=False)


# asked in this order; like SOURCES in main.py, a new source is one more line. Every one takes the whole request
# and raises LyricsNotFound when it has nothing
LYRICS_SOURCES = {"lrclib": get_lyrics_lrclib, "ytmusic": get_lyrics_ytmusic}


async def find_lyrics(song: LyricsRequest) -> tuple[LyricsResponse, bool]:
    """Asks every source in turn: the first timed lyrics, else the first plain ones, else an empty reply. Never
    raises for a source's sake. The bool: every source answered (none failed), so the reply is the best there is
    right now; the cache keeps a reply that is not timed only then (LyricsCache in cache.py)."""
    untimed = None
    every_source_answered = True
    for name, source in LYRICS_SOURCES.items():
        try:
            found = await source(song)
        except LyricsNotFound as e:              # an answer: "not here"
            logger.info("%s: no lyrics for %r: %s", name, song.song_name, e)
            continue
        # lyrics are optional: a failing source is skipped. CancelledError is not an Exception, so a cancelled
        # request still stops (a bare `except:` would swallow it)
        except Exception as e:
            logger.warning("%s: lyrics failed for %r: %r", name, song.song_name, e)
            every_source_answered = False
            continue
        if found.synced:                         # timed: nothing better to find
            return found, every_source_answered
        if found.lines:                          # plain: keep the first, in case nobody has timed ones
            untimed = untimed or found
        # no lines (LRCLIB says "instrumental"): keep looking, another source may have words
    return untimed or LyricsResponse(lyrics_source=None, synced=False, lines=[]), every_source_answered


def parse_lrc(text: str) -> list[LyricLine]:
    """LRC text into timed lines, in time order. A line with two stamps is sung twice: two lines.
    A stamp with no words is kept as "" (a gap: the line before stops being lit)."""
    lines = []
    for raw in text.splitlines():
        words = STAMP.sub("", raw).strip()
        for minutes, seconds in STAMP.findall(raw):
            lines.append(LyricLine(start_ms=round((int(minutes) * 60 + float(seconds)) * 1000), text=words))
    return sorted(lines, key=lambda line: line.start_ms)


def plain_lines(text: str) -> list[LyricLine]:
    """Plain lyrics into lines with no times. Blank lines stay: they are the gaps between verses."""
    return [LyricLine(start_ms=None, text=line.strip()) for line in text.strip().splitlines()]
