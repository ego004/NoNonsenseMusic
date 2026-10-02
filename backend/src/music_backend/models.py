from typing import Literal
from pydantic import BaseModel, Field

# The one list of source IDs, used by every model, SOURCES in main.py, and the /play URL.
# Lowercase, no spaces: they appear in URLs (/play/ytmusic/...) and must never drift between files.
# Display names like "YouTube Music" belong to a UI, not here.
SourceName = Literal["jiosaavn", "ytmusic"]

class Listing(BaseModel):
    source : SourceName
    id : str
    title : str
    artists : list[str]
    album: str | None
    duration: int
    popularity : int | None


class Song(BaseModel):
    title: str
    artists: list[str] | None
    duration: int
    score: float
    best: Listing
    listings: list[Listing]

class SearchSourceInfo(BaseModel):
    source : SourceName
    healthy : bool
    num_results : int
    ms : int
    error : str | None = Field(default = None, exclude_if = lambda error: error is None)


class SearchResponse(BaseModel):
    query : str
    sources : list[SearchSourceInfo]
    songs : list[Song]
