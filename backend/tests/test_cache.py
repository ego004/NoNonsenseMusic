"""MUS-1 step 1: the audio-URL cache, tested through /play with fake sources (no network, no real URLs).

The rule (decided 5 Oct 2026):
    no cached URL, or serve_fresh=true, or the cached URL expires soon  ->  fetch, refresh the cache, send
    otherwise                                                           ->  send the cached URL
"Soon" is the margin: these tests need it to be more than 10 minutes and less than 5 hours.
YouTube URLs carry their expiry in `expire=` (a Unix time). JioSaavn URLs have none.

Every test uses listing ids that are new on every run, so nothing cached (in memory or in a table) leaks between tests.
"""
import asyncio
import time
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend import db
from music_backend.cache import ListingURLCache
from music_backend.sources import SourceUnavailable, jiosaavn, ytmusic

TEST_URL = "postgresql:///music_test"
HOUR = 3600


class FakeSource:
    """Stands in for a source's get_song_url: counts calls, hands out a different URL each time, can fail on demand."""

    def __init__(self, make_url):
        self.make_url = make_url        # (song_id, call number) -> URL
        self.calls = 0
        self.fail = False

    async def __call__(self, song_id):
        self.calls += 1
        if self.fail:
            raise SourceUnavailable("fake outage")
        return self.make_url(song_id, self.calls)


def youtube_urls(expires_in):
    # shaped like a real YouTube audio URL: expire= sits among other parameters (203.0.113.7 is a documentation-only IP)
    return lambda song_id, n: f"https://audio.example/videoplayback?id={song_id}&expire={int(time.time() + expires_in)}&ip=203.0.113.7&n={n}"


def jiosaavn_urls(song_id, n):
    return f"https://aac.example/{song_id}_{n}_320.mp4"


def new_id():
    return "test-" + uuid4().hex[:10]


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:          # "with" runs the lifespan (pool + schema) on music_test
        yield client


@pytest.fixture
def youtube(monkeypatch):
    def install(expires_in):
        fake = FakeSource(youtube_urls(expires_in))
        monkeypatch.setattr(ytmusic, "get_song_url", fake)
        return fake
    return install


@pytest.fixture
def saavn(monkeypatch):
    fake = FakeSource(jiosaavn_urls)
    monkeypatch.setattr(jiosaavn, "get_song_url", fake)
    return fake


def play(client, path):
    """GET a /play path and return where it redirects to."""
    r = client.get(path, follow_redirects=False)
    assert r.status_code == 307, f"{path} answered {r.status_code}: {r.text}"
    return r.headers["location"]


# ---------- the cache is used ----------

def test_second_play_uses_the_cache(client, youtube):
    source, song = youtube(expires_in=6 * HOUR), new_id()
    first = play(client, f"/play/ytmusic/{song}")
    second = play(client, f"/play/ytmusic/{song}")
    assert source.calls == 1, "the second play should come from the cache, not the source"
    assert second == first


def test_jiosaavn_urls_never_expire(client, saavn):
    song = new_id()
    play(client, f"/play/jiosaavn/{song}")
    play(client, f"/play/jiosaavn/{song}")
    assert saavn.calls == 1


def test_each_listing_has_its_own_entry(client, youtube, saavn):
    yt, a, b = youtube(expires_in=6 * HOUR), new_id(), new_id()
    play(client, f"/play/ytmusic/{a}")
    play(client, f"/play/ytmusic/{b}")
    play(client, f"/play/jiosaavn/{a}")            # same id, other source: a different listing
    assert (yt.calls, saavn.calls) == (2, 1)


# ---------- expiry ----------

def test_expired_url_is_never_served(client, youtube):
    source, song = youtube(expires_in=-60), new_id()      # every URL handed out has already expired
    first = play(client, f"/play/ytmusic/{song}")
    second = play(client, f"/play/ytmusic/{song}")
    assert source.calls == 2 and second != first


