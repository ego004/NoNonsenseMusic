import asyncio

from fastapi import FastAPI

from music_backend.models import Listing
from music_backend.sources import jiosaavn, ytmusic

app = FastAPI(title="music")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/search")
async def search(q: str) -> list[Listing]:
    # ask both sources at the same time: the wait is the slower of the two, not their sum
    jiosaavn_listings, ytmusic_listings = await asyncio.gather(jiosaavn.search(q), ytmusic.search(q))
    return jiosaavn_listings + ytmusic_listings
