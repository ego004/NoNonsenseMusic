"""Store the user's library: songs in PostgreSQL, likes, and play events.

Song IDs are assigned lazily: search results have no IDs. When the user likes or plays a song, the
app sends that song's listings, and resolve_song finds the stored song they belong to, or creates it.
"""
import logging
from types import SimpleNamespace
from typing import Literal
from uuid import UUID

from fractional_indexing import FIError, generate_key_between, generate_n_keys_between
from psycopg import AsyncConnection

from music_backend.services import notifications
from music_backend.services.served import ServedListings
from music_backend.services.matching import Vocabulary, normalise, pick_best, pick_cover, same_recording, words_of
from music_backend.models import (EventType, LibrarySong, Listing, Member, Notification,
                                  PlaylistMetadata, PlaylistItem, Song)

logger = logging.getLogger(__name__)

# Every word the stored copies have, in this process: read at start (load_words: 1 s and 1.3 MB for 23,000 words of
# 500,000 copies, 18 Oct), and added to as copies are stored here. A copy another process stores (core/reread_titles.py)
# adds its words at the next start; until then a typo of only those words finds nothing, the words as stored at once
vocabulary = Vocabulary()


def stored_words(title: str, artists: list[str]) -> list[str]:
    """What listings.words holds for a copy: its title's and artists' words (matching.words_of), in order. Written with
    the title and artists, wherever they are written."""
    return sorted(words_of([title, *artists]))


class UnknownListing(Exception):
    """A listing the server never returned and has not stored: nothing vouches for its title or cover (the endpoint's
    422)."""


def _stored_listing(row: dict) -> Listing:
    return Listing(source = row["source"], id = row["source_id"], title = row["title"], artists = row["artists"],
                   album = row["album"], duration = row["duration"], popularity = row["popularity"],
                   image = row["image"], explicit = row["explicit"])


async def trusted_listings(conn: AsyncConnection, served: ServedListings, listings: list[Listing]) -> list[Listing]:
    """Replace each listing a client sent with the server's own copy of it, for resolve_song to store.

    Only the (source, id) of what the client sent is used. The copy comes from what the server recently returned, else
    from the listings table. A listing in neither raises UnknownListing: a real id with an invented title or cover
    would otherwise be stored for every user to see.
    """
    found = [served.get(l.source, l.id) for l in listings]
    missing = [l for l, copy in zip(listings, found) if copy is None]
    if missing:
        rows = await (await conn.execute(
            """SELECT l.* FROM listings l
                 JOIN unnest(%s::text[], %s::text[]) AS k(source, source_id)
                   ON (l.source, l.source_id) = (k.source, k.source_id)""",
            [[l.source for l in missing], [l.id for l in missing]],
        )).fetchall()
        stored = {(r["source"], r["source_id"]): _stored_listing(r) for r in rows}
        found = [copy or stored.get((l.source, l.id)) for l, copy in zip(listings, found)]
    if None in found:
        raise UnknownListing()
    return found


