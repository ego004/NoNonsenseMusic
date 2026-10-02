"""Your library: songs stored in PostgreSQL, likes, and play events.

Song IDs are assigned lazily: search results have no IDs. When you like or play a song, the app
sends that song's listings and resolve_song finds the stored song they belong to, or creates it.
"""
import logging
from types import SimpleNamespace
from uuid import UUID

from psycopg import AsyncConnection

from music_backend.matching import normalise, pick_best, same_recording
from music_backend.models import EventType, LibrarySong, Listing

logger = logging.getLogger(__name__)


async def resolve_song(conn: AsyncConnection, listings: list[Listing]) -> UUID:
    """The stored song these listings are copies of: found, or created. New listings get linked.

    1. Exact identity: is ANY of these listings already linked to a song? (safe to check all of
       them: identity cannot chain the way similarity can)
    2. Otherwise similarity, but only against songs with the same normalised title (indexed),
       because same_recording requires equal titles anyway
    3. Otherwise a new song, whose frozen identity is the first listing (the group's centre)
    Then: link each new listing, but only if it is the same recording as the song's frozen identity,
    so the song's centre never drifts across searches (200 -> 204 -> 208 -> ...).
    """
    first = listings[0]
    async with conn.transaction():
        linked = await (await conn.execute(
            """SELECT DISTINCT s.id, s.created_at
                 FROM listings l
                 JOIN songs s ON s.id = l.song_id
                 JOIN unnest(%s::text[], %s::text[]) AS k(source, source_id)
                   ON (l.source, l.source_id) = (k.source, k.source_id)
                ORDER BY s.created_at""",
            [[l.source for l in listings], [l.id for l in listings]],
        )).fetchall()

        song_id = linked[0]["id"] if linked else None
        if len(linked) > 1:
            # e.g. 200 s and 204 s were stored as two songs under the old 3 s rule; merging is not built yet
            logger.warning("listings span %d stored songs %s; using the oldest", len(linked), [r["id"] for r in linked])

        if song_id is None:
            candidates = await (await conn.execute(
                "SELECT id, title, artists, duration FROM songs WHERE normalised_title = %s ORDER BY created_at",
                [normalise(first.title)],
            )).fetchall()
            song_id = next((c["id"] for c in candidates if same_recording(SimpleNamespace(**c), first)), None)

        if song_id is None:
            song_id = (await (await conn.execute(
                """INSERT INTO songs (title, artists, duration, normalised_title)
                   VALUES (%s, %s, %s, %s) RETURNING id""",
                [first.title, first.artists, first.duration, normalise(first.title)],
            )).fetchone())["id"]

        identity = SimpleNamespace(**(await (await conn.execute(
            "SELECT title, artists, duration FROM songs WHERE id = %s", [song_id],
        )).fetchone()))
        for listing in listings:
            if same_recording(identity, listing):
                await conn.execute(
                    """INSERT INTO listings (source, source_id, song_id, title, artists, album, duration, popularity, image)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                       ON CONFLICT (source, source_id) DO NOTHING""",
                    [listing.source, listing.id, song_id, listing.title, listing.artists, listing.album,
                     listing.duration, listing.popularity, listing.image],
                )
    return song_id


async def like(conn: AsyncConnection, song_id: UUID) -> None:
    # liking twice is a no-op: likes.song_id is the primary key
    await conn.execute("INSERT INTO likes (song_id) VALUES (%s) ON CONFLICT DO NOTHING", [song_id])


async def unlike(conn: AsyncConnection, song_id: UUID) -> bool:
    """True if the song was liked (and now is not)."""
    return (await conn.execute("DELETE FROM likes WHERE song_id = %s", [song_id])).rowcount > 0


async def record_event(conn: AsyncConnection, song_id: UUID, event_type: EventType, position: int) -> None:
    await conn.execute(
        "INSERT INTO events (song_id, type, position) VALUES (%s, %s, %s)", [song_id, event_type, position],
    )


async def liked_songs(conn: AsyncConnection) -> list[LibrarySong]:
    rows = await (await conn.execute(
        """SELECT s.id, k.liked_at AS at, true AS liked
             FROM likes k JOIN songs s ON s.id = k.song_id
            ORDER BY k.liked_at DESC""",
    )).fetchall()
    return await _with_listings(conn, rows)


async def recent_songs(conn: AsyncConnection, limit: int = 50) -> list[LibrarySong]:
    """Most recently played songs, each once, newest first."""
    rows = await (await conn.execute(
        """SELECT e.song_id AS id, max(e.at) AS at, bool_or(k.song_id IS NOT NULL) AS liked
             FROM events e LEFT JOIN likes k ON k.song_id = e.song_id
            WHERE e.type = 'play'
            GROUP BY e.song_id
            ORDER BY at DESC
            LIMIT %s""",
        [limit],
    )).fetchall()
    return await _with_listings(conn, rows)


async def _with_listings(conn: AsyncConnection, rows: list[dict]) -> list[LibrarySong]:
    """Attach each song's stored listings and show it through its best listing (display != identity)."""
    if not rows:
        return []
    listing_rows = await (await conn.execute(
        "SELECT * FROM listings WHERE song_id = ANY(%s) ORDER BY created_at", [[r["id"] for r in rows]],
    )).fetchall()
    by_song: dict[UUID, list[Listing]] = {}
    for l in listing_rows:
        by_song.setdefault(l["song_id"], []).append(Listing(
            source = l["source"], id = l["source_id"], title = l["title"], artists = l["artists"], album = l["album"],
            duration = l["duration"], popularity = l["popularity"], image = l["image"],
        ))
    songs = []
    for r in rows:
        listings = by_song.get(r["id"], [])
        if not listings:
            continue
        best = pick_best(listings)
        songs.append(LibrarySong(
            id = r["id"], title = best.title, artists = best.artists, duration = best.duration,
            best = best, listings = listings, liked = r["liked"], at = r["at"],
        ))
    return songs
