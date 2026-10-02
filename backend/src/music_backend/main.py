import asyncio
import logging
import time
from typing import get_args

from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse

from music_backend.models import Listing, SearchSourceInfo, SearchResponse, SourceName
from music_backend.sources import SongNotFound, SourceUnavailable, jiosaavn, ytmusic

app = FastAPI(title="music")
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
    listings = []
    sources = []
    for source_listings, info in results:
        listings += source_listings
        sources.append(info)
    return SearchResponse(query = q, sources = sources, listings = listings)

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