async def resolve_song(conn: AsyncConnection, listings: list[Listing]) -> UUID:
    """Return the stored song these listings are copies of, creating it if needed; link new listings.

    Resolution runs in three steps:
    1. Exact identity: whether any of these listings is already linked to a song (safe to check all
       of them, because identity cannot chain the way similarity can).
    2. Otherwise similarity, but only against songs with the same normalised title (indexed),
       because same_recording requires equal titles anyway.
    3. Otherwise a new song, whose frozen identity is the first listing (the group's centre).

    Each listing is linked only if it is the same recording as the song's frozen identity, so the
    centre never drifts across searches (200 -> 204 -> 208 -> ...).
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
            # 200 s and 204 s can sit in two stored songs; merging them is not built yet
            logger.warning("listings span %d stored songs %s; using the oldest", len(linked), [r["id"] for r in linked])

        if song_id is None:
            candidates = await (await conn.execute(
                "SELECT id, title, artists, duration FROM songs WHERE normalised_title = %s ORDER BY created_at",
                [normalise(first.title)],
            )).fetchall()
            song_id = next((c["id"] for c in candidates if same_recording(SimpleNamespace(**c), first)), None)

        if song_id is None:
            song_id = (await (await conn.execute(
                """INSERT INTO songs (title, artists, duration, normalised_title, image)
                   VALUES (%s, %s, %s, %s, %s) RETURNING id""",
                [first.title, first.artists, first.duration, normalise(first.title),
                 pick_cover([l for l in listings if same_recording(first, l)])],
            )).fetchone())["id"]

        identity = SimpleNamespace(**(await (await conn.execute(
            "SELECT title, artists, duration FROM songs WHERE id = %s", [song_id],
        )).fetchone()))
        same = [l for l in listings if same_recording(identity, l)]
        if same:
            words = [stored_words(l.title, l.artists) for l in same]
            # executemany: every listing in one round trip (psycopg pipelines them), not one trip per listing
            async with conn.cursor() as cur:
                await cur.executemany(
                    """INSERT INTO listings (source, source_id, song_id, title, artists, album, duration, popularity, image,
                                             explicit, words)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                       ON CONFLICT (source, source_id) DO UPDATE SET explicit = EXCLUDED.explicit
                       WHERE listings.explicit IS NULL AND EXCLUDED.explicit IS NOT NULL""",   # fill in an unknown flag
                    [[l.source, l.id, song_id, l.title, l.artists, l.album, l.duration, l.popularity, l.image, l.explicit, w]
                     for l, w in zip(same, words)],
                )
            for w in words:
                vocabulary.add(w)
    return song_id


async def like(conn: AsyncConnection, user_id: UUID, song_id: UUID) -> None:
    # liking twice is a no-op: (user_id, song_id) is the primary key
    await conn.execute("INSERT INTO likes (user_id, song_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", [user_id, song_id])


async def unlike(conn: AsyncConnection, user_id: UUID, song_id: UUID) -> bool:
    """Return whether the user had liked the song (and now has not)."""
    return (await conn.execute("DELETE FROM likes WHERE user_id = %s AND song_id = %s", [user_id, song_id])).rowcount > 0


async def record_event(conn: AsyncConnection, user_id: UUID, song_id: UUID, event_type: EventType, position: int) -> None:
    """Store one event of this type at a position in the song."""
    await conn.execute(
        "INSERT INTO events (user_id, song_id, type, position) VALUES (%s, %s, %s, %s)",
        [user_id, song_id, event_type, position],
    )


async def liked_songs(conn: AsyncConnection, user_id: UUID) -> list[LibrarySong]:
    """Return the user's liked songs, newest like first."""
    rows = await (await conn.execute(
        """SELECT song_id as id, liked_at AS at, true AS liked
             FROM likes WHERE user_id = %s ORDER BY liked_at DESC""",
        [user_id],
    )).fetchall()
    return await _with_listings(conn, rows)


# How far back "recent" looks. A user's events only grow, and both queries below would otherwise group every play
# they ever made on each call; the (user_id, at) index lets this window read only its own rows.
RECENT_DAYS = 90


async def recent_songs(conn: AsyncConnection, user_id: UUID, limit: int = 50) -> list[LibrarySong]:
    """Return the user's most recently played songs, each once, newest first.

    `liked` is the user's own like: the join matches the user too, so a song someone else liked
    would not show a filled heart.
    """
    rows = await (await conn.execute(
        """SELECT e.song_id AS id, max(e.at) AS at, bool_or(k.song_id IS NOT NULL) AS liked
             FROM events e LEFT JOIN likes k ON k.song_id = e.song_id AND k.user_id = e.user_id
            WHERE e.user_id = %s AND e.type = 'play' AND e.at > now() - make_interval(days => %s)
            GROUP BY e.song_id
            ORDER BY at DESC
            LIMIT %s""",
        [user_id, RECENT_DAYS, limit],
    )).fetchall()
    return await _with_listings(conn, rows)


