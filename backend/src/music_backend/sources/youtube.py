"""Provide plain www.youtube.com as a source, rather than YouTube Music.

The search uses www.youtube.com's WEB client, and titles are returned raw: "The Weeknd - Blinding Lights
(Official Video)" stays exactly that, with no keyword cleaning.

Off by default: /search only queries this module when the request carries ?youtube=true. Channels count
as artists; this source has no albums, so search_albums is not defined here.
"""
import asyncio
import logging
import re
import time

from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError

from music_backend.core.settings import settings
from music_backend.models import ArtistDetail, ArtistRef, Listing
from music_backend.services.matching import to_song
from music_backend.services.video_titles import parse_video_title
from music_backend.core.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

SEARCH_URL = "https://www.youtube.com/youtubei/v1/search"
WATCH_URL = "https://www.youtube.com/watch?v="
# yt-dlp picks one audio-only format and puts its direct link in info["url"].
# m4a (AAC) first: Apple's AVPlayer cannot play YouTube's default WebM/Opus; fall back to anything else
YTDLP_OPTIONS = {"format" : "bestaudio[ext=m4a]/bestaudio", "quiet" : True, "no_warnings" : True}
CLIENT = {"clientName" : "WEB", "clientVersion" : "2.20251006.01.00", "hl" : "en", "gl" : "US"}
# InnerTube search params: channels only
CHANNELS_ONLY = "EgIQAg=="
# www.youtube.com answers more reliably with a browser User-Agent than with httpx's default
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
VIEW_MULTIPLIER = {"K" : 1_000, "M" : 1_000_000, "B" : 1_000_000_000}
REQUEST_TIMEOUT = 2
SOCKET_TIMEOUT = 10
# Validate URL components, rather than assuming every caller came from search. Real video and
# channel ids have fixed lengths, but accepting the safe character set keeps source-level callers
# (including tests and future provider aliases) from becoming unnecessarily coupled to that shape.
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]+$")
CHANNEL_ID = re.compile(r"^UC[A-Za-z0-9_-]+$")

logger = logging.getLogger(__name__)
http = SharedClient(timeout = REQUEST_TIMEOUT, headers = {"User-Agent" : USER_AGENT})

async def search(query: str) -> list[Listing]:
    """Search plain YouTube (videos only): each video as a listing, its song and artist read from its title (to_listing)."""
    body = {"context" : {"client" : CLIENT}, "query" : query}
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    listings = []
    for item in video_rows(r):
        # one malformed row must not discard the other 17
        try:
            listings.append(to_listing(item))
        except (KeyError, IndexError, ValueError, TypeError) as e:
            logger.warning("skipped a YouTube row (query of %d characters): %r", len(query), e)
    return listings


# no search_albums here on purpose: plain YouTube has no albums (its search only returns
# playlists of fan uploads), so main.py finds no such function and never asks this module.
# get_album is missing for the same reason: GET /album/youtube/… answers 404 "no albums"


async def get_artist(artist_id: str) -> ArtistDetail | None:
    """Return a channel's videos, newest first.

    yt-dlp runs extract_flat on /channel/<id>/videos on a worker thread, taking about 1-2 s. The source
    has no albums, and no bio because that would mean parsing the About tab.
    """
    if not CHANNEL_ID.fullmatch(artist_id):
        return None
    return await asyncio.to_thread(get_artist_blocking, artist_id)


