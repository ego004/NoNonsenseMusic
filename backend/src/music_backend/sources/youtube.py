"""Plain YouTube as a source (MUS-13): the same functions as the other sources, but the search is
www.youtube.com's WEB client, not YouTube Music's, and titles are returned RAW (the ticket's no-keyword-cleaning
rule: "The Weeknd - Blinding Lights (Official Video)" stays exactly that).

Off by default: /search only queries this module when the request carries ?youtube=true.
Channels count as artists (MUS-20); albums: this source has none, so search_albums is simply not defined here.
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
from music_backend.core.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

SEARCH_URL = "https://www.youtube.com/youtubei/v1/search"
WATCH_URL = "https://www.youtube.com/watch?v="
# yt-dlp picks one audio-only format and puts its direct link in info["url"].
# m4a (AAC) first: Apple's AVPlayer cannot play YouTube's default WebM/Opus; fall back to anything else
YTDLP_OPTIONS = {"format" : "bestaudio[ext=m4a]/bestaudio", "quiet" : True, "no_warnings" : True}
CLIENT = {"clientName" : "WEB", "clientVersion" : "2.20251006.01.00", "hl" : "en", "gl" : "US"}
# InnerTube search params: channels only (probed 10 Oct 2026)
CHANNELS_ONLY = "EgIQAg=="
# www.youtube.com answers more reliably with a browser User-Agent than with httpx's default
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
VIEW_MULTIPLIER = {"K" : 1_000, "M" : 1_000_000, "B" : 1_000_000_000}
REQUEST_TIMEOUT = 2

logger = logging.getLogger(__name__)
http = SharedClient(timeout = REQUEST_TIMEOUT, headers = {"User-Agent" : USER_AGENT})

async def search(query: str) -> list[Listing]:
    """Search plain YouTube (videos only) and return a list of listings, titles untouched."""
    body = {"context" : {"client" : CLIENT}, "query" : query}
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    listings = []
    for item in video_rows(r):
        # one odd row must not throw away the other 17
        try:
            listings.append(to_listing(item))
        except (KeyError, IndexError, ValueError, TypeError) as e:
            logger.warning("skipped a YouTube row for %r: %r", query, e)
    return listings


# no search_albums here on purpose: plain YouTube has no albums (its search only returns
# playlists of fan uploads), so main.py finds no such function and never asks this module.
# get_album is missing for the same reason: GET /album/youtube/… answers 404 "no albums"


async def radio(source_id: str, limit: int = 25) -> list[Listing]:
    """The RD mix for one video (yt-dlp extract_flat on watch?v=…&list=RD…, ~1-2 s in a thread).

    The Innertube next call with playlistId=RD+videoId returns no panel at all (measured 10 Oct);
    yt-dlp's flat playlist handles the mix instead. An unknown video is [] (the mix does not exist).
    """
    return await asyncio.to_thread(radio_blocking, source_id, limit)


def radio_blocking(source_id: str, limit: int) -> list[Listing]:
    """The blocking yt-dlp call: entries of the RD mix, newest-album-cut ordering by YouTube."""
    opts = {"extract_flat" : True, "quiet" : True, "no_warnings" : True, "playlistend" : limit + 1}
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"{WATCH_URL}{source_id}&list=RD{source_id}", download=False)
    except DownloadError as e:
        inner = e.exc_info[1] if e.exc_info else None
        # bot check first (same as extract_audio_url): the video is fine, this IP is refused
        if "not a bot" in str(e):
            raise SourceBlocked("YouTube: bot check on this IP") from e
        # a video that is not there: extractor's own message, or the API refusing with 400/404
        if (isinstance(inner, ExtractorError) and inner.expected) or "does not exist" in str(e) \
                or "HTTP Error 400" in str(e) or "HTTP Error 404" in str(e):
            return []
        raise SourceUnavailable(f"YouTube: {e}") from e
    if info is None:
        return []
    channel = info.get("channel") or info.get("uploader") or ""
    listings = []
    for entry in info.get("entries") or []:
        # live/upcoming entries have no duration and are not playable songs
        if not entry or not entry.get("id") or not entry.get("duration"):
            continue
        try:
            entry_thumbs = entry.get("thumbnails") or []
            listings.append(Listing(
                source = "youtube",
                id = entry["id"],
                title = entry["title"],          # raw, MUS-13: no keyword stripping
                artists = [entry.get("channel") or channel] if (entry.get("channel") or channel) else [],
                album = None,
                duration = entry["duration"],
                popularity = entry.get("view_count"),
                image = entry_thumbs[-1]["url"] if entry_thumbs else None,
                explicit = None,
            ))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube: skipped a bad radio video: %r", e)
    return listings


async def get_artist(artist_id: str) -> ArtistDetail | None:
    """A channel's page: its videos, newest first (yt-dlp extract_flat on /channel/<id>/videos, ~1-2 s
    in a thread). No albums on this source; no bio either (that would mean parsing the About tab)."""
    return await asyncio.to_thread(get_artist_blocking, artist_id)


def get_artist_blocking(artist_id: str) -> ArtistDetail | None:
    """The blocking yt-dlp call, with its errors translated: None for a channel that does not exist."""
    opts = {"extract_flat" : True, "quiet" : True, "no_warnings" : True, "playlistend" : 20}
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/channel/{artist_id}/videos", download=False)
    except DownloadError as e:
        inner = e.exc_info[1] if e.exc_info else None
        # bot check first (same as extract_audio_url): the channel is fine, this IP is refused
        if "not a bot" in str(e):
            raise SourceBlocked("YouTube: bot check on this IP") from e
        # a channel that is not there: the extractor's own message, or the API refusing a
        # malformed id with 400/404 (measured 10 Oct: "UCxxx" → HTTP Error 400, not "does not exist")
        if (isinstance(inner, ExtractorError) and inner.expected) or "does not exist" in str(e) \
                or "HTTP Error 400" in str(e) or "HTTP Error 404" in str(e):
            return None
        raise SourceUnavailable(f"YouTube: {e}") from e
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
            songs.append(to_song([Listing(
                source = "youtube",
                id = entry["id"],
                title = entry["title"],          # raw, MUS-13: no keyword stripping
                artists = [channel] if channel else [],
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
    """Search plain YouTube's channels (the CHANNELS_ONLY params turn results into channelRenderer rows)."""
    body = {"context" : {"client" : CLIENT}, "query" : query, "params" : CHANNELS_ONLY}
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    artists = []
    for item in channel_rows(r):
        try:
            artists.append(artist_ref(item))
        except (KeyError, IndexError, ValueError, TypeError) as e:
            logger.warning("skipped a YouTube channel row for %r: %r", query, e)
    return artists


