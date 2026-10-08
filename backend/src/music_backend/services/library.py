"""Your library: songs stored in PostgreSQL, likes, and play events.

Song IDs are assigned lazily: search results have no IDs. When you like or play a song, the app
sends that song's listings and resolve_song finds the stored song they belong to, or creates it.
"""
import logging
from types import SimpleNamespace
from typing import Literal
from uuid import UUID

from fractional_indexing import FIError, generate_key_between, generate_n_keys_between
from psycopg import AsyncConnection

from music_backend.services.matching import normalise, pick_best, same_recording
from music_backend.models import EventType, LibrarySong, Listing, Member, PlaylistMetadata, PlaylistItem

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
                    """INSERT INTO listings (source, source_id, song_id, title, artists, album, duration, popularity, image, explicit)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                       ON CONFLICT (source, source_id) DO UPDATE SET explicit = EXCLUDED.explicit
                       WHERE listings.explicit IS NULL AND EXCLUDED.explicit IS NOT NULL""",   # fill in an unknown flag
                    [[l.source, l.id, song_id, l.title, l.artists, l.album, l.duration, l.popularity, l.image, l.explicit] for l in same],
                )
    return song_id


async def like(conn: AsyncConnection, user_id: UUID, song_id: UUID) -> None:
    # liking twice is a no-op: (user_id, song_id) is the primary key
    await conn.execute("INSERT INTO likes (user_id, song_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", [user_id, song_id])


async def unlike(conn: AsyncConnection, user_id: UUID, song_id: UUID) -> bool:
    """True if you had liked the song (and now have not)."""
    return (await conn.execute("DELETE FROM likes WHERE user_id = %s AND song_id = %s", [user_id, song_id])).rowcount > 0


async def record_event(conn: AsyncConnection, user_id: UUID, song_id: UUID, event_type: EventType, position: int) -> None:
    await conn.execute(
        "INSERT INTO events (user_id, song_id, type, position) VALUES (%s, %s, %s, %s)",
        [user_id, song_id, event_type, position],
    )


async def liked_songs(conn: AsyncConnection, user_id: UUID) -> list[LibrarySong]:
    rows = await (await conn.execute(
        """SELECT song_id as id, liked_at AS at, true AS liked
             FROM likes WHERE user_id = %s ORDER BY liked_at DESC""",
        [user_id],
    )).fetchall()
    return await _with_listings(conn, rows)


