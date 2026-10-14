"""A re-uploaded video's song, confirmed by a music catalogue.

"slipfunc - until dawn" on Ikigai's channel is "until dawn" by slipfunc, but nothing in the video says which side is the
artist (services/video_titles.py splits a title only when one side is the channel). A catalogue does: YouTube Music or
JioSaavn has a song called "until dawn" by an artist called "slipfunc", and none called "slipfunc" by "until dawn".
Measured on 14 stored titles (14 Oct): 8 confirmed, all right, including "Udaarian - Satinder Sartaaj" (Song - Artist,
which reading by position gets wrong); 6 not found and kept as uploaded; none wrong.

Asked after a song is stored, in the background (confirm_later): one search on each catalogue, at most two titles at a
time, each copy at most once a day. A search never waits for it. Only what the stored copy shows changes (its title and
artists); the song's identity (songs.title) stays as first stored, as with core/reread_titles.py.
"""
import asyncio
import logging
import time
from collections import OrderedDict
from typing import Any

from music_backend.models import Listing
from music_backend.services.matching import normalise
from music_backend.services.video_titles import without_video_labels
from music_backend.sources import jiosaavn, ytmusic

logger = logging.getLogger(__name__)

CATALOGUES: tuple[Any, ...] = (ytmusic, jiosaavn)      # each has search(query) -> list[Listing]
VIDEO_SOURCES = {"youtube", "ytmusic"}
AT_ONCE = 2                    # titles confirmed at the same time: two searches each
ASK_AGAIN_AFTER = 24 * 60 * 60  # seconds: a title no catalogue knows is not searched again before this
REMEMBERED = 10_000            # copies remembered as asked (a dict entry each)

_asked: OrderedDict[tuple[str, str], float] = OrderedDict()
_running: set[asyncio.Task] = set()                    # held so a task is not collected before it finishes
_limits: dict[asyncio.AbstractEventLoop, asyncio.Semaphore] = {}   # one per event loop: a semaphore binds to its loop


def sides(title: str) -> tuple[str, str] | None:
    """"A - B" from a title written that way (its first "|" part, labels about the video removed), else None."""
    parts = [p.strip() for p in without_video_labels(title.split("|")[0]).split(" - ")]
    return (parts[0], parts[1]) if len(parts) == 2 and all(parts) else None


def _names(found: Listing, song: str, artist: str) -> bool:
    """Whether a catalogue song is [song] by [artist]: the artist by exact name, the title word for word, one starting
    the other ("Im sorry" for "Im sorry{}4K{}Sad Lofi{}", "until dawn (feat. X)" for "until dawn")."""
    title, wanted = normalise(found.title), normalise(song)
    same_title = bool(title) and (title == wanted or wanted.startswith(title + " ") or title.startswith(wanted + " "))
    return same_title and any(normalise(a) == normalise(artist) for a in found.artists)


async def confirmed(title: str) -> tuple[str, list[str]] | None:
    """The song an "A - B" title is, as a catalogue names it, when exactly one reading of it is a catalogue song."""
    pair = sides(title)
    if pair is None or not CATALOGUES:
        return None
    a, b = pair
    replies = await asyncio.gather(*(c.search(f"{a} {b}") for c in CATALOGUES), return_exceptions=True)
    found = [l for r in replies if isinstance(r, list) for l in r]
    readings = [next((l for l in found if _names(l, song, artist)), None) for song, artist in ((b, a), (a, b))]
    match = [r for r in readings if r is not None]
    return (match[0].title, list(match[0].artists)) if len(match) == 1 else None


def _due(listing: Listing) -> bool:
    if listing.source not in VIDEO_SOURCES or sides(listing.title) is None:
        return False
    key, now = (listing.source, listing.id), time.monotonic()
    if now - _asked.get(key, -ASK_AGAIN_AFTER) < ASK_AGAIN_AFTER:
        return False
    _asked[key] = now
    _asked.move_to_end(key)
    while len(_asked) > REMEMBERED:
        _asked.popitem(last=False)
    return True


def confirm_later(pool, listings: list[Listing]) -> None:
    """After [listings] are stored: their "A - B" video titles confirmed in the background, never awaited."""
    due = [l for l in listings if _due(l)]
    if not due:
        return
    task = asyncio.get_running_loop().create_task(_confirm(pool, due))
    _running.add(task)
    task.add_done_callback(_running.discard)


async def _confirm(pool, listings: list[Listing]) -> None:
    limit = _limits.setdefault(asyncio.get_running_loop(), asyncio.Semaphore(AT_ONCE))
    for listing in listings:
        try:
            async with limit:
                reading = await confirmed(listing.title)
            if reading is None:
                continue
            async with pool.connection() as conn:
                # only while the stored copy still shows the title that was confirmed
                await conn.execute("UPDATE listings SET title = %s, artists = %s WHERE source = %s AND source_id = %s"
                                   " AND title = %s", [reading[0], reading[1], listing.source, listing.id, listing.title])
        except Exception as e:                        # a background task: logged, never raised into a request
            logger.warning("reading %s %s: %s", listing.source, listing.id, type(e).__name__)