async def copies_of(conn: AsyncConnection, source: str, source_id: str) -> list[dict]:
    """Every stored copy (source, source_id, title, artists) of the song this copy belongs to, this one first; empty
    when the copy was never stored."""
    return await (await conn.execute(
        """SELECT l.source, l.source_id, l.title, l.artists FROM listings l
             JOIN listings seed ON seed.song_id = l.song_id
            WHERE seed.source = %(source)s AND seed.source_id = %(id)s
            ORDER BY (l.source = %(source)s AND l.source_id = %(id)s) DESC, l.source, l.source_id""",
        {"source": source, "id": source_id})).fetchall()


async def recent_listing_refs(conn: AsyncConnection, user_id: UUID, songs: int = 50) -> set[tuple[str, str]]:
    """Return the (source, source_id) of every listing of the user's last `songs` played songs.

    This set is the server-side exclusion for POST /radio: the station skips what the user played
    most recently, even when the app's own exclude list was cut short.
    """
    rows = await (await conn.execute(
        """SELECT l.source, l.source_id
             FROM listings l
            WHERE l.song_id IN (
                SELECT song_id FROM (
                    SELECT song_id, max(at) AS last_at FROM events
                     WHERE user_id = %s AND type = 'play' AND at > now() - make_interval(days => %s)
                     GROUP BY song_id ORDER BY last_at DESC LIMIT %s
                ) recent)""",
        [user_id, RECENT_DAYS, songs],
    )).fetchall()
    return {(r["source"], r["source_id"]) for r in rows}


async def _with_listings(conn: AsyncConnection, rows: list[dict]) -> list[LibrarySong]:
    """Attach each song's stored listings and show it through its best listing; display is not identity."""
    if not rows:
        return []
    # s.image renamed: SELECT * would let the song's columns overwrite the listing's (title, artists, image)
    listing_rows = await (await conn.execute(
        """SELECT l.*, s.image AS song_image FROM listings l JOIN songs s ON s.id = l.song_id
            WHERE l.song_id = ANY(%s) ORDER BY l.created_at""", [[r["id"] for r in rows]],
    )).fetchall()
    by_song: dict[UUID, list[Listing]] = {}
    covers: dict[UUID, str | None] = {}
    for l in listing_rows:
        by_song.setdefault(l["song_id"], []).append(_stored_listing(l))
        covers[l["song_id"]] = l["song_image"]
    # songs stored before songs.image existed: their cover is chosen now, once, and kept
    missing = [(pick_cover(by_song[song_id]), song_id) for song_id, image in covers.items() if image is None]
    missing = [(image, song_id) for image, song_id in missing if image is not None]
    if missing:
        async with conn.cursor() as cur:
            await cur.executemany("UPDATE songs SET image = %s WHERE id = %s AND image IS NULL", missing)
        covers.update({song_id: image for image, song_id in missing})
    songs = []
    for r in rows:
        listings = by_song.get(r["id"], [])
        if not listings:
            continue
        best = pick_best(listings)
        songs.append(LibrarySong(
            id = r["id"], title = best.title, artists = best.artists, duration = best.duration,
            best = best, listings = listings, image = covers.get(r["id"]), liked = r["liked"], at = r["at"],
        ))
    return songs


async def stored_covers(conn: AsyncConnection, listings: list[Listing]) -> dict[tuple[str, str], str]:
    """The stored cover of every song these listings are linked to, by (source, id): search shows a song you have
    stored with the same cover as your library does."""
    if not listings:
        return {}
    rows = await (await conn.execute(
        """SELECT l.source, l.source_id, s.image
             FROM listings l
             JOIN songs s ON s.id = l.song_id
             JOIN unnest(%s::text[], %s::text[]) AS k(source, source_id)
               ON (l.source, l.source_id) = (k.source, k.source_id)
            WHERE s.image IS NOT NULL""",
        [[l.source for l in listings], [l.id for l in listings]],
    )).fetchall()
    return {(r["source"], r["source_id"]): r["image"] for r in rows}


