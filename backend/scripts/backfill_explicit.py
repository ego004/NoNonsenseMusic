"""MUS-19, once: fill in the explicit flag of listings stored before it existed (7 Oct 2026).

Only fills a flag that is unknown (NULL); never changes a known one, never deletes anything.
JioSaavn: its song-details call, 20 listings per request. YouTube Music: one search per song (title + artist),
2 s apart, matched by video id. Listings a search no longer returns stay unknown; they are filled in when seen again.

    uv run python scripts/backfill_explicit.py                  # your library (DATABASE_URL, default music)
"""
import asyncio

from music_backend import db
from music_backend.sources import jiosaavn, ytmusic


async def main() -> None:
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    await db.apply_schema(pool)                                  # adds the column if this database lacks it
    async with pool.connection() as conn:
        unknown = await (await conn.execute(
            """SELECT l.source, l.source_id, s.title, s.artists FROM listings l JOIN songs s ON s.id = l.song_id
               WHERE l.explicit IS NULL ORDER BY l.source, s.title""")).fetchall()
    print(f"unknown before: {len(unknown)} listings")
    found: dict[tuple[str, str], bool] = {}

    saavn = [r["source_id"] for r in unknown if r["source"] == "jiosaavn"]
    for i in range(0, len(saavn), 20):
        batch = saavn[i:i + 20]
        reply = await jiosaavn.http.client.get(jiosaavn.SEARCH_URL, params={"__call": "song.getDetails", "pids": ",".join(batch)} | jiosaavn.PREAMBLE_PARAMS)
        for song in reply.json().get("songs", []):
            if "explicit_content" in song:
                found[("jiosaavn", song["id"])] = song["explicit_content"] == "1"
        await asyncio.sleep(1)

    youtube = [r for r in unknown if r["source"] == "ytmusic"]
    wanted = {r["source_id"] for r in youtube}
    searches = sorted({(r["title"], r["artists"][0] if r["artists"] else "") for r in youtube})
    for title, artist in searches:
        try:
            for listing in await ytmusic.search(f"{title} {artist}"):
                if listing.id in wanted and listing.explicit is not None:
                    found[("ytmusic", listing.id)] = listing.explicit
        except Exception as e:                                   # one failed search must not stop the rest
            print(f"  search failed for {title!r}: {e!r}")
        await asyncio.sleep(2)                                   # gently: YouTube's bot check reacts to bursts

    async with pool.connection() as conn:
        for (source, source_id), explicit in found.items():
            await conn.execute("UPDATE listings SET explicit = %s WHERE source = %s AND source_id = %s AND explicit IS NULL",
                               [explicit, source, source_id])
        after = (await (await conn.execute("SELECT count(*) AS n FROM listings WHERE explicit IS NULL")).fetchone())["n"]
        counts = await (await conn.execute("SELECT source, explicit, count(*) AS n FROM listings GROUP BY 1, 2 ORDER BY 1, 2")).fetchall()
    print(f"filled: {len(found)}; still unknown: {after}")
    for c in counts: print(f"  {c['source']:9} {('explicit' if c['explicit'] else 'clean' if c['explicit'] is False else 'unknown'):8} {c['n']}")
    await jiosaavn.http.close(); await ytmusic.http.close(); await pool.close()


if __name__ == "__main__":
    asyncio.run(main())
