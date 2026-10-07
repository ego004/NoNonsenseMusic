import base64
import html
import logging
import httpx
import pyDes
from pydantic import ValidationError
from music_backend.http_client import SharedClient
from music_backend.models import Listing
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