def get_artist_blocking(artist_id: str) -> ArtistDetail | None:
    """Fetch the channel page with yt-dlp, translating errors: None for a channel that does not exist."""
    opts = {"extract_flat" : True, "quiet" : True, "no_warnings" : True,
            "playlistend" : 20, "socket_timeout": SOCKET_TIMEOUT}
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/channel/{artist_id}/videos", download=False)
    except DownloadError as e:
        if _missing_or_raise(e):
            return None
    if info is None:
        return None

    channel = info.get("channel") or info.get("uploader") or info.get("title") or ""
    name = channel or artist_id
    if not channel:
        logger.warning("YouTube: channel page %s has no channel name", artist_id)
    thumbnails = info.get("thumbnails") or []
    songs = []
    for entry in info.get("entries") or []:
        # live/upcoming entries have no duration and are not playable songs
        if not entry or not entry.get("id") or not entry.get("duration"):
            continue
        try:
            entry_thumbs = entry.get("thumbnails") or []
            title, artists = parse_video_title(entry["title"], channel)
            songs.append(to_song([Listing(
                source = "youtube",
                id = entry["id"],
                title = title,
                artists = artists,
                album = None,
                duration = entry["duration"],
                popularity = entry.get("view_count"),
                image = entry_thumbs[-1]["url"] if entry_thumbs else None,
                explicit = None,
            )]))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube: skipped a bad channel video: %r", e)
    return ArtistDetail(
        source = "youtube",
        id = artist_id,
        name = name,
        image = thumbnails[-1].get("url") if thumbnails else None,
        bio = None,
        followers = info.get("channel_follower_count") or None,
        monthly_listeners = None,
        songs = songs,
        albums = [],       # plain YouTube has none
    )


async def search_artists(query: str) -> list[ArtistRef]:
    """Search plain YouTube's channels; the CHANNELS_ONLY params turn results into channelRenderer rows."""
    body = {"context" : {"client" : CLIENT}, "query" : query, "params" : CHANNELS_ONLY}
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    artists = []
    for item in channel_rows(r):
        try:
            artists.append(artist_ref(item))
        except (KeyError, IndexError, ValueError, TypeError) as e:
            logger.warning("skipped a YouTube channel row (query of %d characters): %r", len(query), e)
    return artists


def channel_rows(response: dict) -> list[dict]:
    """Return the channelRenderer rows inside YouTube's search reply."""
    contents = (response.get("contents", {}).get("twoColumnSearchResultsRenderer", {})
                .get("primaryContents", {}).get("sectionListRenderer", {}).get("contents", []))
    rows = []
    for section in contents:
        for item in section.get("itemSectionRenderer", {}).get("contents", []):
            if "channelRenderer" in item:
                rows.append(item["channelRenderer"])
    return rows


def artist_ref(item: dict) -> ArtistRef:
    """Build an ArtistRef from one channelRenderer row; the channel id opens the artist page.

    The title arrives as simpleText here, while video rows use runs; both shapes are accepted.
    """
    thumbnails = item.get("thumbnail", {}).get("thumbnails", [])
    title = item["title"]
    name = title["simpleText"] if "simpleText" in title else "".join(run["text"] for run in title["runs"])
    return ArtistRef(
        source = "youtube",
        id = item["channelId"],
        # a topic channel reads "The Weeknd - Topic"; the words still match the artist in fusion
        name = name,
        image = thumbnails[-1]["url"] if thumbnails else None,
    )


def video_rows(response: dict) -> list[dict]:
    """Return the videoRenderer rows inside YouTube's deeply nested search reply.

    The reply also carries playlists (lockupViewModel), channels (channelRenderer) and shelves,
    which are not songs: only videoRenderer rows are taken.
    """
    contents = (response.get("contents", {}).get("twoColumnSearchResultsRenderer", {})
                .get("primaryContents", {}).get("sectionListRenderer", {}).get("contents", []))
    rows = []
    for section in contents:
        for item in section.get("itemSectionRenderer", {}).get("contents", []):
            if "videoRenderer" in item:
                rows.append(item["videoRenderer"])
    return rows


def to_listing(item: dict) -> Listing:
    """Turn one plain-YouTube video row into a Listing.

    A row without lengthText (live, upcoming) has no duration and is skipped by the caller.
    """
    title, artists = parse_video_title(title_of(item), channel_of(item))
    return Listing(
        source = "youtube",
        id = item["videoId"],
        title = title,
        artists = artists,
        # plain YouTube has no album information on a search row
        album = None,
        duration = to_seconds(item["lengthText"]["simpleText"]),
        popularity = views_of(item),
        image = artwork(item),
        explicit = is_explicit(item),
    )


def title_of(item: dict) -> str:
    """Return the video's title as shown: its runs joined (parse_video_title reads the song out of it)."""
    return "".join(run["text"] for run in item["title"]["runs"])