# ---------- your own songs first in a search (#26) ----------

# At most this many of the user's songs go first: one short word ("love") can match hundreds in a large library, and
# the sources' results stay within reach below them
LIBRARY_SONGS = 20


async def matching_songs(conn: AsyncConnection, user_id: UUID, query: str, found: list[Song]) -> list[Song]:
    """The songs of the user's library that match what was typed: liked, or in a playlist of theirs or one shared with
    them, with a copy holding every typed word as found() takes it (typos allowed: matching.coverage's rule). Those the
    sources also `found` come first, in their order, then the most recently liked or added; LIBRARY_SONGS at most.

    One query through indexes, then the songs' copies. For each typed word, `vocabulary` gives the words found() would take, and the GIN
    index on listings.words the copies holding one of them; the user's likes and playlist items, each read through its
    own index, say which are theirs. Comparing every song of the library with what was typed instead (in the database,
    the typo rule there too) cost 15–20 ms for 2,000 songs, 40–80 ms for 5,000 and 150 ms for 10,000. This adds 6–15 ms
    to a search for 2,000 to 10,000 songs, about 3 ms of it finding each typed word's alike words among 23,000; 15–30 ms
    for one common word 20 of yours have ("love"). Measured with 500,000 stored copies on a Windows PC (18 Oct, #26).
    """
    words = list(dict.fromkeys(normalise(query).split()))
    if not words:
        return []
    alike = {f"w{i}": vocabulary.alike(word) for i, word in enumerate(words)}
    keys = [(listing.source, listing.id) for song in found for listing in song.listings]
    rows = await (await conn.execute(
        f"""WITH found AS (SELECT l.song_id, min(k.place) AS place
                             FROM unnest(%(sources)s::text[], %(ids)s::text[]) WITH ORDINALITY AS k(source, source_id, place)
                             JOIN listings l ON (l.source, l.source_id) = (k.source, k.source_id)
                            GROUP BY l.song_id)
            SELECT m.song_id AS id, max(m.at) AS at, bool_or(m.liked) AS liked
              FROM (SELECT song_id, liked_at AS at, true AS liked FROM likes WHERE user_id = %(user)s
                    UNION ALL
                    SELECT i.song_id, i.added_at, false FROM playlists p JOIN playlist_items i ON i.playlist_id = p.id
                     WHERE p.user_id = %(user)s
                    UNION ALL
                    SELECT i.song_id, i.added_at, false FROM playlist_members s JOIN playlist_items i ON i.playlist_id = s.playlist_id
                     WHERE s.user_id = %(user)s) m
              LEFT JOIN found f ON f.song_id = m.song_id
             WHERE m.song_id IN (SELECT song_id FROM listings WHERE {" AND ".join(f"words && %({k})s::text[]" for k in alike)})
             GROUP BY m.song_id
             ORDER BY min(f.place) NULLS LAST, max(m.at) DESC
             LIMIT %(limit)s""",
        {"user": user_id, "sources": [k[0] for k in keys], "ids": [k[1] for k in keys], "limit": LIBRARY_SONGS, **alike},
    )).fetchall()
    return [Song(title = s.title, artists = s.artists, duration = s.duration, best = s.best, listings = s.listings,
                 image = s.image, score = 0) for s in await _with_listings(conn, rows)]