async def recent_songs(conn: AsyncConnection, user_id: UUID, limit: int = 50) -> list[LibrarySong]:
    """Your most recently played songs, each once, newest first. `liked` is YOUR like: the join matches the user too,
    or a song someone else liked would show a filled heart."""
    rows = await (await conn.execute(
        """SELECT e.song_id AS id, max(e.at) AS at, bool_or(k.song_id IS NOT NULL) AS liked
             FROM events e LEFT JOIN likes k ON k.song_id = e.song_id AND k.user_id = e.user_id
            WHERE e.user_id = %s AND e.type = 'play'
            GROUP BY e.song_id
            ORDER BY at DESC
            LIMIT %s""",
        [user_id, limit],
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
            duration = l["duration"], popularity = l["popularity"], image = l["image"], explicit = l["explicit"],
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

# ---------- playlists: who may do what ----------
# Every playlist action starts with one question: what is this user's role on this playlist? The owner is
# playlists.user_id; anyone else's access is a playlist_members row; a public playlist lets everyone view. One query
# answers it (by primary keys only), in one place: no route or query decides access on its own.

Role = Literal["owner", "editor", "viewer"]
_RANK: dict[str, int] = {"viewer": 1, "editor": 2, "owner": 3}

class NoSuchPlaylist(Exception):
    """You cannot see a playlist with this id: it never existed, was deleted, or is someone else's private one. The
    endpoint's 404: a private playlist's existence is not revealed to someone who may not see it."""

class NotAllowed(Exception):
    """You can see this playlist, but your role does not allow this (a viewer adding a song): the endpoint's 403."""

class NoSuchUser(Exception):
    """No account with that username (inviting someone): the endpoint's 404."""

# the role expression, shared by every query that needs it: owner, else your membership, else viewer if public
_ROLE_SQL = """CASE WHEN pl.user_id = %(user)s THEN 'owner'
                    ELSE coalesce(m.role, CASE WHEN pl.public THEN 'viewer' END) END"""

async def _require(conn: AsyncConnection, user_id: UUID, playlist_id: UUID, need: Role, lock: bool = False) -> Role:
    """Your role on the playlist, if it is at least `need`; else NoSuchPlaylist (you cannot see it) or NotAllowed.
    lock=True also takes the playlist's turn (BUG-6): every write that picks or changes a position in it holds the
    playlist's row lock until its transaction commits, so two writers never read the same positions."""
    row = await (await conn.execute(
        f"""SELECT {_ROLE_SQL} AS role
              FROM playlists pl
              LEFT JOIN playlist_members m ON m.playlist_id = pl.id AND m.user_id = %(user)s
             WHERE pl.id = %(playlist)s
             {"FOR UPDATE OF pl" if lock else ""}""",
        {"user": user_id, "playlist": playlist_id})).fetchone()
    if row is None or row["role"] is None:
        raise NoSuchPlaylist(playlist_id)
    if _RANK[row["role"]] < _RANK[need]:
        raise NotAllowed(f"{row['role']} cannot do this")
    return row["role"]

async def _lock_playlist_list(conn: AsyncConnection, user_id: UUID) -> None:
    """Your list of playlists' turn (create, reorder): your own users row, locked until the commit. A second create
    or move of YOUR list waits; other people's never do."""
    await conn.execute("SELECT 1 FROM users WHERE id = %s FOR UPDATE", [user_id])

# one playlist with its totals and your role; the same columns for one playlist and for the list
_SUMMARY_SQL = f"""SELECT pl.id, pl.name, pl.public, {_ROLE_SQL} AS role,
                          count(i.id) AS song_count, coalesce(sum(s.duration), 0) AS duration
                     FROM playlists pl
                     LEFT JOIN playlist_members m ON m.playlist_id = pl.id AND m.user_id = %(user)s
                     LEFT JOIN playlist_items i ON i.playlist_id = pl.id
                     LEFT JOIN songs s ON s.id = i.song_id"""


async def create_playlist(conn: AsyncConnection, user_id: UUID, name : str) -> UUID:
    """A new playlist of yours, private, at the bottom of your list. A name you already use raises UniqueViolation."""
    await _lock_playlist_list(conn, user_id)
    # the bottom = after the largest position so far (None when there are no playlists: then the first key, "a0")
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlists WHERE user_id = %s",
                                      [user_id])).fetchone())["last"]
    row = await (await conn.execute(
        "INSERT INTO playlists (user_id, name, position) VALUES (%s, %s, %s) RETURNING id",
        [user_id, name, generate_key_between(last, None)],
    )).fetchone()
    return row["id"]

async def get_playlists(conn: AsyncConnection, user_id: UUID) -> list[PlaylistMetadata]:
    """Yours, in your order, then those shared with you, with totals and your role: one query. Each half of the union
    is read through its own index (playlists by owner, members by user). Public playlists of others are not listed:
    you open them by id (a link)."""
    rows = await (await conn.execute(
        f"""WITH mine AS (SELECT id, false AS shared FROM playlists WHERE user_id = %(user)s
                          UNION ALL
                          SELECT playlist_id, true FROM playlist_members WHERE user_id = %(user)s)
            {_SUMMARY_SQL}
              JOIN mine ON mine.id = pl.id
             GROUP BY pl.id, m.role, mine.shared
             ORDER BY mine.shared, pl.position, pl.id""",    # pl.id: two at one position keep their order (BUG-6)
        {"user": user_id})).fetchall()
    return [PlaylistMetadata(**row) for row in rows]

