from fastapi import FastAPI

from music_backend.models import Listing
from music_backend.sources import jiosaavn

app = FastAPI(title="music")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/search")
async def search(q: str) -> list[Listing]:
    return await jiosaavn.search(q)
