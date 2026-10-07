from collections import OrderedDict
from datetime import datetime, timedelta, timezone
import asyncio
import logging
import time

from psycopg.types.json import Jsonb

from music_backend import lyrics
from music_backend.models import LyricsRequest, LyricsResponse
from music_backend.settings import settings
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

logger = logging.getLogger(__name__)


def single_flight(running: dict, key, work) -> asyncio.Task:
    """One lookup per key at a time ("single-flight"): the lookup already running for `key`, or a new one, started
    and registered at once (nothing else runs before the next await), so a second caller finds it and waits for it
    instead of starting another. `work` makes the lookup: a function returning a coroutine. When the lookup ends,
    worked or failed, the key leaves `running`, so the next caller after it starts afresh. Shared by both caches:
    it was written out twice."""
    task = running.get(key)
    if task is None:
        task = asyncio.create_task(_run_once(running, key, work))
        running[key] = task
    return task


async def _run_once(running: dict, key, work):
    try:
        return await work()
    finally:
        del running[key]


class ListingURLCache:
    """Audio URLs per listing (source, song_id), in two levels: memory, and the listing_urls table.
    Both drop the least recently used entry when full.

    Call it to get a URL:   url = await cache(source, song_id)
    It answers from memory or the table when the cached URL is still good, and otherwise fetches, stores and returns a new one.
    """

    def __init__(self, sources: dict, pool):
        self.cache = OrderedDict()
        self.sources = sources            # main.py's SOURCES, passed in: one list of sources, not two
        self.max_size_in_memory = settings.cache_max_size_in_memory
        self.max_size_in_db = settings.cache_max_size_in_db
        self.pool = pool
        self.running = {}
        # MUS-1 step 2b, the backoff ("circuit breaker"). Per SOURCE: a bot check blocks our IP, not one song.
        self.blocked_until: dict[str, float] = {}   # source -> Unix time before which we do not ask it
        self.strikes: dict[str, int] = {}           # source -> bot checks in a row; each one doubles the pause
        # MUS-1 step 3, prefetch: (source, source_id) pairs waiting for a worker; a new list replaces what waits
        self.prefetch_queue: asyncio.Queue[tuple[str, str]] = asyncio.Queue()

    async def _db_hit(self, source: str, song_id: str) -> None:
        # the table's own "recently used" mark: the trim in _set_db drops the oldest hit_at first
        async with self.pool.connection() as conn:
            await conn.execute("UPDATE listing_urls SET hit_at = now() WHERE source = %s AND source_id = %s",
                               [source, song_id])

    def _cache_hit(self, source: str, song_id: str) -> None:
        # CHANGED: plain def, it awaits nothing (memory only)
        self.cache.move_to_end((source, song_id))

    async def _get_db(self, source: str, song_id: str) -> str | None:
        """The stored URL, only read (the prefetch worker's check: a prefetch is not a use)."""
        async with self.pool.connection() as conn:
            row = await (await conn.execute("SELECT url FROM listing_urls WHERE source = %s AND source_id = %s",
                                            [source, song_id])).fetchone()
        return None if row is None else row["url"]

    async def _take_db(self, source: str, song_id: str) -> str | None:
        """The stored URL, marked used in the same statement (it was a SELECT, then an UPDATE: two round trips).
        An expired row is marked too; the fresh fetch that follows overwrites it anyway."""
        async with self.pool.connection() as conn:
            row = await (await conn.execute(
                "UPDATE listing_urls SET hit_at = now() WHERE source = %s AND source_id = %s RETURNING url",
                [source, song_id])).fetchone()
        return None if row is None else row["url"]

    async def _set_db(self, source: str, song_id: str, url: str) -> None:
        # CHANGED: one upsert instead of DELETE + INSERT (two requests at once crashed with UniqueViolation),
        # then the trim. One block, so both commit together.
        async with self.pool.connection() as conn:
            await conn.execute(
                """INSERT INTO listing_urls (source, source_id, url) VALUES (%s, %s, %s)
                   ON CONFLICT (source, source_id) DO UPDATE SET
                       url        = EXCLUDED.url,
                       fetched_at = CASE WHEN listing_urls.url <> EXCLUDED.url THEN now() ELSE listing_urls.fetched_at END,
                       hit_at     = now()""",
                [source, song_id, url],
            )
            await conn.execute(
                """DELETE FROM listing_urls WHERE (source, source_id) IN (
                       SELECT source, source_id FROM listing_urls ORDER BY hit_at DESC OFFSET %s)""",
                [self.max_size_in_db],
            )

    async def get(self, source: str, song_id: str) -> str | None:
        """One URL or None: memory first, then the table. Any hit marks the row used (hit_at), so the trim drops the
        least recently used; a table hit also copies the URL into memory. Every hit used to write the table twice (an
        upsert and the trim's DELETE): 600 statements for 300 hits, measured 7 Oct. Now one statement per hit (a table
        hit reads and marks in one UPDATE … RETURNING), and no trim: a hit adds no row, so it cannot grow the table.
        A play's way in: the prefetch worker checks with `_has_fresh`, which marks nothing."""
        url = self.cache.get((source, song_id))
        if url is not None:
            if self.sources[source].is_expired(url):
                return None
            self._cache_hit(source, song_id)
            await self._db_hit(source, song_id)
            return url
        url = await self._take_db(source, song_id)              # marked used: the trim keeps the most recently used
        if url is None or self.sources[source].is_expired(url):
            return None
        self._remember(source, song_id, url)
        return url

    async def set(self, source: str, song_id: str, url: str) -> None:
        """After a real fetch: both levels. The upsert sets hit_at, and the trim runs here only: the table grows only here."""
        self._remember(source, song_id, url)
        await self._set_db(source, song_id, url)

    def _remember(self, source: str, song_id: str, url: str) -> None:
        # memory: store as the most recently used, and drop the least recently used past the limit
        self.cache[(source, song_id)] = url
        self._cache_hit(source, song_id)
        if len(self.cache) > self.max_size_in_memory:
            self.cache.popitem(last=False)

    async def __call__(self, source: str, song_id: str, serve_fresh: bool = False) -> str:
        """The rule: no cached URL, or serve_fresh, or it expires soon -> fetch, store, return. Otherwise the cached one."""
        # CHANGED: one URL variable; get hides memory vs table
        url = None if serve_fresh else await self.get(source, song_id)
        if url is None:
            # wait for the lookup, with its URL or its error. shield: if this request is cancelled (the song was
            # skipped), only its own wait ends; the lookup goes on for anyone else waiting, and still fills the cache
            url = await asyncio.shield(self._start_lookup(source, song_id))
        return url

    def _start_lookup(self, source: str, song_id: str) -> asyncio.Task:
        """Single-flight per listing: a second request for a listing being fetched waits for that fetch."""
        return single_flight(self.running, (source, song_id), lambda: self._lookup(source, song_id))

    async def _lookup(self, source: str, song_id: str) -> str:
        """The real lookup, run as a task, once per listing at a time: fetch, store, return the URL."""
        # paused? then answer at once, without asking the source (this raise is NOT a new strike: we never asked)
        self._refuse_if_paused(source)
        try:
            # SongNotFound / SourceUnavailable pass straight through, so a failure is never stored
            url = await self.sources[source].get_song_url(song_id)
        except SourceBlocked:
            self._strike(source)        # the source itself said "blocked": pause it, then pass the error on
            raise
        self.strikes[source] = 0        # it answered: the next block starts again from the short pause
        await self.set(source, song_id, url)
        return url

    def _refuse_if_paused(self, source: str) -> None:
        """During a source's pause, raise SourceBlocked straight away: no request goes to the source."""
        until = self.blocked_until.get(source, 0)
        if time.time() < until:
            raise SourceBlocked(f"{source} is paused after a bot check until {time.strftime('%H:%M:%S', time.localtime(until))}")

    def _strike(self, source: str) -> None:
        """One more bot check in a row: pause = START x 2^(strikes - 1), at most MAX."""
        self.strikes[source] = self.strikes.get(source, 0) + 1
        minutes = min(settings.backoff_max_minutes, settings.backoff_start_minutes * 2 ** (self.strikes[source] - 1))
        self.blocked_until[source] = time.time() + minutes * 60
        logger.warning("%s: bot check #%d in a row, asking it nothing for %.0f min", source, self.strikes[source], minutes)

    async def _has_fresh(self, source: str, song_id: str) -> bool:
        """Whether a good URL is cached, marking nothing: the prefetch worker's check. It used `get`, which marks the
        row used, so "least recently used" meant "least recently prefetched" (up to 10 UPDATEs per song change)."""
        url = self.cache.get((source, song_id))                # a plain dict read: the order is left as it is
        if url is None:
            url = await self._get_db(source, song_id)
        return url is not None and not self.sources[source].is_expired(url)

    def prefetch(self, listings) -> None:
        """The newest list of listings coming next: replaces whatever still waits (lookups already running finish)."""
        while not self.prefetch_queue.empty():
            self.prefetch_queue.get_nowait()
        for listing in listings:
            self.prefetch_queue.put_nowait((listing.source, listing.source_id))   # each put wakes one free worker

    async def prefetch_worker(self) -> None:
        """One prefetch worker (main.py's lifespan starts several): forever, take the next waiting listing and look
        it up, unless it is cached or already being looked up. One lookup at a time per worker, so N workers mean
        at most N prefetch lookups at once: yt-dlp shares its threads with your clicks."""
        while True:
            source, song_id = await self.prefetch_queue.get()           # free: asleep here until a list arrives
            try:
                if (source, song_id) in self.running or await self._has_fresh(source, song_id):
                    continue                                             # running (it fills the cache anyway) or cached
                await asyncio.shield(self._start_lookup(source, song_id))
            except (SongNotFound, SourceUnavailable) as e:
                # expected: a song that is gone, a network blip, a source in its pause. One quiet line
                logger.info("prefetch %s %s: %s", source, song_id, e)
            except Exception:
                # a bug: say so loudly, but keep this worker alive (an escaped error would end its loop for good)
                logger.exception("prefetch %s %s failed", source, song_id)