async def get_playlist_metadata(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> PlaylistMetadata:
    """One playlist you can see, with its totals and your role: one query. NoSuchPlaylist otherwise."""
    row = await (await conn.execute(
        f"""{_SUMMARY_SQL}
             WHERE pl.id = %(playlist)s
             GROUP BY pl.id, m.role""",
        {"user": user_id, "playlist": playlist_id})).fetchone()
    if row is None or row["role"] is None:
        raise NoSuchPlaylist(playlist_id)
    return PlaylistMetadata(**row)

async def get_playlist_items(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> list[PlaylistItem]:
    """The playlist's songs in order, each shown through its best listing; `liked` is YOUR like. Checks you can see
    it (NoSuchPlaylist), so it is safe on its own; the open route calls get_playlist_metadata first anyway."""
    await _require(conn, user_id, playlist_id, "viewer")
    # one row per ITEM: the same song added twice is two rows. The columns are what _with_listings reads
    # (id = the song, at, liked); item_id rides along. i.id breaks ties: two adds at the same moment could get
    # the same position, and a UUIDv7 sorts by time
    rows = await (await conn.execute(
        """SELECT i.id AS item_id, i.song_id AS id, i.added_at AS at, (k.song_id IS NOT NULL) AS liked
             FROM playlist_items i
             LEFT JOIN likes k ON k.song_id = i.song_id AND k.user_id = %(user)s
            WHERE i.playlist_id = %(playlist)s
            ORDER BY i.position, i.id""", {"user": user_id, "playlist": playlist_id})).fetchall()
    # _with_listings builds each song once; the dict hands the same song to every item that holds it
    songs = {song.id: song for song in await _with_listings(conn, rows)}
    return [PlaylistItem(item_id = r["item_id"], song = songs[r["id"]]) for r in rows if r["id"] in songs]

async def add_to_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, song_id: UUID) -> UUID:
    """At the bottom; editors and the owner. Records who added it."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    # this playlist's last position: the (playlist_id, position) index answers it without reading other playlists
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlist_items WHERE playlist_id = %s",
                                      [playlist_id])).fetchone())["last"]
    return (await (await conn.execute(
        "INSERT INTO playlist_items (playlist_id, song_id, position, added_by) VALUES (%s, %s, %s, %s) RETURNING id",
        [playlist_id, song_id, generate_key_between(last, None), user_id])).fetchone())["id"]

async def remove_from_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, item_id : UUID) -> bool:
    """Editors and the owner. False when the playlist has no such item (an item of another playlist is not one)."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    return (await conn.execute("DELETE FROM playlist_items WHERE id = %s AND playlist_id = %s",
                               [item_id, playlist_id])).rowcount > 0

async def rename_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, name : str) -> None:
    """The owner only. A name you already use raises UniqueViolation."""
    await _require(conn, user_id, playlist_id, "owner")
    await conn.execute("UPDATE playlists SET name = %s WHERE id = %s", [name, playlist_id])

async def set_public(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, public: bool) -> None:
    """The owner only: public = anyone signed in can view it by its id."""
    await _require(conn, user_id, playlist_id, "owner")
    await conn.execute("UPDATE playlists SET public = %s WHERE id = %s", [public, playlist_id])

async def delete_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> None:
    """The owner only. Its items and memberships go with it (ON DELETE CASCADE); the songs stay."""
    await _require(conn, user_id, playlist_id, "owner")
    await conn.execute("DELETE FROM playlists WHERE id = %s", [playlist_id])

async def share_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, username: str, role: str) -> None:
    """The owner invites someone by username, or changes their role ("viewer" or "editor"). NoSuchUser when there is
    no such account; inviting yourself does nothing (you own it)."""
    await _require(conn, user_id, playlist_id, "owner")
    row = await (await conn.execute("SELECT id FROM users WHERE lower(username) = lower(%s)", [username])).fetchone()
    if row is None:
        raise NoSuchUser(username)
    if row["id"] == user_id:
        return
    await conn.execute(
        """INSERT INTO playlist_members (playlist_id, user_id, role) VALUES (%s, %s, %s)
           ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role""",
        [playlist_id, row["id"], role])

async def playlist_members(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> list[Member]:
    """Who is on the playlist: its owner first, then the people it is shared with, oldest invite first. For the owner
    and the members; someone who sees it only because it is public gets NotAllowed (who it is shared with is not
    theirs to know). One query for everyone, after the access check."""
    role = await _require(conn, user_id, playlist_id, "viewer")
    rows = await (await conn.execute(
        """SELECT u.id AS user_id, u.username, 'owner' AS role, 0 AS place, NULL::timestamptz AS added_at
             FROM playlists pl JOIN users u ON u.id = pl.user_id
            WHERE pl.id = %(playlist)s
           UNION ALL
           SELECT u.id, u.username, m.role, 1, m.added_at
             FROM playlist_members m JOIN users u ON u.id = m.user_id
            WHERE m.playlist_id = %(playlist)s
            ORDER BY place, added_at, username""",
        {"playlist": playlist_id})).fetchall()
    if role != "owner" and all(r["user_id"] != user_id for r in rows):
        raise NotAllowed("only its owner and its members see who it is shared with")
    return [Member(user_id=r["user_id"], username=r["username"], role=r["role"]) for r in rows]

async def unshare_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, member_id: UUID) -> bool:
    """The owner removes someone; anyone may remove themselves (leave). False when they were not a member."""
    role = await _require(conn, user_id, playlist_id, "viewer")
    if role != "owner" and member_id != user_id:
        raise NotAllowed("only the owner removes other people")
    return (await conn.execute("DELETE FROM playlist_members WHERE playlist_id = %s AND user_id = %s",
                               [playlist_id, member_id])).rowcount > 0