async def load_words(conn: AsyncConnection) -> int:
    """At start: give the copies stored before #26 their words (listings.words), then read every stored word into
    `vocabulary`. Returns how many copies were given words (all of them the first time, then none)."""
    rows = await (await conn.execute(
        "SELECT source, source_id, title, artists FROM listings WHERE words IS NULL")).fetchall()
    if rows:
        # one COPY and one UPDATE, once: 150 s for 500,000 copies (18 Oct), most of it keeping the words index up to date
        async with conn.transaction():
            await conn.execute("SET LOCAL statement_timeout = 0")    # once, at start: may outlast a request's 10 s
            await conn.execute("CREATE TEMP TABLE new_words (source text, source_id text, words text[]) ON COMMIT DROP")
            async with conn.cursor().copy("COPY new_words FROM STDIN") as copy:
                for r in rows:
                    await copy.write_row((r["source"], r["source_id"], stored_words(r["title"], r["artists"])))
            await conn.execute("""UPDATE listings l SET words = n.words FROM new_words n
                                   WHERE (l.source, l.source_id) = (n.source, n.source_id)""")
            await conn.execute("ANALYZE listings")       # the first searches are planned knowing the words
    vocabulary.add([r["word"] for r in await (await conn.execute(
        "SELECT DISTINCT unnest(words) AS word FROM listings")).fetchall()])
    return len(rows)

# ---------- playlists: who may do what ----------
# Every playlist action starts with one question: what is this user's role on this playlist? The owner is
# playlists.user_id; anyone else's access is a playlist_members row; a public playlist lets everyone view. One query
# answers it (by primary keys only), in one place: no route or query decides access on its own.

Role = Literal["owner", "editor", "viewer"]
_RANK: dict[str, int] = {"viewer": 1, "editor": 2, "owner": 3}

class NoSuchPlaylist(Exception):
    """The playlist with this id cannot be seen: it never existed, was deleted, or belongs to someone else and is
    private. Raised as the endpoint's 404: a private playlist's existence is not revealed to a person who may not
    see it."""

class NotAllowed(Exception):
    """The playlist is visible, but the role does not allow this action (a viewer adding a song): the endpoint's
    403."""

class NoSuchUser(Exception):
    """No account has this username (an invitation targets it): the endpoint's 404."""

class IsAlbum(Exception):
    """A pinned album is a read-only copy of a source's album: rename, public, share, and editing its songs do not
    apply (the endpoint's 400). Deleting it unpins it."""

# the role expression, shared by every query that needs it: owner, else the user's membership, else viewer if public
_ROLE_SQL = """CASE WHEN pl.user_id = %(user)s THEN 'owner'
                    ELSE coalesce(m.role, CASE WHEN pl.public THEN 'viewer' END) END"""

async def _require(conn: AsyncConnection, user_id: UUID, playlist_id: UUID, need: Role, lock: bool = False) -> Role:
    """The user's role on the playlist, if it is at least `need`; else NoSuchPlaylist (the playlist cannot be seen)
    or NotAllowed. lock=True also takes the playlist's turn: every write that picks or changes a position in it holds
    the playlist's row lock until its transaction commits, so two writers never read the same positions."""
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
    """The user's own users row, locked until the commit (create, reorder): the list's turn. A second create or move
    in the same user's list waits; other users' lists never do."""
    await conn.execute("SELECT 1 FROM users WHERE id = %s FOR UPDATE", [user_id])

async def _reject_album(conn: AsyncConnection, playlist_id: UUID) -> None:
    """Raise IsAlbum when this playlist is a pinned album. Called AFTER _require, so it never reveals an album the
    caller cannot see: an invisible album is still 404, someone else's is still 403, and only the owner of an album
    reaches here (400)."""
    row = await (await conn.execute("SELECT kind FROM playlists WHERE id = %s", [playlist_id])).fetchone()
    if row is not None and row["kind"] == "album":
        raise IsAlbum(playlist_id)

# one playlist with its totals and the user's role; the same columns for one playlist and for the list
_SUMMARY_SQL = f"""SELECT pl.id, pl.name, pl.public, pl.kind, pl.source, pl.source_id, {_ROLE_SQL} AS role,
                          count(i.id) AS song_count, coalesce(sum(s.duration), 0) AS duration
                     FROM playlists pl
                     LEFT JOIN playlist_members m ON m.playlist_id = pl.id AND m.user_id = %(user)s
                     LEFT JOIN playlist_items i ON i.playlist_id = pl.id
                     LEFT JOIN songs s ON s.id = i.song_id"""


