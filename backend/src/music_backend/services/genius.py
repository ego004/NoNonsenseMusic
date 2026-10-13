"""Return what Genius's annotations say about a song's lines and its "About" section: the description, who produced
it and what it samples. Notes only: Genius's lyrics text is never fetched or kept. The feature is experimental.

Genius's website has its own API, which needs no token: search, then the song's referents, about 3.4 s and 123 KB
per song, plus one request for the song's details. The API is undocumented and may change; when it fails, the
official API (api.genius.com, same data and shapes) answers instead, using GENIUS_ACCESS_TOKEN from backend/.env.
Without a token the official API answers 401, so the website's API stays in use until one is set. The apps ask once
per song and the server keeps the answer for everyone (GeniusCache in cache.py).
"""
import asyncio
import logging
import re

import httpx
from rapidfuzz import fuzz

from music_backend.core.http_client import SharedClient
from music_backend.core.settings import settings
from music_backend.models import GeniusAbout, GeniusNote, GeniusRequest, GeniusResponse
from music_backend.services.matching import normalise

WEBSITE = "https://genius.com/api"
OFFICIAL = "https://api.genius.com"
# A hit is this song when its title and artist are this close (0-100, rapidfuzz): another song's notes are worse
# than none.
TITLE_MATCH = 85
ARTIST_MATCH = 70
# "Song (feat. Someone)", "Song - Remastered 2011", "Song [Live]": titles are compared without these suffixes.
EXTRAS = re.compile(r"\s*[(\[].*?[)\]]|\s+-\s+.*$")

logger = logging.getLogger(__name__)
http = SharedClient(timeout=8, headers={"User-Agent": "NoNonsenseMusic (https://github.com/ego004/NoNonsenseMusic)"},
                    follow_redirects=True)


class GeniusUnavailable(Exception):
    """Neither API answered: nothing is known, so nothing is kept."""


async def find_notes(song: GeniusRequest) -> GeniusResponse:
    """Return the song's notes and About, or an empty answer when Genius has no such song.

    Raise GeniusUnavailable when neither API could be asked.
    """
    hit = best_hit(await search(f"{song.song_name} {song.artist_name}"), song)
    if hit is None:
        return GeniusResponse(url=None, notes=[], about=None)
    # the notes and the song's details at once: each is a round trip to Genius
    referents, details = await asyncio.gather(
        ask("/referents", {"song_id": hit["id"], "per_page": 50, "text_format": "plain"}),
        ask(f"/songs/{hit['id']}", {"text_format": "plain"}))
    return GeniusResponse(url=hit.get("url"), notes=notes(referents["referents"]), about=about(details["song"]))


async def search(query: str) -> list[dict]:
    """Return the songs among the search hits.

    The website's search spreads its hits over sections, so only the "song" section is read here; the official
    API's search lists the hits plainly.
    """
    try:
        response = await website("/search/song", {"q": query, "per_page": 5})
        return [hit["result"] for section in response["sections"] for hit in section["hits"]]
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        response = await official("/search", {"q": query}, because=e)
        return [hit["result"] for hit in response["hits"] if hit.get("type") == "song"]


async def ask(path: str, params: dict) -> dict:
    """Return the same path from either API, the website's first."""
    try:
        return await website(path, params)
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        return await official(path, params, because=e)


async def website(path: str, params: dict) -> dict:
    """Return the website API's response body for a path, or raise when the request fails."""
    r = await http.client.get(WEBSITE + path, params=params)
    r.raise_for_status()
    return r.json()["response"]


async def official(path: str, params: dict, because: Exception) -> dict:
    """Return the official API's response body, used when the website's API failed.

    Raise GeniusUnavailable when GENIUS_ACCESS_TOKEN is unset or the request fails.
    """
    token = settings.genius_access_token
    if not token:
        raise GeniusUnavailable(f"Genius's website API failed ({type(because).__name__}) and there is no GENIUS_ACCESS_TOKEN")
    logger.info("genius: the website's API failed (%s): the official API instead", type(because).__name__)
    try:
        r = await http.client.get(OFFICIAL + path, params=params, headers={"Authorization": f"Bearer {token}"})
        r.raise_for_status()
        return r.json()["response"]
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        raise GeniusUnavailable(f"both of Genius's APIs failed: {type(because).__name__}, then {type(e).__name__}") from e


def best_hit(hits: list[dict], song: GeniusRequest) -> dict | None:
    """Return the hit that is this song, or None rather than a guess.

    A hit qualifies when its title and its main artist are both close enough.
    """
    title, artist = plain(song.song_name), normalise(song.artist_name)
    best, best_score = None, 0
    for hit in hits:
        title_score = fuzz.ratio(plain(hit.get("title") or ""), title)
        hit_artist = normalise(((hit.get("primary_artist") or {}).get("name")) or "")
        # The artist asked for may appear inside a longer credit: "Arijit Singh" inside "Arijit Singh & Shreya
        # Ghoshal", which still counts as this song.
        artist_score = 100 if artist and artist in hit_artist else fuzz.ratio(hit_artist, artist)
        if title_score >= TITLE_MATCH and artist_score >= ARTIST_MATCH and title_score + artist_score > best_score:
            best, best_score = hit, title_score + artist_score
    return best


def plain(title: str) -> str:
    """Return the title with its suffixes removed and the rest normalised."""
    return normalise(EXTRAS.sub("", title))


def notes(referents: list[dict]) -> list[GeniusNote]:
    """Return one note per annotated fragment, taking its first annotation: Genius lists the accepted one first."""
    found = []
    for referent in referents:
        fragment = (referent.get("fragment") or "").strip()
        annotations = referent.get("annotations") or []
        text = (((annotations[0].get("body") or {}).get("plain")) or "").strip() if annotations else ""
        if fragment and text:
            found.append(GeniusNote(fragment=fragment, text=text, verified=bool(annotations[0].get("verified"))))
    return found


def about(song: dict) -> GeniusAbout:
    """Return the song's description, producers and sampled songs, taken from its details."""
    description = ((song.get("description") or {}).get("plain") or "").strip()
    samples = [s.get("full_title") or s.get("title") for relation in song.get("song_relationships") or []
               if relation.get("relationship_type") == "samples" for s in relation.get("songs") or []]
    return GeniusAbout(
        description=None if description in ("", "?") else description,    # Genius writes "?" when there is none
        produced_by=[a["name"] for a in song.get("producer_artists") or [] if a.get("name")],
        samples=[s for s in samples if s],
    )
