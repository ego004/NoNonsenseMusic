"""YouTube Music source: search, albums, artists, radio, and direct audio links."""

import asyncio
import functools
import logging
import re
import threading
import time
import requests
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError
from ytmusicapi import YTMusic
from ytmusicapi.exceptions import YTMusicServerError
from music_backend.core.settings import settings
from music_backend.models import AlbumDetail, AlbumRef, ArtistDetail, ArtistRef, Listing, SpotifyImportSong
from music_backend.services.matching import normalise, to_song
from music_backend.services.video_titles import parse_video_title, without_video_labels
from music_backend.core.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable
from music_backend.sources.youtube import VIDEO_ID

SEARCH_URL = "https://music.youtube.com/youtubei/v1/search"
WATCH_URL = "https://music.youtube.com/watch?v="
# yt-dlp picks one audio-only format and puts its direct link in info["url"].
# m4a (AAC) first: Apple's AVPlayer cannot play YouTube's default WebM/Opus; fall back to anything else
YTDLP_OPTIONS = {"format" : "bestaudio[ext=m4a]/bestaudio", "quiet" : True, "no_warnings" : True,
                 # a stray &list= in an id must never turn one song into a playlist walk
                 "noplaylist" : True}
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
    # TODO: a timeout on this POST raises rather than returning JSON; record which class it is and
    # whether a try/except around the request catches it.
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
    r = r.json()
    listings = []
    for item in song_rows(r):
        # one odd row (no playlistItemData) must not throw away the other 19
        try:
            listings.append(to_listing(item))
        except (KeyError, IndexError, ValueError) as e:
            logger.warning("skipped a YouTube Music row (query of %d characters): %r", len(query), e)
    return listings


# the top results a search can put first: a song, a music video, an upload. Not an artist, album or podcast episode
TOP_KINDS = {"MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC"}


async def top_result(query: str) -> Listing | None:
    """YouTube Music's own first choice (its unfiltered search's "Top result") when it is a song or video, else None.

    It reads typos, artist names and popularity, and finds a song that is there only as a music video: "pasoori" is
    Ali Sethi and Shae Gill's Coke Studio video, missing from the songs-only search (#25). One more request per search,
    sent alongside the others.
    """
    r = await http.client.post(SEARCH_URL, params = {"prettyPrint" : "false"},
                               json = {"context" : {"client" : CLIENT}, "query" : query})
    return top_listing(r.json())