class LyricsCache:
    """Lyrics replies per song, in the lyrics table. Not ListingURLCache renamed: lyrics are kept per song, not per
    listing, never go stale when timed, and need no memory level, backoff or workers. Only single-flight is shared
    (`single_flight`, above).

    Call it to get lyrics:   reply = await lyrics_cache(song)
    Timed lyrics are kept for good. Plain or empty ones are kept for settings.lyrics_recheck_days, and only when
    every source answered: if one failed, it may have had better, so the next request asks again.
    """

    def __init__(self, pool):
        self.pool = pool
        self.running: dict[tuple, asyncio.Task] = {}     # single-flight, as in ListingURLCache: one lookup per song

    async def __call__(self, song: LyricsRequest) -> LyricsResponse:
        reply = await self.get(song)
        if reply is None:
            # shield: a request that gives up (the app closed Lyrics) does not cancel a lookup another request shares
            reply = await asyncio.shield(self._start_lookup(song))
        return reply

    def _start_lookup(self, song: LyricsRequest) -> asyncio.Task:
        return single_flight(self.running, key(song), lambda: self._lookup(song))

    async def _lookup(self, song: LyricsRequest) -> LyricsResponse:
        reply, every_source_answered = await lyrics.find_lyrics(song)
        if reply.synced or every_source_answered:
            await self.set(song, reply)
        return reply

    async def get(self, song: LyricsRequest) -> LyricsResponse | None:
        async with self.pool.connection() as conn:
            cur = await conn.execute(
                """SELECT reply, fetched_at FROM lyrics
                   WHERE song_name = %s AND artist_name = %s AND song_duration = %s AND youtube_id = %s""", key(song))
            row = await cur.fetchone()
        if row is None:
            return None
        reply = LyricsResponse.model_validate(row["reply"])
        recheck_after = row["fetched_at"] + timedelta(days=settings.lyrics_recheck_days)
        if not reply.synced and datetime.now(timezone.utc) > recheck_after:
            return None                          # plain or empty, and old: a source may have them now
        return reply

    async def set(self, song: LyricsRequest, reply: LyricsResponse) -> None:
        async with self.pool.connection() as conn:
            await conn.execute(
                """INSERT INTO lyrics (song_name, artist_name, song_duration, youtube_id, reply) VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (song_name, artist_name, song_duration, youtube_id) DO UPDATE SET
                       reply = EXCLUDED.reply, fetched_at = now()""",
                [*key(song), Jsonb(reply.model_dump())],
            )


def key(song: LyricsRequest) -> tuple[str, str, int, str]:
    """One song as the app asks for it. With and without a YouTube copy are two entries: the answers can differ."""
    return song.song_name, song.artist_name, song.song_duration, song.youtube_id or ""
