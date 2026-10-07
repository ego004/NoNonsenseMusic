"""Your library: songs stored in PostgreSQL, likes, and play events.

Song IDs are assigned lazily: search results have no IDs. When you like or play a song, the app
sends that song's listings and resolve_song finds the stored song they belong to, or creates it.
"""
import logging
from types import SimpleNamespace
from typing import Any
from uuid import UUID

from fractional_indexing import FIError, generate_key_between
from psycopg import AsyncConnection

from music_backend.matching import normalise, pick_best, same_recording
from music_backend.models import EventType, LibrarySong, Listing, PlaylistMetadata, PlaylistItem

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
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", [normalise(first.title)])
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
        same = [l for l in listings if same_recording(identity, l)]
        if same:
            # executemany: every listing in one round trip (psycopg pipelines them), not one trip per listing
            async with conn.cursor() as cur:
                await cur.executemany(
                    """INSERT INTO listings (source, source_id, song_id, title, artists, album, duration, popularity, image)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                       ON CONFLICT (source, source_id) DO NOTHING""",
                    [[l.source, l.id, song_id, l.title, l.artists, l.album, l.duration, l.popularity, l.image] for l in same],
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
        """SELECT song_id as id, liked_at AS at, true AS liked
             FROM likes ORDER BY liked_at DESC""",
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

async def create_playlist(conn: AsyncConnection, name : str) -> UUID:
    """A new playlist at the bottom of your list. A name already in use raises psycopg's UniqueViolation."""
    # the bottom = after the largest position so far (None when there are no playlists: then the first key, "a0")
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlists")).fetchone())["last"]
    row = await (await conn.execute(
        "INSERT INTO playlists (name, position) VALUES (%s, %s) RETURNING id",
        [name, generate_key_between(last, None)],
    )).fetchone()
    return row["id"]

async def get_playlists(conn: AsyncConnection) -> list[PlaylistMetadata]:
    """Every playlist with its totals, in one query. It used to be one query, then one more per playlist (7 Oct)."""
    rows = await (await conn.execute(
        """SELECT pl.id, pl.name, COUNT(s.id) AS song_count, COALESCE(SUM(s.duration), 0) AS duration
             FROM playlists pl
             LEFT JOIN playlist_items p ON p.playlist_id = pl.id
             LEFT JOIN songs s ON s.id = p.song_id
            GROUP BY pl.id, pl.name, pl.position
            ORDER BY pl.position ASC""")).fetchall()
    return [PlaylistMetadata(**row) for row in rows]

async def _totals(conn: AsyncConnection, playlist_id : UUID) -> Any | None:
    """{"song_count": n, "duration": seconds} for one playlist; shared by the list and the open."""
    # AS: the keys become the model's field names. COALESCE: an empty playlist's SUM is NULL, and duration is an int
    return await (await conn.execute(
        """SELECT COUNT(*) AS song_count, COALESCE(SUM(duration), 0) AS duration
             FROM songs s JOIN playlist_items p ON s.id = p.song_id
            WHERE p.playlist_id = %s""", [playlist_id])).fetchone()

async def get_playlist_metadata(conn: AsyncConnection, playlist_id : UUID) -> PlaylistMetadata | None:
    """One playlist's metadata; None when there is no such playlist (the endpoint's 404)."""
    row = await (await conn.execute("SELECT id, name FROM playlists WHERE id = %s", [playlist_id])).fetchone()
    if row is None:
        return None
    return PlaylistMetadata(id = row["id"], name = row["name"], **await _totals(conn, playlist_id))

async def add_to_playlist(conn: AsyncConnection, playlist_id : UUID, song_id: UUID) -> UUID:
    # this playlist's last position: the (playlist_id, position) index answers it without reading other playlists
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlist_items WHERE playlist_id = %s",
                                      [playlist_id])).fetchone())["last"]
    return (await (await conn.execute("INSERT INTO playlist_items (playlist_id, song_id, position) VALUES (%s, %s, %s) RETURNING id", [playlist_id, song_id, generate_key_between(last, None)])).fetchone())["id"]

