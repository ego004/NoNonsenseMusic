import asyncio
import logging
import time
from contextlib import asynccontextmanager
from typing import get_args
from uuid import UUID

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import RedirectResponse

from music_backend import db, library
from music_backend.matching import rank_songs
from music_backend.models import (EventRequest, LibraryRequest, LibrarySong, Listing, SearchResponse,
                                  SearchSourceInfo, SongRef, SourceName)
from music_backend.sources import SongNotFound, SourceUnavailable, jiosaavn, ytmusic


@asynccontextmanager
async def lifespan(app: FastAPI):
    # runs once at startup (before yield) and once at shutdown (after yield)
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    await db.apply_schema(pool)
    app.state.pool = pool
    yield
    await pool.close()


app = FastAPI(title="music", lifespan=lifespan)
# INFO for everything (keeps httpx's own DEBUG chatter out of the terminal), DEBUG for our own logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

SOURCES = {"jiosaavn" : jiosaavn, "ytmusic" : ytmusic}
# fail at startup, not at the first request, if this table and SourceName ever drift apart
assert set(SOURCES) == set(get_args(SourceName)), f"SOURCES {set(SOURCES)} != SourceName {get_args(SourceName)}"


@app.get("/")
async def root():
    return {"app_name": "NoNonsenseMusic", "api_version": "1.0"}

@app.get("/health")
async def health():
    return {"status": "ok"}


async def search_one(name: SourceName, source, q: str) -> tuple[list[Listing], SearchSourceInfo]:
    """Run one source's search: time it, count its listings, and never raise.

    Any failure (timeout, a changed reply shape, bad data) becomes an error message
    in its SearchSourceInfo, so one broken source cannot take down the other.
    """
    start = time.perf_counter()
    try:
        listings = await source.search(q)
        error = None
    except Exception as e:
        logger.warning("%s failed for %r: %r", name, q, e)
        listings = []
        error = type(e).__name__
    ms = round((time.perf_counter() - start) * 1000)
    info = SearchSourceInfo(source = name, healthy = error is None, num_results = len(listings), ms = ms, error = error)
    return listings, info


@app.get("/search")
async def search(q: str) -> SearchResponse:
    logger.debug("Received search query : %s", q)
    # every source runs at the same time; each one's failure stays inside its own search_one
    results = await asyncio.gather(*(search_one(name, source, q) for name, source in SOURCES.items()))
    by_source = []
    sources = []
    for source_listings, info in results:
        by_source.append(source_listings)
        sources.append(info)
    return SearchResponse(query = q, sources = sources, songs = rank_songs(by_source))

@app.get("/play/{source}/{song_id}")
async def play(source: SourceName, song_id: str) -> RedirectResponse:
    # source is checked by FastAPI against SourceName: an unknown source gets a 422 before we run
    try:
        song_url = await SOURCES[source].get_song_url(song_id)
    except SongNotFound:
        logger.warning("%s has no playable song %r", source, song_id)
        raise HTTPException(status_code=404, detail="Song not found")
    except SourceUnavailable as e:
        logger.warning("%s unavailable while resolving %r: %s", source, song_id, e)
        raise HTTPException(status_code=502, detail=f"{source} is unavailable right now")
    # redirect, not proxy: the browser fetches the audio straight from the CDN, so it never passes
    # through this server. Fine while browser and server share an IP (YouTube URLs are tied to it).
    return RedirectResponse(song_url)


# ---------- library (MUS-4) ----------

@app.post("/library")
async def add_to_library(body: LibraryRequest, request: Request) -> SongRef:
    """Like a song. The app sends the song's listings; the server finds or creates the stored song."""
    async with request.app.state.pool.connection() as conn:
        song_id = await library.resolve_song(conn, body.listings)
        await library.like(conn, song_id)
    return SongRef(song_id = song_id)


@app.delete("/library/{song_id}", status_code = 204)
async def remove_from_library(song_id: UUID, request: Request) -> Response:
    async with request.app.state.pool.connection() as conn:
        if not await library.unlike(conn, song_id):
            raise HTTPException(status_code = 404, detail = "Song is not in your library")
    return Response(status_code = 204)


@app.get("/library")
async def get_library(request: Request) -> list[LibrarySong]:
    async with request.app.state.pool.connection() as conn:
        return await library.liked_songs(conn)


@app.get("/recent")
async def get_recent(request: Request, limit: int = 50) -> list[LibrarySong]:
    async with request.app.state.pool.connection() as conn:
        return await library.recent_songs(conn, limit)


@app.post("/events")
async def add_event(body: EventRequest, request: Request) -> SongRef:
    """Record a play, a skip (and at which second), or a finish."""
    async with request.app.state.pool.connection() as conn:
        song_id = await library.resolve_song(conn, body.listings)
        await library.record_event(conn, song_id, body.type, body.position)
    return SongRef(song_id = song_id)
