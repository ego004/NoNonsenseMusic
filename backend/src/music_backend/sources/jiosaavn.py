import base64
import html
import json
import logging
import httpx
import pyDes
from pydantic import ValidationError
from music_backend.core.http_client import SharedClient
from music_backend.models import AlbumDetail, AlbumRef, ArtistDetail, ArtistRef, Listing
from music_backend.services.matching import to_song
from music_backend.sources import SongNotFound, SourceUnavailable, SourceBlocked

SEARCH_URL = "https://www.jiosaavn.com/api.php"
SEARCH_PARAMS = {"__call" : "search.getResults", "p" : 1, "n" : 20}
PREAMBLE_PARAMS = {"_format" : "json", "_marker" : "0", "api_version" : "4", "ctx" : "web6dot0"}
REQUEST_TIMEOUT = 2
URL_DECRYPTION_SECRET = b"38346591"

logger = logging.getLogger(__name__)
des_cipher = pyDes.des(URL_DECRYPTION_SECRET, pyDes.ECB, padmode=pyDes.PAD_PKCS5)
http = SharedClient(timeout = REQUEST_TIMEOUT)   # one connection to JioSaavn, reused by searches and song lookups

async def search(query: str) -> list[Listing]:
    """Search JioSaavn and return a list of listings.

    Each listing has: source, id, title, artists, album, duration (seconds), popularity.
    """
    r = await http.client.get(SEARCH_URL, params = SEARCH_PARAMS | PREAMBLE_PARAMS | {"q": query})
    r = r.json()
    listings = []
    for result in r.get("results", []):
        try:
            listings.append(to_listing(result))
        except (ValidationError, KeyError) as e:
            logger.warning(f"JioSaavn: skipped a bad result: {result!r}")
            continue
    return listings


async def search_albums(query: str) -> list[AlbumRef]:
    """Search JioSaavn's albums (search.getAlbumResults; search.getResults has no album type)."""
    params = {"__call" : "search.getAlbumResults", "p" : 1, "n" : 20} | PREAMBLE_PARAMS | {"q": query}
    r = await http.client.get(SEARCH_URL, params = params)
    r = r.json()
    albums = []
    for result in r.get("results", []):
        try:
            albums.append(album_ref(result))
        except (ValidationError, KeyError) as e:
            logger.warning(f"JioSaavn: skipped a bad album result: {result!r}")
            continue
    return albums


def album_ref(result: dict) -> AlbumRef:
    """Turn one search.getAlbumResults row into an AlbumRef."""
    # the track count lives in more_info.song_count ("14"); the top-level list_count said "0" (measured 10 Oct)
    info = result.get("more_info") or {}
    return AlbumRef(
        source = "jiosaavn",
        id = result["id"],
        title = html.unescape(result["title"]),
        # the subtitle is one string ("The Weeknd", sometimes "A, B"): kept as a single artist entry;
        # artists_match's word-set rule still matches it against another source's list
        artists = [html.unescape(result["subtitle"])] if result.get("subtitle") else [],
        year = int_or_none(result.get("year")),
        image = result["image"].replace("150x150", "500x500") if result.get("image") else None,
        song_count = int_or_none(info.get("song_count")),
        explicit = result["explicit_content"] == "1" if "explicit_content" in result else None,
    )


async def search_artists(query: str) -> list[ArtistRef]:
    """Search JioSaavn's artists (search.getArtistResults)."""
    params = {"__call" : "search.getArtistResults", "p" : 1, "n" : 20} | PREAMBLE_PARAMS | {"q": query}
    r = await http.client.get(SEARCH_URL, params = params)
    r = r.json()
    artists = []
    for result in r.get("results", []):
        try:
            artists.append(ArtistRef(
                source = "jiosaavn",
                id = result["id"],
                name = html.unescape(result["name"]),
                image = result["image"].replace("150x150", "500x500") if result.get("image") else None,
            ))
        except (ValidationError, KeyError) as e:
            logger.warning(f"JioSaavn: skipped a bad artist result: {result!r}")
            continue
    return artists