def channel_of(item: dict) -> str:
    """Return the channel that uploaded the video (ownerText; shortBylineText is the same line in some rows)."""
    for key in ("ownerText", "shortBylineText"):
        runs = item.get(key, {}).get("runs", [])
        if runs:
            return runs[0]["text"]
    raise KeyError(key)


def artwork(item: dict) -> str | None:
    """Return the row's largest thumbnail (hq720 for ordinary search results)."""
    thumbnails = item.get("thumbnail", {}).get("thumbnails", [])
    if not thumbnails:
        return None
    return thumbnails[-1]["url"]


def views_of(item: dict) -> int | None:
    """Return the view count as an int.

    '1,071,511,379 views' -> 1071511379 and '1.2M views' -> 1200000. Missing or unparseable text
    yields None rather than a broken row.
    """
    text = (item.get("viewCountText", {}).get("simpleText")
            or item.get("shortViewCountText", {}).get("simpleText"))
    if not text:
        return None
    try:
        return to_count(text)
    except ValueError:
        return None


def is_explicit(item: dict) -> bool | None:
    """Return True when an explicit badge is present, otherwise None.

    Plain YouTube does not reliably badge, so absence means unknown, not clean.
    """
    if any(b.get("metadataBadgeRenderer", {}).get("style") == "BADGE_STYLE_TYPE_EXPLICIT"
           for b in item.get("badges", [])):
        return True
    return None


def to_seconds(duration: str) -> int:
    """Convert a clock duration to seconds: '3:22' -> 202, '1:02:03' -> 3723."""
    seconds = 0
    for part in duration.split(":"):
        seconds = seconds * 60 + int(part)
    return seconds


def to_count(text: str) -> int:
    """Convert a view-count string to an int: '1,071,511,379 views' -> 1071511379, '1.2M views' -> 1200000."""
    number = text.split()[0].replace(",", "")
    if number[-1] in VIEW_MULTIPLIER:
        return round(float(number[:-1]) * VIEW_MULTIPLIER[number[-1]])
    return int(number)


async def get_song_url(song_id: str) -> str:
    """Return the direct audio URL for a plain YouTube video id.

    The URL expires after a few hours and only works from the IP address that asked for it.
    """
    # yt-dlp is blocking code (~2 s). Called on the event loop it would freeze the server; to_thread
    # runs it on a worker thread so the coroutine can await the result.
    if not VIDEO_ID.fullmatch(song_id):
        raise SongNotFound(song_id)
    return await asyncio.to_thread(extract_audio_url, song_id)


def extract_audio_url(song_id: str) -> str:
    """Fetch the audio URL with yt-dlp, translating its errors into the two source errors."""
    try:
        with YoutubeDL({**YTDLP_OPTIONS, "socket_timeout": SOCKET_TIMEOUT}) as ydl:
            info = ydl.extract_info(WATCH_URL + song_id, download=False)
    except DownloadError as e:
        if _missing_or_raise(e):
            raise SongNotFound(song_id) from e
    try:
        return info["url"]
    except (KeyError, TypeError) as e:
        raise SourceUnavailable("YouTube returned no audio URL") from e


def _missing_or_raise(error: DownloadError) -> bool:
    """Translate yt-dlp's repeated error shapes; return True for a missing video/channel.

    All yt-dlp entry points use the same distinction: a bot block is temporary source trouble,
    a known 400/404 is absent content, and every other error is a source failure.
    """
    text = str(error)
    inner = error.exc_info[1] if error.exc_info else None
    if "not a bot" in text:
        raise SourceBlocked("YouTube: bot check on this IP") from error
    if (isinstance(inner, ExtractorError) and inner.expected) or "does not exist" in text \
            or "HTTP Error 400" in text or "HTTP Error 404" in text:
        return True
    raise SourceUnavailable(f"YouTube: {error}") from error


def is_expired(song_url: str) -> bool:
    # The expiry arrives in the link as ?expire=. When no such value is present the link is assumed
    # not to expire; the client can make a serve_fresh request if it turns out expired.
    expire = re.search(r'[?&]expire=(\d+)', song_url)
    if expire is None:
        return False
    return int(expire.group(1)) - int(time.time()) <= settings.youtube_cache_expiry_threshold * 60
