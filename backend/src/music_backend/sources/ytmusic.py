import asyncio
import logging
import re
import threading
import time
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError
from ytmusicapi import YTMusic
from ytmusicapi.exceptions import YTMusicServerError
from music_backend.core.settings import settings
from music_backend.models import AlbumDetail, AlbumRef, ArtistDetail, ArtistRef, Listing
from music_backend.services.matching import normalise, to_song
from music_backend.core.http_client import SharedClient
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


# Album and artist search go through ytmusicapi (its parsers handle reply shapes we would otherwise
# hand-parse); its calls block (requests), so each runs in a thread. One client per thread: a
# requests.Session is not thread-safe, and a client is never shared between threads (no web request
# when made, measured 6 Oct).
_thread_local = threading.local()


def client() -> YTMusic:
    if not hasattr(_thread_local, "yt"):
        _thread_local.yt = YTMusic()
    return _thread_local.yt


async def search_albums(query: str) -> list[AlbumRef]:
    """YouTube Music's albums (filter="albums"), parsed by ytmusicapi in a thread."""
    return await asyncio.to_thread(search_albums_blocking, query)


def search_albums_blocking(query: str) -> list[AlbumRef]:
    albums = []
    for row in client().search(query, filter="albums", limit=20):
        try:
            albums.append(AlbumRef(
                source = "ytmusic",
                id = row["browseId"],
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []],
                year = row.get("year"),
                image = thumbnail_of(row),
                # the search reply carries no track count; the album page (Phase 3) will
                song_count = None,
                explicit = row.get("isExplicit"),
            ))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad album row for %r: %r", query, e)
    return albums


async def search_artists(query: str) -> list[ArtistRef]:
    """YouTube Music's artists (filter="artists"), parsed by ytmusicapi in a thread."""
    return await asyncio.to_thread(search_artists_blocking, query)


def search_artists_blocking(query: str) -> list[ArtistRef]:
    artists = []
    for row in client().search(query, filter="artists", limit=20):
        try:
            artists.append(ArtistRef(
                source = "ytmusic",
                id = row["browseId"],
                name = row.get("artist") or row["title"],
                image = thumbnail_of(row),
            ))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad artist row for %r: %r", query, e)
    return artists


def thumbnail_of(row: dict) -> str | None:
    """ytmusicapi's thumbnails are ordered smallest first: the last is the largest."""
    thumbnails = row.get("thumbnails") or []
    return thumbnails[-1].get("url") if thumbnails else None


def thumb_url(thumbnails) -> str | None:
    """Same, for a raw thumbnail list (detail pages put it in different keys), resized to 544 px."""
    if not thumbnails:
        return None
    url = thumbnails[-1].get("url") if isinstance(thumbnails[-1], dict) else None
    if not url:
        return None
    # the size lives in the URL itself: ...=w120-h120 → ...=w544-h544
    return re.sub(r"=w\d+-h\d+", "=w544-h544", url)


def int_or_none(value) -> int | None:
    """A year or count that arrives as a string ("2020", "") or is missing: parse it, else None."""
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def count_or_none(text) -> int | None:
    """'40.1M' -> 40100000 (subscribers, monthly listeners); unparseable → None."""
    if not text:
        return None
    try:
        return to_count(str(text))
    except (ValueError, IndexError):
        return None


async def radio(source_id: str, limit: int = 25) -> list[Listing]:
    """The watch-playlist radio seeded from one video (ytmusicapi get_watch_playlist, in a thread).

    The reply's first track is the seed itself; the caller drops it. Continuations are pointless:
    re-fetching with the playlistId returns the same 50, so the app re-seeds from the queue tail.
    """
    return await asyncio.to_thread(radio_blocking, source_id, limit)


def radio_blocking(source_id: str, limit: int) -> list[Listing]:
    try:
        d = client().get_watch_playlist(videoId = source_id, limit = limit)
    except (KeyError, YTMusicServerError):
        # unknown video: ytmusicapi answers "No content returned… RDAMVM<id>" (measured live)
        return []
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    listings = []
    # one extra track: the reply leads with the seed, which the endpoint drops
    for row in (d.get("tracks") or [])[: limit + 1]:
        try:
            if not row.get("videoId") or not row.get("length"):
                continue
            listings.append(Listing(
                source = "ytmusic",
                id = row["videoId"],
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []],
                album = (row.get("album") or {}).get("name"),
                duration = to_seconds(row["length"]),
                popularity = None,
                image = thumb_url(row.get("thumbnail")),   # watch-playlist rows say "thumbnail" (singular)
                # watch-playlist rows carry no isExplicit badge: unknown, not clean
                explicit = None,
            ))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad radio track: %r", e)
    return listings


async def get_album(album_id: str) -> AlbumDetail | None:
    """One album's page (ytmusicapi get_album, in a thread): tracks in track order.

    None: a browse id that does not exist makes ytmusicapi's nav() raise KeyError (measured).
    """
    return await asyncio.to_thread(get_album_blocking, album_id)


