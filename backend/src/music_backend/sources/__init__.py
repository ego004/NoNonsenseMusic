"""Music sources. Every source module offers the same two functions:

    async def search(query: str) -> list[Listing]
    async def get_song_url(song_id: str) -> str      # direct audio URL

and reports failures with the two exceptions below instead of its own library's errors,
so main.py never needs to know whether a source uses httpx, yt-dlp, or anything else.
"""


class SongNotFound(Exception):
    """The source has no playable song with this id."""


class SourceUnavailable(Exception):
    """The source could not be reached or answered too slowly."""
