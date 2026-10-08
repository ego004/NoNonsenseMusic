"""MUS-1 step 3: prefetch. Fake sources (nothing real is contacted), the music_test database."""
import asyncio
import time
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.services.cache import ListingURLCache
from music_backend.core.settings import settings
from music_backend.sources import SongNotFound, ytmusic

TEST_URL = "postgresql:///music_test"
HOUR = 3600


def new_id():
    return "pre-" + uuid4().hex[:10]


class SlowSource:
    """A source whose lookup takes `delay` seconds. Records every call and the most lookups it ever saw at once."""

    def __init__(self, delay=0.2, failing=()):
        self.delay, self.failing = delay, set(failing)
        self.calls, self.active, self.most_at_once = [], 0, 0

    async def get_song_url(self, song_id):
        self.calls.append(song_id)
        self.active += 1
        self.most_at_once = max(self.most_at_once, self.active)
        try:
            await asyncio.sleep(self.delay)
            if song_id in self.failing:
                raise SongNotFound(song_id)
            return f"https://audio.example/videoplayback?id={song_id}&expire={int(time.time()) + 6 * HOUR}"
        finally:
            self.active -= 1

    def is_expired(self, url):
        return False


class Listing:
    def __init__(self, source_id, source="ytmusic"):
        self.source, self.source_id = source, source_id


# ---------- through the server ----------

@pytest.fixture
def server(monkeypatch):
    source = SlowSource()
    monkeypatch.setattr(ytmusic, "get_song_url", source.get_song_url)
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client, source, app


def prefetch(client, ids, source="ytmusic"):
    return client.post("/prefetch", json={"listings": [{"source": source, "source_id": i} for i in ids]})


def test_a_prefetched_song_plays_from_the_cache(server):
    # the ticket's "done when": the list arrives, the server looks it up in the background, the click is a cache hit
    client, source, _ = server
    songs = [new_id() for _ in range(3)]
    start = time.perf_counter()
    assert prefetch(client, songs).status_code == 202
    assert time.perf_counter() - start < 0.15                  # answered at once, not after the lookups
    time.sleep(0.5)                                            # 4 workers: all 3 looked up in ~0.2 s
    assert sorted(source.calls) == sorted(songs)
    played = client.get(f"/play/ytmusic/{songs[0]}", follow_redirects=False)
    assert played.status_code == 307
    assert len(source.calls) == 3                              # the play asked the source nothing


@pytest.mark.parametrize("listings", [
    [],                                                         # nothing to prefetch
    [{"source": "napster", "source_id": "x"}],                 # not a source we have
    [{"source": "ytmusic", "source_id": f"s{n}"} for n in range(51)],   # more than 50
])
def test_bad_lists_answer_422(server, listings):
    client, source, _ = server
    assert client.post("/prefetch", json={"listings": listings}).status_code == 422
    assert source.calls == []


def test_the_server_starts_separate_workers_and_stops_them(server):
    client, _, app = server
    workers = app.state.prefetch_workers
    assert len(set(map(id, workers))) == settings.num_prefetch_workers   # N different tasks, not one listed N times
    assert all(not w.done() for w in workers)


def test_shutdown_stops_the_workers(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app):
        workers = list(app.state.prefetch_workers)
    assert all(w.done() for w in workers)


# ---------- the cache and its workers, directly ----------

async def with_workers(cache, n, body):
    workers = [asyncio.create_task(cache.prefetch_worker()) for _ in range(n)]
    try:
        await body()
    finally:
        for w in workers:
            w.cancel()
        await asyncio.gather(*workers, return_exceptions=True)


@pytest.mark.anyio
async def test_a_new_list_replaces_what_is_still_waiting(pool):
    source = SlowSource()
    cache = ListingURLCache({"ytmusic": source}, pool)
    a, b, c, d, x, y = (new_id() for _ in range(6))

    async def body():
        cache.prefetch([Listing(i) for i in (a, b, c, d)])    # 1 worker: a starts, b c d wait
        await asyncio.sleep(0.05)
        cache.prefetch([Listing(i) for i in (x, y)])          # the queue moved on: b c d are no longer coming
        await asyncio.sleep(0.7)

    await with_workers(cache, 1, body)
    assert source.calls == [a, x, y]                          # a (already running) finished; b c d never asked


@pytest.mark.anyio
async def test_cached_and_running_listings_are_skipped(pool):
    source = SlowSource()
    cache = ListingURLCache({"ytmusic": source}, pool)
    cached, running, new = new_id(), new_id(), new_id()
    await cache("ytmusic", cached)                            # played before: cached
    playing = asyncio.create_task(cache("ytmusic", running))  # being looked up right now (a click)
    await asyncio.sleep(0.05)

    async def body():
        cache.prefetch([Listing(i) for i in (cached, running, new)])
        await asyncio.sleep(0.4)

    await with_workers(cache, 1, body)
    await playing
    assert sorted(source.calls) == sorted([cached, running, new])   # each asked exactly once


@pytest.mark.anyio
async def test_prefetching_a_cached_listing_does_not_mark_it_used(pool):
    # STRIP: the worker checked "cached?" with get(), which marks the row used, so the table's "least recently used"
    # meant "least recently prefetched". A prefetch is not a play: the row keeps its old hit_at
    source = SlowSource()
    cache = ListingURLCache({"ytmusic": source}, pool)
    song = new_id()
    await cache("ytmusic", song)                              # played: cached in memory and in the table
    async with pool.connection() as conn:                     # pretend it was last played a day ago
        await conn.execute("UPDATE listing_urls SET hit_at = now() - interval '1 day' WHERE source_id = %s", [song])

    async def body():
        cache.prefetch([Listing(song)])
        await asyncio.sleep(0.2)

    await with_workers(cache, 1, body)
    async with pool.connection() as conn:
        row = await (await conn.execute("SELECT hit_at < now() - interval '1 hour' AS old FROM listing_urls WHERE source_id = %s",
                                        [song])).fetchone()
    assert source.calls == [song]                             # the prefetch asked nobody: it was cached
    assert row["old"]                                         # and it did not count as a use


@pytest.mark.anyio
async def test_a_failing_lookup_does_not_stop_a_worker(pool):
    gone, good = new_id(), new_id()
    source = SlowSource(failing={gone})
    cache = ListingURLCache({"ytmusic": source}, pool)

    async def body():
        cache.prefetch([Listing(gone), Listing(good)])
        await asyncio.sleep(0.6)

    await with_workers(cache, 1, body)
    assert source.calls == [gone, good]                       # the one worker carried on after the failure
    assert await cache.get("ytmusic", good) is not None


@pytest.mark.anyio
async def test_at_most_n_lookups_at_once(pool):
    source = SlowSource(delay=0.1)
    cache = ListingURLCache({"ytmusic": source}, pool)

    async def body():
        cache.prefetch([Listing(new_id()) for _ in range(8)])
        await asyncio.sleep(0.6)

    await with_workers(cache, 2, body)
    assert len(source.calls) == 8
    assert source.most_at_once == 2
