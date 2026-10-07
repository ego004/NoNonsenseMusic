from datetime import datetime
from typing import Literal
from uuid import UUID
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
    # artwork URL, already rewritten to a large size by the source adapter
    image : str | None = None
    # the explicit version (JioSaavn's explicit_content, YouTube Music's E badge); None: not known (older rows)
    explicit : bool | None = None

class BaseSong(BaseModel):
    title: str
    artists: list[str] | None
    duration: int
    best: Listing
    listings: list[Listing]

class LibrarySong(BaseSong):
    """A stored song as the app shows it: identity from the database, display from its best listing."""
    id : UUID
    liked : bool
    at : datetime | None = None   # liked_at for /liked, last played for /recent

class Song(BaseSong):
    score: float

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


EventType = Literal["play", "skip", "finish"]


class ListingsRequest(BaseModel):
    # IDs are assigned lazily: the app sends the song's listings, the server finds or creates the song
    listings : list[Listing] = Field(min_length = 1)


class EventRequest(ListingsRequest):
    type : EventType
    position : int = Field(ge = 0)


class SongRef(BaseModel):
    song_id : UUID

class PlaylistRequest(BaseModel):
    name : str = Field(min_length=1)

class PlaylistMetadata(BaseModel):
    id : UUID
    name : str
    song_count : int
    thumbnail : str | None = None
    duration : int

class PlaylistsResponse(BaseModel):
    playlists : list[PlaylistMetadata]

class MoveRequest(BaseModel):
    top_neighbour_id : UUID | None = None
    bottom_neighbour_id : UUID | None = None

class PlaylistItem(BaseModel):
    item_id : UUID
    song: LibrarySong

class PlaylistItems(PlaylistMetadata):
    items : list[PlaylistItem]

class PlaylistItemRef(BaseModel):
    item_id : UUID
    song_id : UUID

class PrefetchListing(BaseModel):
    source: SourceName
    source_id : str

class PrefetchRequest(BaseModel):
    # the app sends 5 to 10; the maximum stops one request from queueing thousands of lookups
    listings : list[PrefetchListing] = Field(min_length = 1, max_length = 50)

class LyricsRequest(BaseModel):
    song_name : str
    artist_name : str                       # LRCLIB answers 400 without one
    song_duration : int                     # seconds
    youtube_id : str | None = None          # the song's ytmusic listing, if any (even when JioSaavn's copy plays)

class LyricLine(BaseModel):
    start_ms : int | None                   # None: plain lyrics, no times. A line ends where the next one starts
    text : str

class LyricsResponse(BaseModel):
    lyrics_source : Literal["lrclib", "ytmusic"] | None   # None: nobody had lyrics (lines is [])
    synced : bool
    lines : list[LyricLine]
