"""MUS-12 step 3: the lyrics cache (LyricsCache), on the music_test database. The sources are fakes that count
how often they are asked; every word is made up."""
import asyncio
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend import db, lyrics
from music_backend.cache import LyricsCache
from music_backend.lyrics import LyricsNotFound
from music_backend.models import LyricLine, LyricsRequest, LyricsResponse
from music_backend.settings import settings

TEST_URL = "postgresql:///music_test"


@pytest.fixture
async def pool():
    pool = db.make_pool(TEST_URL)
    await pool.open()
    await db.apply_schema(pool)
    yield pool
    async with pool.connection() as conn:
        await conn.execute("DELETE FROM lyrics WHERE song_name LIKE 'cache-test-%'")
    await pool.close()


def song(youtube_id="vid"):
    return LyricsRequest(song_name=f"cache-test-{uuid4().hex[:8]}", artist_name="Artist", song_duration=200, youtube_id=youtube_id)


def reply(source, synced, n=2):
    lines = [LyricLine(start_ms=1000 * i if synced else None, text=f"words {i}") for i in range(n)]
    return LyricsResponse(lyrics_source=source, synced=synced, lines=lines)


class Source:
    """A fake lyrics source: answers `result` (a reply, or an exception to raise) and counts the calls."""

    def __init__(self, result, delay=0.0):
        self.result, self.delay, self.calls = result, delay, 0

    async def __call__(self, request):
        self.calls += 1
        await asyncio.sleep(self.delay)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


@pytest.fixture
def sources(monkeypatch):
    """Two fake sources in LYRICS_SOURCES: set .result on each."""
    a, b = Source(LyricsNotFound("none")), Source(LyricsNotFound("none"))
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": a, "ytmusic": b})
    return a, b


async def age(pool, request, days):
    """Pretend the stored reply was fetched `days` ago."""
    async with pool.connection() as conn:
        await conn.execute("UPDATE lyrics SET fetched_at = now() - %s * interval '1 day' WHERE song_name = %s",
                           [days, request.song_name])


@pytest.mark.anyio
async def test_the_second_request_asks_no_source(pool, sources):
    a, b = sources
    a.result = reply("lrclib", synced=True)
    cache, request = LyricsCache(pool), song()
    first = await cache(request)
    second = await cache(request)
    assert first == second == reply("lrclib", synced=True)       # the same reply, back from the table exactly
    assert a.calls == 1


@pytest.mark.anyio
async def test_timed_lyrics_are_kept_for_good(pool, sources):
    a, _ = sources
    a.result = reply("lrclib", synced=True)
    cache, request = LyricsCache(pool), song()
    await cache(request)
    await age(pool, request, 400)
    await cache(request)
    assert a.calls == 1


@pytest.mark.anyio
async def test_plain_lyrics_are_asked_for_again_after_the_recheck_days(pool, sources):
    a, b = sources
    a.result = reply("lrclib", synced=False)
    cache, request = LyricsCache(pool), song()
    await cache(request)
    await age(pool, request, settings.lyrics_recheck_days - 1)
    await cache(request)
    assert (a.calls, b.calls) == (1, 1)                          # still fresh: from the table
    await age(pool, request, settings.lyrics_recheck_days + 1)
    b.result = reply("ytmusic", synced=True)                     # meanwhile YouTube got timed lyrics
    assert (await cache(request)).lyrics_source == "ytmusic"
    assert (a.calls, b.calls) == (2, 2)


@pytest.mark.anyio
async def test_nothing_anywhere_is_kept_too_and_asked_again_later(pool, sources):
    a, b = sources
    cache, request = LyricsCache(pool), song()
    assert (await cache(request)).lines == []
    await cache(request)
    assert (a.calls, b.calls) == (1, 1)
    await age(pool, request, settings.lyrics_recheck_days + 1)
    await cache(request)
    assert (a.calls, b.calls) == (2, 2)


@pytest.mark.anyio
async def test_when_a_source_failed_plain_lyrics_are_not_kept(pool, sources):
    a, b = sources
    a.result = reply("lrclib", synced=False)
    b.result = RuntimeError("YouTube changed its page")          # it might have had timed lyrics
    cache, request = LyricsCache(pool), song()
    assert (await cache(request)).lyrics_source == "lrclib"
    await cache(request)
    assert (a.calls, b.calls) == (2, 2)                          # asked again: nothing was stored


@pytest.mark.anyio
async def test_when_a_source_failed_timed_lyrics_are_still_kept(pool, sources):
    a, b = sources
    a.result = RuntimeError("LRCLIB broke")
    b.result = reply("ytmusic", synced=True)
    cache, request = LyricsCache(pool), song()
    await cache(request)
    await cache(request)
    assert b.calls == 1                                          # timed is the best there is


@pytest.mark.anyio
async def test_with_and_without_a_youtube_copy_are_two_entries(pool, sources):
    a, _ = sources
    a.result = reply("lrclib", synced=True)
    cache, with_copy = LyricsCache(pool), song("vid")
    without = with_copy.model_copy(update={"youtube_id": None})
    await cache(with_copy)
    await cache(without)
    assert a.calls == 2


@pytest.mark.anyio
async def test_two_requests_at_once_share_one_lookup(pool, sources):
    a, _ = sources
    a.result, a.delay = reply("lrclib", synced=True), 0.2
    cache, request = LyricsCache(pool), song()
    first, second = await asyncio.gather(cache(request), cache(request))
    assert first == second and a.calls == 1
    assert cache.running == {}                                   # done lookups leave nothing behind


@pytest.mark.anyio
async def test_a_request_that_gives_up_does_not_cancel_the_shared_lookup(pool, sources):
    a, _ = sources
    a.result, a.delay = reply("lrclib", synced=True), 0.3
    cache, request = LyricsCache(pool), song()
    leaving = asyncio.create_task(cache(request))
    staying = asyncio.create_task(cache(request))
    await asyncio.sleep(0.05)
    leaving.cancel()                                             # the app closed Lyrics
    assert (await staying).synced
    await cache(request)
    assert a.calls == 1                                          # finished and stored despite the cancel


# ---------- through the server ----------

def test_post_lyrics_twice_asks_the_sources_once(monkeypatch):
    a = Source(reply("lrclib", synced=True))
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": a})
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    body = {"song_name": f"cache-test-{uuid4().hex[:8]}", "artist_name": "Artist", "song_duration": 200}
    with TestClient(app) as client:
        first = client.post("/lyrics", json=body)
        second = client.post("/lyrics", json=body)
        assert first.status_code == second.status_code == 200
        assert first.json() == second.json()
        assert a.calls == 1
        with_lookup_running = app.state.lyrics_cache                 # for the shutdown check below
    assert with_lookup_running.running == {}
    import psycopg
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("DELETE FROM lyrics WHERE song_name = %s", [body["song_name"]])


def test_shutdown_stops_a_lyrics_lookup_still_running(monkeypatch):
    slow = Source(reply("lrclib", synced=True), delay=30)
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": slow})
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        cache = app.state.lyrics_cache
        client.portal.start_task_soon(cache, song())                 # a lookup that would take 30 s
        for _ in range(50):
            if cache.running:
                break
            client.portal.call(asyncio.sleep, 0.01)
        running = list(cache.running.values())
        assert len(running) == 1
    assert all(task.done() for task in running)                    # cancelled at shutdown, not left behind