def top_listing(response: dict) -> Listing | None:
    """The top-result card of an unfiltered search reply as a listing. Its subtitle reads "Song • Artist • 5:21" or
    "Video • Artist • 1B views • 4:37"."""
    tabs = response.get("contents", {}).get("tabbedSearchResultsRenderer", {}).get("tabs", [])
    sections = tabs[0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"] if tabs else []
    card = next((section["musicCardShelfRenderer"] for section in sections if "musicCardShelfRenderer" in section), None)
    watch = ((card or {}).get("onTap") or {}).get("watchEndpoint") or {}
    kind = watch.get("watchEndpointMusicSupportedConfigs", {}).get("watchEndpointMusicConfig", {}).get("musicVideoType")
    if kind not in TOP_KINDS or not watch.get("videoId"):
        return None
    parts = split_on_separator(card["subtitle"]["runs"])
    title, artists = named({"title" : card["title"]["runs"][0]["text"], "videoType" : kind,
                            "artists" : [{"name" : run["text"]} for run in parts[1] if run["text"] not in ARTIST_JOINERS]})
    return Listing(
        source = "ytmusic",
        id = watch["videoId"],
        title = title,
        artists = artists,
        album = None,
        duration = to_seconds(parts[-1][0]["text"]),
        popularity = to_count(parts[2][0]["text"]) if len(parts) == 4 else None,   # a video's views
        image = artwork(card),
        explicit = is_explicit(card),
    )


# Album and artist search go through ytmusicapi, whose parsers handle reply shapes that would
# otherwise be hand-parsed. Its calls block on requests, so each runs in a thread, with one client
# per thread: requests.Session is not thread-safe, and constructing a YTMusic performs no web
# request, so a client is never shared between threads.
_thread_local = threading.local()


# seconds: ytmusicapi's own sessions wait 30 s, so a slow YouTube Music held a search (it waits for every kind of
# result) and a thread of the shared pool that long. Its calls answer in about 1 s; the httpx sources wait 2-8 s.
REQUEST_TIMEOUT = 8


def client() -> YTMusic:
    """Return this thread's YTMusic client, creating it on first use."""
    if not hasattr(_thread_local, "yt"):
        session = requests.Session()
        session.request = functools.partial(session.request, timeout=REQUEST_TIMEOUT)   # ytmusicapi's documented way
        _thread_local.yt = YTMusic(requests_session=session)
    return _thread_local.yt


async def search_albums(query: str) -> list[AlbumRef]:
    """Search YouTube Music for albums (filter="albums"), running the blocking call in a thread."""
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
            logger.warning("YouTube Music: skipped a bad album row (query of %d characters): %r", len(query), e)
    return albums


async def search_artists(query: str) -> list[ArtistRef]:
    """Search YouTube Music for artists (filter="artists"), running the blocking call in a thread."""
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
            logger.warning("YouTube Music: skipped a bad artist row (query of %d characters): %r", len(query), e)
    return artists


def thumbnail_of(row: dict) -> str | None:
    """Return the largest thumbnail of a ytmusicapi row: thumbnails arrive smallest first."""
    thumbnails = row.get("thumbnails") or []
    return thumbnails[-1].get("url") if thumbnails else None


def thumb_url(thumbnails) -> str | None:
    """Return the largest thumbnail of a raw list (services/images.py asks for the full size); None if absent.

    Detail pages store thumbnails under different keys from search rows, hence this separate
    helper.
    """
    if not thumbnails:
        return None
    url = thumbnails[-1].get("url") if isinstance(thumbnails[-1], dict) else None
    return url or None


def int_or_none(value) -> int | None:
    """Parse a year or count that arrives as a string ("2020", "") or is missing; else None."""
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def count_or_none(text) -> int | None:
    """Parse a count such as '40.1M' into 40100000 (subscribers, monthly listeners); None if unparseable."""
    if not text:
        return None
    try:
        return to_count(str(text))
    except (ValueError, IndexError):
        return None


async def radio(source_id: str, limit: int = 25) -> list[Listing]:
    """Return the watch-playlist radio seeded from one video (ytmusicapi get_watch_playlist, in a thread): every track
    read, at least `limit` while the station has them, each video once.

    The reply's first track is the seed itself; the caller drops it. The station goes on in pages of ~50, a request
    each: ~150 distinct songs in its first 197, on the seed's language and genre to the end; the pages after the first
    repeat a few of its songs, and past ~200 it repeats itself (17 Oct, four seeds).
    """
    return await asyncio.to_thread(radio_blocking, source_id, limit)


def radio_blocking(source_id: str, limit: int) -> list[Listing]:
    try:
        d = client().get_watch_playlist(videoId = source_id, limit = limit)
    except (KeyError, YTMusicServerError):
        # unknown video: ytmusicapi answers "No content returned… RDAMVM<id>"
        return []
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    listings, seen = [], set()
    for row in d.get("tracks") or []:
        try:
            if not row.get("videoId") or not row.get("length") or row["videoId"] in seen:
                continue
            seen.add(row["videoId"])
            title, artists = named(row)
            listings.append(Listing(
                source = "ytmusic",
                id = row["videoId"],
                title = title,
                artists = artists,
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


def named(row: dict) -> tuple[str, list[str]]:
    """A watch-page or playlist row's song title and artists. YouTube Music names a song (ATV) itself. A music video (OMV)
    has its artist, and its video's labels in the title ("Blinding Lights (Official Video)"). An upload (UGC) shows the
    video's own title and channel, as plain YouTube does ("slipfunc - until dawn" by Ikigai, 13 Oct): read the same way.
    A music video's title is never split on a dash: "Kesariya - Brahmāstra" is a song from a film."""
    title = row["title"]
    artists = [a["name"] for a in row.get("artists") or [] if a.get("name")]
    match row.get("videoType"):
        case "MUSIC_VIDEO_TYPE_UGC":
            return parse_video_title(title, artists[0] if artists else "")
        case "MUSIC_VIDEO_TYPE_OMV":
            return without_video_labels(title), artists
    return title, artists


# ---------- for imports (services/spotify_import.py) ----------

async def import_track(video_id: str) -> Listing | None:
    """One video as a listing (ytmusicapi get_song, in a thread): what a YouTube export names only by its id."""
    return await asyncio.to_thread(import_track_blocking, video_id)


def import_track_blocking(video_id: str) -> Listing | None:
    # the watch page's first row, as radio reads it. get_song answers a data-centre address "Sign in to confirm you're
    # not a bot" (LOGIN_REQUIRED, no details): on the hosted server 92 of a 112-video playlist were lost that way (12 Oct)
    try:
        rows = client().get_watch_playlist(videoId=video_id, limit=1).get("tracks") or []
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    row = next((r for r in rows if r.get("videoId") == video_id), None)
    duration = to_seconds(row["length"]) if row and row.get("length") else 0
    if row is None or not row.get("title") or duration <= 0:
        logger.info("import: no details for a video")
        return None
    title, artists = named(row)
    return Listing(source="ytmusic", id=video_id, title=title, artists=artists, album=None,
                   duration=duration, popularity=None, image=thumb_url(row.get("thumbnail")), explicit=None)


async def import_playlist(playlist_id: str) -> tuple[str, list[SpotifyImportSong]] | None:
    """A public or unlisted playlist's title and songs, every one (ytmusicapi get_playlist, in a thread)."""
    return await asyncio.to_thread(import_playlist_blocking, playlist_id)


def import_playlist_blocking(playlist_id: str) -> tuple[str, list[SpotifyImportSong]] | None:
    try:
        p = client().get_playlist(playlist_id, limit=None)
    except KeyError:
        return None
    except Exception as e:
        raise SourceUnavailable(f"YouTube Music: {e}") from e
    songs = []
    for t in p.get("tracks") or []:
        if not t.get("videoId"):
            continue
        title, artists = named(t) if t.get("title") else ("", [])
        songs.append(SpotifyImportSong(title=title, artists=artists, youtube_id=t["videoId"],
                                       duration_ms=(t.get("duration_seconds") or 0) * 1000 or None))
    return (p.get("title") or "YouTube playlist", songs)


async def get_album(album_id: str) -> AlbumDetail | None:
    """Return one album's page as AlbumDetail, tracks in track order (ytmusicapi get_album, in a thread).

    Returns None for a browse id that does not exist: ytmusicapi's nav() raises KeyError there.
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
    album_cover = thumb_url(d.get("thumbnails"))   # album tracks carry no pictures of their own (measured 12 Oct)
    for row in d.get("tracks") or []:
        try:
            duration = row.get("duration_seconds")
            if not row.get("videoId") or not duration:
                logger.warning("YouTube Music: skipped album track %s without id/duration", row.get("videoId"))
                continue
            songs.append(to_song([Listing(
                source = "ytmusic",
                id = row["videoId"],
                title = row["title"],
                artists = [a["name"] for a in row.get("artists") or []] or album_artists,
                album = d["title"],
                duration = duration,
                popularity = to_count(row["views"]) if row.get("views") else None,
                image = thumb_url(row.get("thumbnails")) or album_cover,
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
                logger.warning("YouTube Music: no duration for %s: album fetch or title match failed",
                               row.get("videoId"))
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
    """The row's cover image (a 60/120 px search thumbnail: services/images.py asks for the full size)."""
    thumbnails = item.get("thumbnail", {}).get("musicThumbnailRenderer", {}).get("thumbnail", {}).get("thumbnails", [])
    if not thumbnails:
        return None
    return thumbnails[-1]["url"]


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
    # the id goes into a URL that yt-dlp fetches: only the characters a real video id has may reach it
    if not VIDEO_ID.fullmatch(song_id):
        raise SongNotFound(song_id)
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
    try:
        return info["url"]
    except (KeyError, TypeError) as e:     # yt-dlp answered with no playable format (or no info at all)
        raise SourceUnavailable("YouTube Music returned no audio URL") from e

def is_expired(song_url: str) -> bool:
    """links are expected to have ?expire= format for expiry. If such an expiry cant be found, we simply assume the link does not expire.
    in any case, the client can make a serve_fresh request if the link turns out to be expired."""
    expire = re.search(r'[?&]expire=(\d+)', song_url)
    if expire is None:
        return False
    return int(expire.group(1)) - int(time.time()) <= settings.youtube_cache_expiry_threshold * 60