def channel_rows(response: dict) -> list[dict]:
    """Find the channelRenderer rows inside YouTube's search reply."""
    contents = (response.get("contents", {}).get("twoColumnSearchResultsRenderer", {})
                .get("primaryContents", {}).get("sectionListRenderer", {}).get("contents", []))
    rows = []
    for section in contents:
        for item in section.get("itemSectionRenderer", {}).get("contents", []):
            if "channelRenderer" in item:
                rows.append(item["channelRenderer"])
    return rows


def artist_ref(item: dict) -> ArtistRef:
    """Turn one channelRenderer row into an ArtistRef (the channel id opens the artist page).

    The title arrives as simpleText here (video rows use runs — both shapes are accepted).
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
    """Find the videoRenderer rows inside YouTube's deeply nested search reply.

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
    return Listing(
        source = "youtube",
        id = item["videoId"],
        title = title_of(item),
        artists = [channel_of(item)],
        # plain YouTube has no album information on a search row
        album = None,
        duration = to_seconds(item["lengthText"]["simpleText"]),
        popularity = views_of(item),
        image = artwork(item),
        explicit = is_explicit(item),
    )


def title_of(item: dict) -> str:
    """The video's title, raw: several runs are joined, nothing is stripped (MUS-13)."""
    return "".join(run["text"] for run in item["title"]["runs"])


def channel_of(item: dict) -> str:
    """The channel that uploaded the video (ownerText; shortBylineText is the same line in some rows)."""
    for key in ("ownerText", "shortBylineText"):
        runs = item.get(key, {}).get("runs", [])
        if runs:
            return runs[0]["text"]
    raise KeyError(key)


def artwork(item: dict) -> str | None:
    """The row's largest thumbnail (hq720 for ordinary search results)."""
    thumbnails = item.get("thumbnail", {}).get("thumbnails", [])
    if not thumbnails:
        return None
    return thumbnails[-1]["url"]


def views_of(item: dict) -> int | None:
    """'1,071,511,379 views' -> 1071511379, '1.2M views' -> 1200000. Missing or unparseable: None (never a broken row)."""
    text = (item.get("viewCountText", {}).get("simpleText")
            or item.get("shortViewCountText", {}).get("simpleText"))
    if not text:
        return None
    try:
        return to_count(text)
    except ValueError:
        return None


def is_explicit(item: dict) -> bool | None:
    """A badge when marked explicit; None when there is no badge (plain YouTube does not reliably badge,
    so absence means unknown, not clean)."""
    if any(b.get("metadataBadgeRenderer", {}).get("style") == "BADGE_STYLE_TYPE_EXPLICIT"
           for b in item.get("badges", [])):
        return True
    return None


def to_seconds(duration: str) -> int:
    """'3:22' -> 202, '1:02:03' -> 3723."""
    seconds = 0
    for part in duration.split(":"):
        seconds = seconds * 60 + int(part)
    return seconds


def to_count(text: str) -> int:
    """'1,071,511,379 views' -> 1071511379, '1.2M views' -> 1200000."""
    number = text.split()[0].replace(",", "")
    if number[-1] in VIEW_MULTIPLIER:
        return round(float(number[:-1]) * VIEW_MULTIPLIER[number[-1]])
    return int(number)


async def get_song_url(song_id: str) -> str:
    """Direct audio URL for a plain YouTube video id.

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
        # YouTube blocking this IP ("Sign in to confirm you're not a bot") is ALSO expected=True, but the video
        # is fine: the source is what's unavailable. Checked first, so it never becomes a 404.
        if "not a bot" in str(e):
            raise SourceBlocked("YouTube: bot check on this IP") from e
        if isinstance(inner, ExtractorError) and inner.expected:
            raise SongNotFound(song_id) from e
        raise SourceUnavailable(f"YouTube: {e}") from e
    return info["url"]


def is_expired(song_url: str) -> bool:
    # links are expected to have ?expire= format for expiry. If such an expiry cant be found, we simply assume
    # the link does not expire. In any case, the client can make a serve_fresh request if it turns out expired.
    expire = re.search(r'[?&]expire=(\d+)', song_url)
    if expire is None:
        return False
    return int(expire.group(1)) - int(time.time()) <= settings.youtube_cache_expiry_threshold * 60