def get_album_blocking(album_id: str) -> AlbumDetail | None:
    try:
        d = client().get_album(album_id)
    except KeyError:
        return None
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    if not d.get("title"):
        return None
    album_artists = [a["name"] for a in d.get("artists") or []]
    songs = []
    for row in d.get("tracks") or []:
        try:
            duration = row.get("duration_seconds")
            if not row.get("videoId") or not duration:
                logger.warning("YouTube Music: skipped album track without id/duration: %r", row.get("title"))
                continue
            songs.append(to_song([Listing(
                source = "ytmusic",
                id = row["videoId"],
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []] or album_artists,
                album = d["title"],
                duration = duration,
                popularity = to_count(row["views"]) if row.get("views") else None,
                image = thumb_url(row.get("thumbnails")),
                explicit = row.get("isExplicit"),
            )]))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad album track: %r", e)
    # the album-level flag is often False while tracks are explicit: any track wins, else the flag
    explicit = any(song.best.explicit for song in songs) or d.get("isExplicit")
    return AlbumDetail(
        source = "ytmusic",
        id = album_id,
        title = d["title"],
        artists = album_artists,
        year = int_or_none(d.get("year")),
        image = thumb_url(d.get("thumbnails")),
        explicit = explicit,
        songs = songs,
    )


async def get_artist(artist_id: str) -> ArtistDetail | None:
    """One artist's page (ytmusicapi get_artist, in a thread): top songs, then albums and singles.

    The reply has NO duration on song rows (measured, even in the raw flexColumns), so each song's
    own album is fetched in parallel and its duration found by title match inside that album
    (5/5 exact on 10 Oct). A song whose album cannot be read gets duration 0 and a warning: the
    track still plays and prefills fine, only the display shows 0:00.
    """
    d = await asyncio.to_thread(get_artist_page, artist_id)
    if d is None:
        return None
    name = d["name"]

    song_rows_list = (d.get("songs") or {}).get("results") or []
    # the song's own album (row.album.id) is the only place its duration is known
    album_ids: list[str] = []
    for row in song_rows_list:
        album_id = (row.get("album") or {}).get("id")
        if album_id and album_id not in album_ids:
            album_ids.append(album_id)
    durations = dict(zip(album_ids, await asyncio.gather(*(asyncio.to_thread(album_durations, a) for a in album_ids))))

    songs = []
    for row in song_rows_list:
        try:
            album_id = (row.get("album") or {}).get("id")
            duration = durations.get(album_id, {}).get(normalise(row["title"])) if album_id else 0
            if not duration:
                logger.warning("YouTube Music: no duration for %r (%s): album fetch or title match failed",
                               row["title"], row.get("videoId"))
            songs.append(to_song([Listing(
                source = "ytmusic",
                id = row["videoId"],
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []] or [name],
                album = (row.get("album") or {}).get("name"),
                duration = duration or 0,
                popularity = None,
                image = thumb_url(row.get("thumbnails")),
                explicit = row.get("isExplicit"),
            )]))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad artist song: %r", e)

    # albums then singles, as one list; an id in both lists is shown once
    rows = list((d.get("albums") or {}).get("results") or []) + list((d.get("singles") or {}).get("results") or [])
    albums, seen = [], set()
    for row in rows:
        try:
            browse_id = row.get("browseId")
            if not browse_id or browse_id in seen:
                continue
            seen.add(browse_id)
            albums.append(AlbumRef(
                source = "ytmusic",
                id = browse_id,
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []] or [name],
                year = int_or_none(row.get("year")),
                image = thumb_url(row.get("thumbnails")),
                song_count = None,
                explicit = row.get("isExplicit"),
            ))
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("YouTube Music: skipped a bad artist album: %r", e)

    return ArtistDetail(
        source = "ytmusic",
        id = artist_id,
        name = name,
        image = thumb_url(d.get("thumbnails")),
        bio = d.get("description") or None,
        followers = count_or_none(d.get("subscribers")),
        monthly_listeners = count_or_none(d.get("monthlyListeners")),
        songs = songs,
        albums = albums,
    )


def get_artist_page(artist_id: str) -> dict | None:
    """The blocking get_artist call: None for a channel id that does not exist."""
    try:
        d = client().get_artist(artist_id)
    except KeyError:
        return None
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    if not d.get("name"):
        return None
    return d


def album_durations(album_id: str) -> dict[str, int]:
    """{normalised track title: duration_seconds} for one album — {} whenever it cannot be read."""
    try:
        page = get_album_blocking(album_id)
    except Exception as e:
        logger.warning("YouTube Music: no durations from album %s: %r", album_id, e)
        return {}
    if page is None:
        return {}
    return {normalise(song.title) : song.duration for song in page.songs}


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
        explicit = is_explicit(item),
    )


def is_explicit(item: dict) -> bool:
    """YouTube Music marks explicit songs with an E badge; a row without one is the clean (or only) version."""
    return any(badge.get("musicInlineBadgeRenderer", {}).get("icon", {}).get("iconType") == "MUSIC_EXPLICIT_BADGE"
               for badge in item.get("badges", []))


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
    """links are expected to have ?expire= format for expiry. If such an expiry cant be found, we simply assume the link does not expire.
    in any case, the client can make a serve_fresh request if the link turns out to be expired."""
    expire = re.search(r'[?&]expire=(\d+)', song_url)
    if expire is None:
        return False
    return int(expire.group(1)) - int(time.time()) <= settings.youtube_cache_expiry_threshold * 60