from collections import OrderedDict
import asyncio
import logging
import time
from music_backend.settings import settings
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

logger = logging.getLogger(__name__)

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
        async with self.pool.connection() as conn:
            # CHANGED: the column is source_id
            cur = await conn.execute("SELECT url FROM listing_urls WHERE source = %s AND source_id = %s", [source, song_id])
            row = await cur.fetchone()
            if row is None:
                return None
            return row["url"]

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
        # CHANGED: returns one URL or None; memory first, then the table
        url = self.cache.get((source, song_id))
        if url is None:
            url = await self._get_db(source, song_id)
            if url is None:
                return None
            # copy into memory only: the table already has it
        if self.sources[source].is_expired(url):
            return None
        await self.set(source, song_id, url)
        return url

    async def set(self, source: str, song_id: str, url: str) -> None:
        # CHANGED: called only after a real fetch, so it always writes both levels (no flag needed);
        # the upsert already sets hit_at, so no _db_hit here
        self.cache[(source, song_id)] = url
        self._cache_hit(source, song_id)
        if len(self.cache) > self.max_size_in_memory:
            self.cache.popitem(last=False)
        await self._set_db(source, song_id, url)

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
        """Single-flight: the lookup already running for this listing, or a new one, started and registered at once
        (nothing else runs before the next await), so a second request finds it and waits instead of fetching."""
        task = self.running.get((source, song_id))
        if task is None:
            task = asyncio.create_task(self._lookup(source, song_id))
            self.running[(source, song_id)] = task
        return task

    async def _lookup(self, source: str, song_id: str) -> str:
        """The real lookup, run as a task, once per listing at a time: fetch, store, return the URL."""
        try:
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
        finally:
            # worked or failed: out of `running`, so the next request after this starts a fresh lookup
            del self.running[(source, song_id)]

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
                if (source, song_id) in self.running or await self.get(source, song_id) is not None:
                    continue                                             # running (it fills the cache anyway) or cached
                await asyncio.shield(self._start_lookup(source, song_id))
            except (SongNotFound, SourceUnavailable) as e:
                # expected: a song that is gone, a network blip, a source in its pause. One quiet line
                logger.info("prefetch %s %s: %s", source, song_id, e)
            except Exception:
                # a bug: say so loudly, but keep this worker alive (an escaped error would end its loop for good)
                logger.exception("prefetch %s %s failed", source, song_id)