async def create_playlist(conn: AsyncConnection, user_id: UUID, name : str) -> UUID:
    """A new playlist of the user's, private, at the bottom of their list. A name they already use raises
    UniqueViolation."""
    await _lock_playlist_list(conn, user_id)
    # the bottom = after the largest position so far (None when there are no playlists: then the first key, "a0")
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlists WHERE user_id = %s",
                                      [user_id])).fetchone())["last"]
    row = await (await conn.execute(
        "INSERT INTO playlists (user_id, name, position) VALUES (%s, %s, %s) RETURNING id",
        [user_id, name, generate_key_between(last, None)],
    )).fetchone()
    return row["id"]

async def pin_album(conn: AsyncConnection, user_id: UUID, source: str, source_id: str,
                    album_title: str, songs: list[Song]) -> UUID:
    """Copy a source's album into the user's list: a row of kind 'album' at the bottom, then its tracks as items in
    order. The copy is a snapshot; the source's later edits do not follow. Each track resolves through resolve_song,
    so a recording already stored stays itself (and gains a listing) instead of becoming a duplicate row.

    One pin per album per person: the partial unique index (user_id, source, source_id) where kind='album' raises
    UniqueViolation, which the endpoint answers 409. The caller holds no lock yet: _lock_playlist_list here takes the
    user's list's turn, so two pins by the same user never pick the same position."""
    await _lock_playlist_list(conn, user_id)
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlists WHERE user_id = %s",
                                      [user_id])).fetchone())["last"]
    playlist_id = (await (await conn.execute(
        """INSERT INTO playlists (user_id, name, position, kind, source, source_id)
           VALUES (%s, %s, %s, 'album', %s, %s) RETURNING id""",
        [user_id, album_title, generate_key_between(last, None), source, source_id],
    )).fetchone())["id"]
    # evenly spaced keys up front, one per track: the album's own order, and room between any two to reorder
    # (reordering is rejected while pinned, but the keys are already correct if that changes)
    keys = generate_n_keys_between(None, None, len(songs))
    for key, song in zip(keys, songs):
        song_id = await resolve_song(conn, song.listings)
        await conn.execute(
            "INSERT INTO playlist_items (playlist_id, song_id, position, added_by) VALUES (%s, %s, %s, %s)",
            [playlist_id, song_id, key, user_id],
        )
    return playlist_id

async def get_playlists(conn: AsyncConnection, user_id: UUID) -> list[PlaylistMetadata]:
    """The user's playlists in their order, then those shared with them, with totals and their role: one query. Each
    half of the union is read through its own index (playlists by owner, members by user). Public playlists of others
    are not listed: they open by id (a link)."""
    rows = await (await conn.execute(
        f"""WITH mine AS (SELECT id, false AS shared FROM playlists WHERE user_id = %(user)s
                          UNION ALL
                          SELECT playlist_id, true FROM playlist_members WHERE user_id = %(user)s)
            {_SUMMARY_SQL}
              JOIN mine ON mine.id = pl.id
             GROUP BY pl.id, m.role, mine.shared
             ORDER BY mine.shared, pl.position, pl.id""",    # pl.id: two at one position keep their order
        {"user": user_id})).fetchall()
    return [PlaylistMetadata(**row) for row in rows]