async def radio(source_id: str, limit: int = 25) -> list[Listing]:
    """A station seeded from one song: webradio.createEntityStation then webradio.getSong.

    The rows are exactly the search-row shape, so to_listing handles them. A made-up song id
    creates a station that answers with no songs (empty list, not an error).
    """
    try:
        station_reply = await http.client.get(SEARCH_URL, params = PREAMBLE_PARAMS | {
            "__call" : "webradio.createEntityStation", "entity_id" : json.dumps([source_id]),
            "entity_type" : "queue", "ctx" : "android"})
        if station_reply.status_code == 429:
            raise SourceBlocked("JioSaavn: Too many requests to JioSaavn's API. Status code: 429")
        elif station_reply.status_code != 200:
            raise SourceUnavailable("JioSaavn: unable to create radio station, returned status code " + str(station_reply.status_code))
        station_id = station_reply.json().get("stationid")
    except (httpx.HTTPError, ValueError) as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e
    if not station_id:
        return []

    try:
        songs_reply = await http.client.get(SEARCH_URL, params = PREAMBLE_PARAMS | {
            "__call" : "webradio.getSong", "stationid" : station_id, "k" : limit, "next" : 1, "ctx" : "android"})
        if songs_reply.status_code == 429:
            raise SourceBlocked("JioSaavn: Too many requests to JioSaavn's API. Status code: 429")
        elif songs_reply.status_code != 200:
            raise SourceUnavailable("JioSaavn: unable to get radio songs, returned status code " + str(songs_reply.status_code))
        reply = songs_reply.json()
    except (httpx.HTTPError, ValueError) as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e

    listings = []
    for entry in reply.values():
        # the reply is {"0": {"song": row}, "1": {"song": row}, ...}; non-dict values are not songs
        row = entry.get("song") if isinstance(entry, dict) else None
        if not row:
            continue
        try:
            listings.append(to_listing(row))
        except (ValidationError, KeyError, TypeError) as e:
            logger.warning("JioSaavn: skipped a bad radio song: %r", e)
    return listings


async def get_album(album_id: str) -> AlbumDetail | None:
    """One album's page (content.getAlbumDetails): metadata plus its tracks, in track order.

    None: JioSaavn answers 200 for a made-up id with title:"" and list:"" (empty strings, measured 10 Oct).
    """
    try:
        r = await http.client.get(SEARCH_URL, params = {"__call" : "content.getAlbumDetails", "albumid" : album_id} | PREAMBLE_PARAMS)
        if r.status_code == 429:
            raise SourceBlocked("JioSaavn: Too many requests to JioSaavn's API. Status code: 429")
        elif r.status_code != 200:
            raise SourceUnavailable("JioSaavn: unable to get album details, returned status code " + str(r.status_code))
        d = r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e

    rows = d.get("list") or []
    if not rows or not d.get("title"):
        return None
    songs = []
    for row in rows:
        try:
            songs.append(to_song([to_listing(row)]))
        except (ValidationError, KeyError, TypeError) as e:
            logger.warning("JioSaavn: skipped a bad album track: %r", e)
    if not songs:
        return None
    # explicit when the album or any track says so; the reply's own flag is the fallback
    explicit = (any(song.best.explicit for song in songs)
                or (d["explicit_content"] == "1" if "explicit_content" in d else None))
    return AlbumDetail(
        source = "jiosaavn",
        id = album_id,
        title = html.unescape(d["title"]),
        artists = [html.unescape(d["subtitle"])] if d.get("subtitle") else [],
        year = int_or_none(d.get("year")),
        image = d["image"].replace("150x150", "500x500") if d.get("image") else None,
        explicit = explicit,
        songs = songs,
    )