# ---------- taking turns (BUG-6) ----------
# Every write that picks a position (add, move) reads the positions around it, then writes a key between them. Two at
# the same moment read the same positions and wrote the same key: a tie, and nothing can go between a tie (moving a
# song there answered 422, for good). So they take turns, in the database: row locks (SELECT … FOR UPDATE) on the
# playlist's row, or on your users row for your list, held until the transaction commits. They hold across server
# processes and scripts (a lock in Python holds in one process only); whoever comes next reads what the one before left.

class NotInList(Exception):
    """The row to move, or one of its new neighbours, is not in that list (the endpoint's 404)."""

class BadMove(ValueError):
    """Neighbours in the wrong order, or a row named as its own neighbour (the endpoint's 422)."""

async def move_item(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, item_id : UUID,
                    top_id : UUID | None, bottom_id : UUID | None) -> None:
    """Moves one song of a playlist to between two of its songs; editors and the owner. One row changes (the whole
    playlist only when it held a tie: see `_move`)."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    await _move(conn, "playlist_items", "playlist_id = %s", [playlist_id], item_id, top_id, bottom_id)

async def move_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, top_id : UUID | None,
                        bottom_id : UUID | None) -> None:
    """Moves one of your own playlists to between two others in your list. One row changes (all of them only after a
    tie). Only your own: a shared playlist keeps its owner's order, and as a neighbour it is NotInList."""
    await _lock_playlist_list(conn, user_id)
    await _move(conn, "playlists", "user_id = %s", [user_id], playlist_id, top_id, bottom_id)

async def _move(conn: AsyncConnection, table: str, where: str, args: list, row_id: UUID,
                top_id: UUID | None, bottom_id: UUID | None) -> None:
    """The shared part of both moves, in one list: the rows of `table` that match `where` (one playlist's songs, or
    every playlist). The caller holds the list's turn, so the positions read here stay as read until the commit.
    `table` and `where` are this file's own text, never a request's: safe to put into the SQL."""
    rows = await (await conn.execute(f"SELECT id, position FROM {table} WHERE {where} AND id = ANY(%s)",
                                     [*args, [row_id, top_id, bottom_id]])).fetchall()
    positions = {r["id"]: r["position"] for r in rows}
    for needed in (row_id, top_id, bottom_id):
        if needed is not None and needed not in positions:
            raise NotInList(needed)
    if row_id in (top_id, bottom_id):
        raise BadMove("a row cannot be its own neighbour")
    if top_id is None and bottom_id is None:
        return                                     # nothing to put it between: it stays where it is
    top, bottom = positions.get(top_id), positions.get(bottom_id)    # None: the top or the bottom of the list
    if top is not None and top == bottom:
        # tied neighbours (two adds at once, before the turns): nothing sorts between two equal keys, so the move
        # answered 422 for good. The whole list gets fresh keys once, in the order it shows; never tied after that
        fresh = await _rekey(conn, table, where, args)
        top, bottom = fresh[top_id], fresh[bottom_id]
    try:
        new = generate_key_between(top, bottom)    # sorts between the two neighbours
    except FIError as e:
        raise BadMove("the top neighbour must come before the bottom one") from e
    # the same two neighbours always give the same key: a row moved into this slot since the app last looked (from
    # another window or device) already has it, and the two would tie. Go just after it, still before the bottom one
    while await _taken(conn, table, where, args, new, row_id):
        new = generate_key_between(new, bottom)
    await conn.execute(f"UPDATE {table} SET position = %s WHERE id = %s", [new, row_id])

async def _rekey(conn: AsyncConnection, table: str, where: str, args: list) -> dict[UUID, str]:
    """Every row of the list gets a fresh key, evenly spaced, in the order it shows (position, then id)."""
    ids = [r["id"] for r in await (await conn.execute(
        f"SELECT id FROM {table} WHERE {where} ORDER BY position, id", args)).fetchall()]
    keys = generate_n_keys_between(None, None, len(ids))
    async with conn.cursor() as cur:
        await cur.executemany(f"UPDATE {table} SET position = %s WHERE id = %s", list(zip(keys, ids)))
    return dict(zip(ids, keys))

async def _taken(conn: AsyncConnection, table: str, where: str, args: list, position: str, row_id: UUID) -> bool:
    """Whether another row of the list already has this key."""
    found = await (await conn.execute(f"SELECT 1 FROM {table} WHERE {where} AND position = %s AND id <> %s LIMIT 1",
                                      [*args, position, row_id])).fetchone()
    return found is not None