async def get_playlist_items(conn: AsyncConnection, playlist_id : UUID) -> list[PlaylistItem]:
    """The playlist's songs in your order, each shown through its best listing (like Liked Songs)."""
    # one row per ITEM: the same song added twice is two rows. The columns are what _with_listings reads
    # (id = the song, at, liked); item_id rides along. i.id breaks ties: two adds at the same moment can get
    # the same position, and a UUIDv7 sorts by time
    rows = await (await conn.execute(
        """SELECT i.id AS item_id, i.song_id AS id, i.added_at AS at, (k.song_id IS NOT NULL) AS liked
             FROM playlist_items i
             LEFT JOIN likes k ON k.song_id = i.song_id
            WHERE i.playlist_id = %s
            ORDER BY i.position, i.id""", [playlist_id])).fetchall()
    # _with_listings builds each song once; the dict hands the same song to every item that holds it
    songs = {song.id: song for song in await _with_listings(conn, rows)}
    return [PlaylistItem(item_id = r["item_id"], song = songs[r["id"]]) for r in rows if r["id"] in songs]

async def rename_playlist(conn: AsyncConnection, playlist_id : UUID, name : str) -> bool:
    """False when there is no such playlist. A name already in use raises psycopg's UniqueViolation."""
    return (await conn.execute("UPDATE playlists SET name = %s WHERE id = %s", [name, playlist_id])).rowcount > 0

async def delete_playlist(conn: AsyncConnection, playlist_id : UUID) -> bool:
    """False when there is no such playlist. Its items go with it (ON DELETE CASCADE); the songs stay."""
    return (await conn.execute("DELETE FROM playlists WHERE id = %s", [playlist_id])).rowcount > 0

async def remove_from_playlist(conn: AsyncConnection, playlist_id : UUID, item_id : UUID) -> bool:
    """False when this playlist has no such item. Both ids must match: an item of another playlist is not removed."""
    return (await conn.execute("DELETE FROM playlist_items WHERE id = %s AND playlist_id = %s",
                               [item_id, playlist_id])).rowcount > 0


class NotInList(Exception):
    """The row to move, or one of its new neighbours, is not in that list (the endpoint's 404)."""

class BadMove(ValueError):
    """Neighbours in the wrong order, or a row named as its own neighbour (the endpoint's 422)."""

async def move_item(conn: AsyncConnection, playlist_id : UUID, item_id : UUID,
                    top_id : UUID | None, bottom_id : UUID | None) -> None:
    """Moves one song of a playlist to between two of its songs. Exactly one row changes."""
    rows = await (await conn.execute(
        "SELECT id, position FROM playlist_items WHERE playlist_id = %s AND id = ANY(%s)",
        [playlist_id, [item_id, top_id, bottom_id]])).fetchall()
    await _move(conn, "UPDATE playlist_items SET position = %s WHERE id = %s", rows, item_id, top_id, bottom_id)

async def move_playlist(conn: AsyncConnection, playlist_id : UUID, top_id : UUID | None, bottom_id : UUID | None) -> None:
    """Moves one playlist to between two others in your list. Exactly one row changes."""
    rows = await (await conn.execute(
        "SELECT id, position FROM playlists WHERE id = ANY(%s)", [[playlist_id, top_id, bottom_id]])).fetchall()
    await _move(conn, "UPDATE playlists SET position = %s WHERE id = %s", rows, playlist_id, top_id, bottom_id)

async def _move(conn: AsyncConnection, update_sql : str, rows : list[dict], row_id : UUID,
                top_id : UUID | None, bottom_id : UUID | None) -> None:
    """The shared part of both moves. `rows` holds the positions of whichever of the three ids are in the list."""
    positions = {r["id"]: r["position"] for r in rows}
    for needed in (row_id, top_id, bottom_id):
        if needed is not None and needed not in positions:
            raise NotInList(needed)
    if row_id in (top_id, bottom_id):
        raise BadMove("a row cannot be its own neighbour")
    if top_id is None and bottom_id is None:
        return                                     # nothing to put it between: it stays where it is
    try:
        # the new key sorts between the two neighbours; a missing neighbour is None (the top or the bottom)
        new = generate_key_between(positions.get(top_id), positions.get(bottom_id))
    except FIError as e:
        raise BadMove("the top neighbour must come before the bottom one") from e
    await conn.execute(update_sql, [new, row_id])
