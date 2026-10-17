"""Read every stored YouTube and YouTube Music video's song and artist again, as the sources read them now.

Videos stored before the title reader (13 Oct) show their video's title and channel: "slipfunc - until dawn" by Ikigai.
Each is looked up again and read as a new listing would be: plain YouTube through oEmbed (the title and channel as
uploaded; the player page is refused from a data centre), YouTube Music through its watch page (which says whether the
video is an upload, a music video or a song: ytmusic.named). An "A - B" title is then confirmed against the catalogues
(services/readings.py). Only what a listing shows changes. A song's identity
(songs.title, which new copies are compared with) stays as first stored.

    uv run python -m music_backend.core.reread_titles            # lists what would change
    uv run python -m music_backend.core.reread_titles --apply    # changes it
"""
import argparse
import asyncio
from collections.abc import Callable

import httpx

from music_backend.core import db
from music_backend.services import library, readings
from music_backend.services.video_titles import parse_video_title
from music_backend.sources import ytmusic

OEMBED_URL = "https://www.youtube.com/oembed"
PAUSE_SECONDS = 0.3          # between two lookups: a few hundred at once would look like a bot

Reading = tuple[str, list[str]]


def youtube_reading(video_id: str) -> Reading | None:
    r = httpx.get(OEMBED_URL, params={"url": f"https://www.youtube.com/watch?v={video_id}", "format": "json"}, timeout=10)
    if r.status_code != 200:                          # removed or private
        return None
    d = r.json()
    return parse_video_title(d["title"], d["author_name"])


def ytmusic_reading(video_id: str) -> Reading | None:
    rows = ytmusic.client().get_watch_playlist(videoId=video_id, limit=1).get("tracks") or []
    row = next((r for r in rows if r.get("videoId") == video_id and r.get("title")), None)
    # a song (ATV) is named by YouTube Music itself, nothing to re-read: its watch page credits more artists than its
    # search row did, and would reorder them ("Aati Kya Khandala" gained its composer first, 13 Oct)
    if row is None or row.get("videoType") == "MUSIC_VIDEO_TYPE_ATV":
        return None
    return ytmusic.named(row)


READERS: dict[str, Callable[[str], Reading | None]] = {"youtube": youtube_reading, "ytmusic": ytmusic_reading}


async def reread(pool, apply: bool, readers: dict[str, Callable[[str], Reading | None]] = READERS,
                 pause: float = PAUSE_SECONDS) -> list[str]:
    """Each changed listing as "source id: old → new", written when [apply]. A lookup that fails leaves its row as it is."""
    async with pool.connection() as conn:
        rows = await (await conn.execute("SELECT source, source_id, title, artists FROM listings WHERE source = ANY(%s)"
                                         " ORDER BY source, source_id", [list(readers)])).fetchall()
    changes = []
    for row in rows:
        try:
            reading = await asyncio.to_thread(readers[row["source"]], row["source_id"])
            # "slipfunc - until dawn" on Ikigai's channel: "until dawn" by slipfunc when a catalogue has that song
            if reading is not None and readings.sides(reading[0]) is not None:
                reading = await readings.confirmed(reading[0]) or reading
        except Exception as e:                        # one video unreachable: the rest still go
            print(f"skipped {row['source']} {row['source_id']}: {type(e).__name__}")
            reading = None
        if reading is not None and reading != (row["title"], row["artists"]):
            changes.append(f"{row['source']} {row['source_id']}: {row['title']!r} by {row['artists']}"
                           f" → {reading[0]!r} by {reading[1]}")
            if apply:
                async with pool.connection() as conn:
                    await conn.execute("UPDATE listings SET title = %s, artists = %s, words = %s"
                                       " WHERE source = %s AND source_id = %s",
                                       [*reading, library.stored_words(*reading), row["source"], row["source_id"]])
        await asyncio.sleep(pause)
    return changes


async def main(apply: bool) -> None:
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    try:
        changes = await reread(pool, apply)
    finally:
        await pool.close()
    print("\n".join(changes))
    print(f"{len(changes)} {'changed' if apply else 'would change (run with --apply)'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the changes (without it, only list them)")
    asyncio.run(main(parser.parse_args().apply))
