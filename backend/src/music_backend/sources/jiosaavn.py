import html

import httpx

from music_backend.models import Listing

SEARCH_URL = "https://www.jiosaavn.com/api.php"
SEARCH_PARAMS = {"__call" : "search.getResults", "p" : 1, "n" : 20, "_format" : "json", "_marker" : "0", "api_version" : "4", "ctx" : "web6dot0"}


async def search(query: str) -> list[Listing]:
    """Search JioSaavn and return a list of listings.

    Each listing has: source, id, title, artists, album, duration (seconds), popularity.
    """
    async with httpx.AsyncClient() as client:
        r = await client.get(SEARCH_URL, params = SEARCH_PARAMS | {"q": query})
        r = r.json()
        listings = []
        for result in r.get("results", []):
            listings.append(to_listing(result))
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
    )
