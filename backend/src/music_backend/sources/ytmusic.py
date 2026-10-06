import asyncio
import logging
import re

import time
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError
from music_backend.settings import settings
from music_backend.models import Listing
from music_backend.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

SEARCH_URL = "https://music.youtube.com/youtubei/v1/search"
WATCH_URL = "https://music.youtube.com/watch?v="
# yt-dlp picks one audio-only format and puts its direct link in info["url"].
# m4a (AAC) first: Apple's AVPlayer cannot play YouTube's default WebM/Opus; fall back to anything else
YTDLP_OPTIONS = {"format" : "bestaudio[ext=m4a]/bestaudio", "quiet" : True, "no_warnings" : True}
CLIENT = {"clientName" : "WEB_REMIX", "clientVersion" : "1.20250101.01.00", "hl" : "en"}
SONGS_ONLY = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
SEPARATOR = " • "
ARTIST_JOINERS = (", ", " & ")
PLAYS_MULTIPLIER = {"K" : 1_000, "M" : 1_000_000, "B" : 1_000_000_000}
REQUEST_TIMEOUT = 2

logger = logging.getLogger(__name__)
http = SharedClient(timeout = REQUEST_TIMEOUT)   # one connection to YouTube Music, reused by every search

async def search(query: str) -> list[Listing]:
    """Search YouTube Music (songs only) and return a list of listings."""
    body = {"context" : {"client" : CLIENT}, "query" : query, "params" : SONGS_ONLY}
    # added the timeout, but i wanna see 2 things... 1. when it times out what gets passed up? i suppose an error class which is converted to json..
    # 2. if it is jsoon, can it be caught by try except?
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    listings = []
    for item in song_rows(r):
        # one odd row (seen once: no playlistItemData) must not throw away the other 19
        try:
            listings.append(to_listing(item))
        except (KeyError, IndexError, ValueError) as e:
            logger.warning("skipped a YouTube Music row for %r: %r", query, e)
    return listings


def song_rows(response: dict) -> list[dict]:
    """Find the song rows inside YouTube Music's deeply nested search reply."""
    tabs = response.get("contents", {}).get("tabbedSearchResultsRenderer", {}).get("tabs", [])
    if not tabs:
        return []
    sections = tabs[0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"]
    rows = []
    for section in sections:
        # "no results" and "did you mean" sections have no musicShelfRenderer
        if "musicShelfRenderer" in section:
            for row in section["musicShelfRenderer"]["contents"]:
                rows.append(row["musicResponsiveListItemRenderer"])
    return rows


def to_listing(item: dict) -> Listing:
    """Turn one YouTube Music song row into a Listing."""
    title = column(item, 0)[0]["text"]
    parts = split_on_separator(column(item, 1))
    artists = [run["text"] for run in parts[0] if run["text"] not in ARTIST_JOINERS]
    album = parts[1][0]["text"] if len(parts) == 3 else None
    plays = column(item, 2)
    return Listing(
        source = "ytmusic",
        id = video_id(item),
        title = title,
        artists = artists,
        album = album,
        duration = to_seconds(parts[-1][0]["text"]),
        popularity = to_count(plays[0]["text"]) if plays else None,
        image = artwork(item),
    )


# YouTube serves at least two row layouts (about 1 request in 5 got the second one, 2 Oct 2026):
#   usual:  playlistItemData.videoId, and the title run is a link
#   other:  no playlistItemData, the title run is plain text, the whole row is the link
# The play button overlay carries the id in both.
VIDEO_ID_PATHS = [
    ("playlistItemData", "videoId"),
    ("navigationEndpoint", "watchEndpoint", "videoId"),
    ("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"),
]


def artwork(item: dict) -> str | None:
    """The row's cover image, rewritten from the 60/120 px search thumbnail to 544 px."""
    thumbnails = item.get("thumbnail", {}).get("musicThumbnailRenderer", {}).get("thumbnail", {}).get("thumbnails", [])
    if not thumbnails:
        return None
    # the size lives in the URL itself: ...=w120-h120-l90-rj
    return re.sub(r"=w\d+-h\d+", "=w544-h544", thumbnails[-1]["url"])


def video_id(item: dict) -> str:
    """The row's videoId, from whichever place this row layout keeps it."""
    for path in VIDEO_ID_PATHS:
        value = item
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if value:
            return value
    raise KeyError("videoId")


def column(item: dict, index: int) -> list[dict]:
    """The text pieces ("runs") of one column in a song row; empty if the column is missing."""
    columns = item["flexColumns"]
    if index >= len(columns):
        return []
    return columns[index]["musicResponsiveListItemFlexColumnRenderer"]["text"].get("runs", [])


def split_on_separator(runs: list[dict]) -> list[list[dict]]:
    """Split runs into groups wherever the ' • ' separator appears."""
    groups = [[]]
    for run in runs:
        if run["text"] == SEPARATOR:
            groups.append([])
        else:
            groups[-1].append(run)
    return groups


def to_seconds(duration: str) -> int:
    """'3:22' -> 202, '1:02:03' -> 3723."""
    seconds = 0
    for part in duration.split(":"):
        seconds = seconds * 60 + int(part)
    return seconds


def to_count(plays: str) -> int:
    """'952 plays' -> 952, '2.6K plays' -> 2600, '9.5B plays' -> 9500000000."""
    number = plays.split()[0]
    if number[-1] in PLAYS_MULTIPLIER:
        return round(float(number[:-1]) * PLAYS_MULTIPLIER[number[-1]])
    return int(number.replace(",", ""))


async def get_song_url(song_id: str) -> str:
    """Direct audio URL for a YouTube Music video id (best audio-only format, ~133 kbps Opus).

    The URL expires after a few hours and only works from the IP address that asked for it.
    """
    # yt-dlp is ordinary blocking code (~2 s). Called directly, it would freeze the whole server;
    # to_thread runs it on a separate thread and gives back something we can await.
    return await asyncio.to_thread(extract_audio_url, song_id)


def extract_audio_url(song_id: str) -> str:
    """The blocking yt-dlp call, with its errors translated into our two source errors."""
    try:
        with YoutubeDL(YTDLP_OPTIONS) as ydl:
            info = ydl.extract_info(WATCH_URL + song_id, download=False)
    except DownloadError as e:
        # yt-dlp wraps everything in DownloadError; the error inside says what really happened.
        # "This video is unavailable" (missing, private, blocked) is an ExtractorError marked expected=True;
        # a network failure is a TransportError.
        inner = e.exc_info[1] if e.exc_info else None
        # YouTube blocking this IP ("Sign in to confirm you're not a bot") is ALSO expected=True, but the song
        # is fine: the source is what's unavailable. yt-dlp has no separate error type for it, so the message
        # is the only signal. Checked first, so it never becomes a 404 (seen 5 Oct 2026).
        if "not a bot" in str(e):
            raise SourceBlocked("YouTube Music: bot check on this IP") from e
        if isinstance(inner, ExtractorError) and inner.expected:
            raise SongNotFound(song_id) from e
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    return info["url"]

def is_expired(song_url: str) -> bool:
    return int(re.search(r'[?&]expire=(\d+)', song_url).group(1)) - int(time.time()) <= settings.youtube_cache_expiry_threshold * 60