async def get_artist(artist_id: str) -> ArtistDetail | None:
    """One artist's page (artist.getArtistPageDetails): info, top songs and top albums.

    Works with the ids search.getArtistResults returns (measured 615155, The Weeknd); a bad id
    answers 200 with name:"" → None.
    """
    try:
        r = await http.client.get(SEARCH_URL, params = {"__call" : "artist.getArtistPageDetails", "artistId" : artist_id} | PREAMBLE_PARAMS)
        if r.status_code == 429:
            raise SourceBlocked("JioSaavn: Too many requests to JioSaavn's API. Status code: 429")
        elif r.status_code != 200:
            raise SourceUnavailable("JioSaavn: unable to get artist details, returned status code " + str(r.status_code))
        d = r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e

    if not d.get("name"):
        return None
    songs = []
    for row in d.get("topSongs") or []:
        try:
            songs.append(to_song([to_listing(row)]))
        except (ValidationError, KeyError, TypeError) as e:
            logger.warning("JioSaavn: skipped a bad top song: %r", e)
    albums = []
    for row in d.get("topAlbums") or []:
        try:
            albums.append(album_ref(row))
        except (ValidationError, KeyError, TypeError) as e:
            logger.warning("JioSaavn: skipped a bad top album: %r", e)
    return ArtistDetail(
        source = "jiosaavn",
        id = artist_id,
        name = html.unescape(d["name"]),
        image = d["image"].replace("150x150", "500x500") if d.get("image") else None,
        bio = artist_bio(d.get("bio")),
        followers = int_or_none(d.get("follower_count")),
        songs = songs,
        albums = albums,
    )


def artist_bio(raw) -> str | None:
    """The bio arrives as a JSON string of [{"text": ...}] pieces ('[]' when the artist has none)."""
    if not raw or not isinstance(raw, str):
        return None
    try:
        pieces = json.loads(raw)
        text = "\n".join(piece["text"] for piece in pieces if piece.get("text")).strip()
        return text or None
    except (ValueError, TypeError, KeyError, AttributeError):
        # not the expected JSON at all: show what was sent rather than nothing
        return raw


def int_or_none(value) -> int | None:
    """A count or year that arrives as a string ("2020", "") or is missing: parse it, else None."""
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def to_listing(result: dict) -> Listing:
    """Turn one raw JioSaavn search result into a Listing."""
    info = result["more_info"]
    return Listing(
        source = "jiosaavn",
        id = result["id"],
        # JioSaavn HTML-escapes text: 'From &quot;Aashiqui 2&quot;' -> 'From "Aashiqui 2"'
        title = html.unescape(result["title"]),
        # artistMap also lists featured artists and composers; only primary_artists are the singers
        artists = [html.unescape(artist["name"]) for artist in info["artistMap"]["primary_artists"]],
        album = html.unescape(info["album"]) or None,
        # both arrive as text ("200", "38250621"); Listing's int fields convert them
        duration = info["duration"],
        popularity = result.get("play_count") or None,
        # the search gives a 150x150 cover; the same URL with 500x500 is the large one
        image = result["image"].replace("150x150", "500x500") if result.get("image") else None,
        # "1" or "0"; missing would mean JioSaavn changed its reply: then unknown, not clean
        explicit = result["explicit_content"] == "1" if "explicit_content" in result else None,
    )

async def get_song_url(song_id: str, kbps : str = "320") -> str:
    """Direct audio URL for a JioSaavn song id (320 kbps AAC by default)."""
    try:
        r = await http.client.get(SEARCH_URL, params = {"__call" : "song.getDetails", "pids" : song_id} | PREAMBLE_PARAMS)
        if r.status_code == 429:
            raise SourceBlocked("JioSaavn: Too many requests to JioSaavn's API. Status code: 429")
        elif r.status_code != 200:
            raise SourceUnavailable("JioSaavn: unable to get song details, returned status code " + str(r.status_code))
        r = r.json()

    except (httpx.HTTPError, ValueError) as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e

    # a real id gives {"songs": [...]}; a made-up one gives {"status": ..., "msg": ...} with no "songs"
    if "songs" not in r or r["songs"] == []:
        raise SongNotFound(song_id)

    try:
        return decrypt_media_url(r["songs"][0]["more_info"]["encrypted_media_url"])[:-7] + "_" + kbps + ".mp4"
    except KeyError as e:
        raise SongNotFound(song_id) from e
    except ValueError as e:
        raise SourceUnavailable(f"JioSaavn: {e!r}") from e

def decrypt_media_url(encrypted: str) -> str:
    """Unwrap JioSaavn's encrypted_media_url, in reverse order of how it was wrapped.

    base64 text -> DES-encrypted bytes -> URL as bytes -> URL as text
    """
    encrypted_bytes = base64.b64decode(encrypted)
    url_bytes = des_cipher.decrypt(encrypted_bytes)
    return url_bytes.decode()

def is_expired(song_url: str) -> bool:
    #jioSaavn never expires
    return False