def test_url_expiring_within_the_margin_is_refreshed(client, youtube):
    # 10 minutes left is too little: a seek near the end of a long song would reuse it after it dies
    source, song = youtube(expires_in=10 * 60), new_id()
    play(client, f"/play/ytmusic/{song}")
    play(client, f"/play/ytmusic/{song}")
    assert source.calls == 2


# ---------- serve_fresh ----------

def test_serve_fresh_skips_the_cache_and_updates_it(client, youtube):
    source, song = youtube(expires_in=6 * HOUR), new_id()
    old = play(client, f"/play/ytmusic/{song}")
    fresh = play(client, f"/play/ytmusic/{song}?serve_fresh=true")
    assert source.calls == 2 and fresh != old
    assert play(client, f"/play/ytmusic/{song}") == fresh, "after a fresh fetch, the cache holds the fresh URL"
    assert source.calls == 2


# ---------- failures ----------

def test_failures_are_not_cached(client, youtube):
    source, song = youtube(expires_in=6 * HOUR), new_id()
    source.fail = True
    assert client.get(f"/play/ytmusic/{song}", follow_redirects=False).status_code == 502
    source.fail = False
    play(client, f"/play/ytmusic/{song}")
    assert source.calls == 2, "a failure must not be remembered: the next request tries the source again"


def test_failed_fresh_fetch_returns_the_error_not_the_old_url(client, youtube):
    # the app asks for a fresh URL because the cached one failed; sending that one back would fail again
    source, song = youtube(expires_in=6 * HOUR), new_id()
    play(client, f"/play/ytmusic/{song}")
    source.fail = True
    assert client.get(f"/play/ytmusic/{song}?serve_fresh=true", follow_redirects=False).status_code == 502


# ---------- MUS-1 step 2: single-flight (one lookup per listing at a time) ----------

class SlowSource:
    """A source whose lookup takes 0.2 s, so requests really overlap. Counts calls; fails on demand."""

    def __init__(self, fail=False):
        self.calls = 0
        self.fail = fail

    async def get_song_url(self, song_id):
        self.calls += 1
        await asyncio.sleep(0.2)
        if self.fail:
            raise SourceUnavailable("fake outage")
        return f"https://audio.example/{song_id}_{self.calls}.m4a"

    def is_expired(self, url):
        return False


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def pool():
    pool = db.make_pool(TEST_URL)
    await pool.open()
    await db.apply_schema(pool)
    yield pool
    await pool.close()


@pytest.mark.anyio
async def test_two_requests_at_once_make_one_lookup(pool):
    source = SlowSource()
    cache = ListingURLCache({"ytmusic": source}, pool)
    song = new_id()
    first, second = await asyncio.gather(cache("ytmusic", song), cache("ytmusic", song))
    assert source.calls == 1
    assert first == second
    assert cache.running == {}                                  # nothing left behind


@pytest.mark.anyio
async def test_a_failed_lookup_reaches_every_waiter_and_is_not_kept(pool):
    source = SlowSource(fail=True)
    cache = ListingURLCache({"ytmusic": source}, pool)
    song = new_id()
    results = await asyncio.gather(cache("ytmusic", song), cache("ytmusic", song), return_exceptions=True)
    assert [type(r) for r in results] == [SourceUnavailable, SourceUnavailable]
    assert source.calls == 1
    assert cache.running == {}
    source.fail = False
    assert (await cache("ytmusic", song)).startswith("https://")   # the next request tries again
    assert source.calls == 2


@pytest.mark.anyio
async def test_a_skipped_song_does_not_cancel_the_lookup_for_others(pool):
    source = SlowSource()
    cache = ListingURLCache({"ytmusic": source}, pool)
    song = new_id()
    first = asyncio.create_task(cache("ytmusic", song))
    second = asyncio.create_task(cache("ytmusic", song))
    await asyncio.sleep(0.05)
    first.cancel()                                              # the first request's song was skipped
    assert (await second).startswith("https://")               # the other request still gets its URL
    with pytest.raises(asyncio.CancelledError):
        await first
    assert await cache("ytmusic", song) == await second        # and the lookup filled the cache
    assert source.calls == 1
