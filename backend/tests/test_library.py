"""Library tests against the music_test database (wiped before every test; the real `music` is never touched)."""
import pytest
from fastapi.testclient import TestClient

from music_backend import db, library
from music_backend.models import Listing

TEST_URL = "postgresql:///music_test"


def listing(source, id, title="Blinding Lights", artists=("The Weeknd",), duration=200):
    return Listing(source=source, id=id, title=title, artists=list(artists), album=None, duration=duration, popularity=None)


@pytest.fixture
async def pool():
    pool = db.make_pool(TEST_URL)
    await pool.open()
    async with pool.connection() as conn:
        await conn.execute("DROP TABLE IF EXISTS playlist_items, playlists, events, likes, listings, songs CASCADE")
    await db.apply_schema(pool)
    yield pool
    await pool.close()


async def count(pool, table):
    async with pool.connection() as conn:
        return (await (await conn.execute(f"SELECT count(*) AS n FROM {table}")).fetchone())["n"]


@pytest.mark.anyio
async def test_like_survives_a_restart(pool):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "fW-Mxsnu"), listing("ytmusic", "J7p4bzqLvCw", duration=202)])
        await library.like(conn, song_id)
    await pool.close()                                  # "restart": a brand-new pool
    fresh = db.make_pool(TEST_URL)
    await fresh.open()
    async with fresh.connection() as conn:
        songs = await library.liked_songs(conn)
    await fresh.close()
    assert [s.id for s in songs] == [song_id]
    assert {l.source for l in songs[0].listings} == {"jiosaavn", "ytmusic"}


@pytest.mark.anyio
async def test_same_song_from_a_later_search_is_not_duplicated(pool):
    async with pool.connection() as conn:
        first = await library.resolve_song(conn, [listing("jiosaavn", "A"), listing("ytmusic", "Y", duration=202)])
        # next week: different order, plus a release the server has never seen
        second = await library.resolve_song(conn, [listing("jiosaavn", "NEW", duration=204), listing("jiosaavn", "A")])
    assert first == second
    assert await count(pool, "songs") == 1
    assert await count(pool, "listings") == 3           # the new release got linked


@pytest.mark.anyio
async def test_unseen_listing_found_through_the_title_index(pool):
    async with pool.connection() as conn:
        first = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        second = await library.resolve_song(conn, [listing("ytmusic", "Y", duration=202)])   # no shared listing
    assert first == second


@pytest.mark.anyio
async def test_centre_does_not_drift_across_searches(pool):
    async with pool.connection() as conn:
        s1 = await library.resolve_song(conn, [listing("jiosaavn", "A", duration=200)])
        # a later group {204, 208}: 204 is linked via the title index, 208 is 8 s from the frozen 200
        await library.resolve_song(conn, [listing("jiosaavn", "B", duration=204), listing("jiosaavn", "C", duration=208)])
        linked = await (await conn.execute("SELECT source_id FROM listings WHERE song_id = %s ORDER BY source_id", [s1])).fetchall()
    assert [r["source_id"] for r in linked] == ["A", "B"]


@pytest.mark.anyio
async def test_cover_becomes_its_own_song(pool):
    async with pool.connection() as conn:
        weeknd = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        loi = await library.resolve_song(conn, [listing("ytmusic", "L", artists=("Loi",), duration=148)])
    assert weeknd != loi


@pytest.mark.anyio
async def test_liking_twice_is_one_like(pool):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.like(conn, song_id)
        await library.like(conn, song_id)
    assert await count(pool, "likes") == 1


@pytest.mark.anyio
async def test_unlike(pool):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.like(conn, song_id)
        assert await library.unlike(conn, song_id) is True
        assert await library.unlike(conn, song_id) is False
        assert await library.liked_songs(conn) == []


@pytest.mark.anyio
async def test_events_are_stored_and_countable(pool):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.record_event(conn, song_id, "play", 0)
        await library.record_event(conn, song_id, "skip", 12)
        await library.record_event(conn, song_id, "play", 0)
        await library.record_event(conn, song_id, "finish", 200)
        rows = await (await conn.execute(
            "SELECT type, count(*) AS n FROM events WHERE song_id = %s GROUP BY type ORDER BY type", [song_id])).fetchall()
        recent = await library.recent_songs(conn)
    assert {r["type"]: r["n"] for r in rows} == {"finish": 1, "play": 2, "skip": 1}
    assert [s.id for s in recent] == [song_id] and recent[0].liked is False


def test_endpoints_end_to_end(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    body = {"listings": [listing("jiosaavn", "E2E").model_dump()]}
    with TestClient(app) as client:                     # "with" runs startup and shutdown (the lifespan)
        song_id = client.post("/liked", json=body).json()["song_id"]
        assert client.post("/events", json=body | {"type": "play", "position": 0}).json()["song_id"] == song_id
        assert song_id in [s["id"] for s in client.get("/liked").json()]
        assert song_id in [s["id"] for s in client.get("/recent").json()]
        assert client.delete(f"/liked/{song_id}").status_code == 204
        assert client.delete(f"/liked/{song_id}").status_code == 404
        assert client.post("/events", json=body | {"type": "jump", "position": 0}).status_code == 422


# ---------- MUS-19: explicit and clean versions ----------

async def stored_flags(pool):
    async with pool.connection() as conn:
        rows = await (await conn.execute("SELECT source_id, explicit FROM listings ORDER BY source_id")).fetchall()
    return {r["source_id"]: r["explicit"] for r in rows}


@pytest.mark.anyio
async def test_the_explicit_flag_is_stored_and_read_back(pool):
    loud = listing("jiosaavn", "E1").model_copy(update={"explicit": True})
    clean = listing("ytmusic", "C1", duration=201).model_copy(update={"explicit": False})
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [loud, clean])
        await library.like(conn, song_id)
        liked = await library.liked_songs(conn)
    assert await stored_flags(pool) == {"C1": False, "E1": True}
    assert {l.id: l.explicit for l in liked[0].listings} == {"C1": False, "E1": True}


@pytest.mark.anyio
async def test_an_unknown_flag_is_filled_in_and_a_known_one_is_kept(pool):
    unknown = listing("jiosaavn", "U1")                                   # stored before flags existed: None
    known = listing("ytmusic", "K1", duration=201).model_copy(update={"explicit": True})
    async with pool.connection() as conn:
        await library.resolve_song(conn, [unknown, known])
        assert await stored_flags(pool) == {"K1": True, "U1": None}
        # seen again, now with flags; the known one arrives (wrongly) as clean: it must not be overwritten
        await library.resolve_song(conn, [unknown.model_copy(update={"explicit": True}), known.model_copy(update={"explicit": False})])
    assert await stored_flags(pool) == {"K1": True, "U1": True}