async def get_playlist_metadata(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> PlaylistMetadata:
    """One playlist the user can see, with its totals and their role: one query. NoSuchPlaylist otherwise."""
    row = await (await conn.execute(
        f"""{_SUMMARY_SQL}
             WHERE pl.id = %(playlist)s
             GROUP BY pl.id, m.role""",
        {"user": user_id, "playlist": playlist_id})).fetchone()
    if row is None or row["role"] is None:
        raise NoSuchPlaylist(playlist_id)
    return PlaylistMetadata(**row)

async def get_playlist_items(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> list[PlaylistItem]:
    """The playlist's songs in order, each shown through its best listing; `liked` is the user's own like. Checks
    that the playlist is visible (NoSuchPlaylist), so this is safe on its own; the open route calls
    get_playlist_metadata first anyway."""
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
    """Add at the bottom; editors and the owner. Records who added it."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    await _reject_album(conn, playlist_id)
    # this playlist's last position: the (playlist_id, position) index answers it without reading other playlists
    last = (await (await conn.execute("SELECT max(position) AS last FROM playlist_items WHERE playlist_id = %s",
                                      [playlist_id])).fetchone())["last"]
    return (await (await conn.execute(
        "INSERT INTO playlist_items (playlist_id, song_id, position, added_by) VALUES (%s, %s, %s, %s) RETURNING id",
        [playlist_id, song_id, generate_key_between(last, None), user_id])).fetchone())["id"]

async def remove_from_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, item_id : UUID) -> bool:
    """Remove one item; editors and the owner. False when the playlist has no such item (an item of another playlist
    is not one)."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    await _reject_album(conn, playlist_id)
    return (await conn.execute("DELETE FROM playlist_items WHERE id = %s AND playlist_id = %s",
                               [item_id, playlist_id])).rowcount > 0

async def rename_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, name : str) -> None:
    """Rename it; the owner only. A name the user already uses raises UniqueViolation."""
    await _require(conn, user_id, playlist_id, "owner")
    await _reject_album(conn, playlist_id)
    await conn.execute("UPDATE playlists SET name = %s WHERE id = %s", [name, playlist_id])

async def set_public(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, public: bool) -> None:
    """The owner only: public = any signed-in user can view it by its id."""
    await _require(conn, user_id, playlist_id, "owner")
    await _reject_album(conn, playlist_id)
    await conn.execute("UPDATE playlists SET public = %s WHERE id = %s", [public, playlist_id])

async def delete_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> None:
    """The owner only. Its items and memberships go with it (ON DELETE CASCADE); the songs stay."""
    await _require(conn, user_id, playlist_id, "owner")
    await conn.execute("DELETE FROM playlists WHERE id = %s", [playlist_id])

async def share_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, username: str, role: str) -> Notification | None:
    """The owner invites someone by username, or changes their role ("viewer" or "editor"). NoSuchUser when no such
    account exists; inviting themselves does nothing (they own it). A NEW membership creates the invitee's
    playlist_invite notification in the same transaction, returned for the WebSocket push; a role change is not a new
    invite, so the result is None."""
    await _require(conn, user_id, playlist_id, "owner")
    await _reject_album(conn, playlist_id)
    row = await (await conn.execute("SELECT id FROM users WHERE lower(username) = lower(%s)", [username])).fetchone()
    if row is None:
        raise NoSuchUser(username)
    if row["id"] == user_id:
        return None
    inserted = (await (await conn.execute(
        """INSERT INTO playlist_members (playlist_id, user_id, role) VALUES (%s, %s, %s)
           ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role
           RETURNING (xmax = 0) AS inserted""",
        [playlist_id, row["id"], role])).fetchone())["inserted"]
    if not inserted:
        return None
    info = await (await conn.execute(
        """SELECT pl.name AS playlist_name, u.username AS owner_username
             FROM playlists pl JOIN users u ON u.id = pl.user_id
            WHERE pl.id = %s""",
        [playlist_id])).fetchone()
    return await notifications.create(conn, row["id"], "playlist_invite", {
        "playlist_id": str(playlist_id),
        "playlist_name": info["playlist_name"],
        "from_user_id": str(user_id),
        "from_username": info["owner_username"],
    })

async def playlist_members(conn: AsyncConnection, user_id: UUID, playlist_id : UUID) -> list[Member]:
    """Who is on the playlist: its owner first, then the people it is shared with, oldest invite first. Open to the
    owner and the members; someone who sees it only because it is public gets NotAllowed (who it is shared with is
    not theirs to know). One query for everyone, after the access check."""
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
    """Remove a member: the owner removes anyone, and a member may remove themselves (leave). False when they were
    not a member."""
    role = await _require(conn, user_id, playlist_id, "viewer")
    if role != "owner" and member_id != user_id:
        raise NotAllowed("only the owner removes other people")
    return (await conn.execute("DELETE FROM playlist_members WHERE playlist_id = %s AND user_id = %s",
                               [playlist_id, member_id])).rowcount > 0


