"""Music sources. Every source module offers the same two functions:

    async def search(query: str) -> list[Listing]
    async def get_song_url(song_id: str) -> str      # direct audio URL

and, when the source has them at all, four more (MUS-20; a source without albums simply omits both):

    async def search_albums(query: str) -> list[AlbumRef]
    async def search_artists(query: str) -> list[ArtistRef]
    async def get_album(album_id: str) -> AlbumDetail | None      # None: no such album
    async def get_artist(artist_id: str) -> ArtistDetail | None   # None: no such artist

and, when the source has radio, one more (MUS-3; every source currently does):

    async def radio(source_id: str, limit: int = 25) -> list[Listing]   # []: no station for this id

and reports failures with the two exceptions below instead of its own library's errors,
so main.py never needs to know whether a source uses httpx, yt-dlp, or anything else.
"""


class SongNotFound(Exception):
    """The source has no playable song with this id."""


class SourceUnavailable(Exception):
    """The source could not be reached or answered too slowly."""


class SourceBlocked(SourceUnavailable):
    """The source refuses this IP (YouTube's "Sign in to confirm you're not a bot"), or tells us to slow down
    (JioSaavn's 429, BUG-3). A kind of SourceUnavailable, so main.py still answers 502. The cache catches exactly
    this one to pause the source (MUS-1 step 2b), and raises it itself during that pause."""