# ---------- taking turns ----------
# Every write that picks a position (add, move) reads the positions around it, then writes a key between them. Two
# writes at the same moment read the same positions and write the same key: a tie, and nothing can go between a tie
# (moving a song there answered 422, permanently). So they take turns, in the database: row locks (SELECT ... FOR
# UPDATE) on the playlist's row, or on the user's users row for their own list, held until the transaction commits.
# The locks hold across server processes and scripts (a lock in Python holds in one process only); whoever comes
# next reads what the one before left.

class NotInList(Exception):
    """The row to move, or one of its new neighbours, is not in that list (the endpoint's 404)."""

class BadMove(ValueError):
    """Neighbours in the wrong order, or a row named as its own neighbour (the endpoint's 422)."""

async def move_item(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, item_id : UUID,
                    top_id : UUID | None, bottom_id : UUID | None) -> None:
    """Moves one song of a playlist to between two of its songs; editors and the owner. One row changes (the whole
    playlist only when it held a tie: see `_move`)."""
    await _require(conn, user_id, playlist_id, "editor", lock=True)
    await _reject_album(conn, playlist_id)
    await _move(conn, "playlist_items", "playlist_id = %s", [playlist_id], item_id, top_id, bottom_id)

async def move_playlist(conn: AsyncConnection, user_id: UUID, playlist_id : UUID, top_id : UUID | None,
                        bottom_id : UUID | None) -> None:
    """Moves one of the user's own playlists to between two others in their list. One row changes (all of them only
    after a tie). Only their own: a shared playlist keeps its owner's order, and as a neighbour it is NotInList."""
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
        return                                     # no neighbours to put it between: it stays where it is
    top, bottom = positions.get(top_id), positions.get(bottom_id)    # None: the top or the bottom of the list
    if top is not None and top == bottom:
        # tied neighbours (two adds at once, before the turns): nothing sorts between two equal keys, so the move
        # answered 422 permanently. The whole list gets fresh keys once, in the order it shows; never tied again
        fresh = await _rekey(conn, table, where, args)
        top, bottom = fresh[top_id], fresh[bottom_id]
    try:
        new = generate_key_between(top, bottom)    # sorts between the two neighbours
    except FIError as e:
        raise BadMove("the top neighbour must come before the bottom one") from e
    # the same two neighbours always give the same key: a row moved into this slot since the app last looked (from
    # another window or device) already has it, and the two would tie. Step past it, still before the bottom one
    while await _taken(conn, table, where, args, new, row_id):
        new = generate_key_between(new, bottom)
    await conn.execute(f"UPDATE {table} SET position = %s WHERE id = %s", [new, row_id])

async def _rekey(conn: AsyncConnection, table: str, where: str, args: list) -> dict[UUID, str]:
    """Give every row of the list a fresh key, evenly spaced, in the order it shows (position, then id)."""
    ids = [r["id"] for r in await (await conn.execute(
        f"SELECT id FROM {table} WHERE {where} ORDER BY position, id", args)).fetchall()]
    keys = generate_n_keys_between(None, None, len(ids))
    async with conn.cursor() as cur:
        await cur.executemany(f"UPDATE {table} SET position = %s WHERE id = %s", list(zip(keys, ids)))
    return dict(zip(ids, keys))

async def _taken(conn: AsyncConnection, table: str, where: str, args: list, position: str, row_id: UUID) -> bool:
    """Return whether another row of the list already has this key."""
    found = await (await conn.execute(f"SELECT 1 FROM {table} WHERE {where} AND position = %s AND id <> %s LIMIT 1",
                                      [*args, position, row_id])).fetchone()
    return found is not None
