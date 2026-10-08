"""Genius notes (experimental, 8 Oct): what Genius's annotations say about a song's lines, and its "About" (the
description, who produced it, what it samples). Notes only: Genius's lyrics text is never fetched or kept.

Genius's website has its own API, needing no token (researched 8 Oct: search, then the song's referents, ~3.4 s and
~123 KB per song; the song's details add one request). It is undocumented, so it may change: then the official API
(api.genius.com, the same data and shapes) answers instead, with GENIUS_ACCESS_TOKEN from backend/.env. Without a
token the official API answers 401, so nothing changes until the owner adds one.
The apps ask once per song and the server keeps the answer for everyone (GeniusCache in cache.py).
"""
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
# a hit is this song when its title and artist are this close (0-100, rapidfuzz): another song's notes are worse
# than none
TITLE_MATCH = 85
ARTIST_MATCH = 70
# "Song (feat. Someone)", "Song - Remastered 2011", "Song [Live]": compared without them
EXTRAS = re.compile(r"\s*[(\[].*?[)\]]|\s+-\s+.*$")

logger = logging.getLogger(__name__)
http = SharedClient(timeout=8, headers={"User-Agent": "NoNonsenseMusic (https://github.com/ego004/NoNonsenseMusic)"},
                    follow_redirects=True)


class GeniusUnavailable(Exception):
    """Neither API answered: nothing is known, so nothing is kept."""


async def find_notes(song: GeniusRequest) -> GeniusResponse:
    """The song's notes and About, or an empty answer when Genius has no such song. GeniusUnavailable when it could
    not be asked."""
    hit = best_hit(await search(f"{song.song_name} {song.artist_name}"), song)
    if hit is None:
        return GeniusResponse(url=None, notes=[], about=None)
    referents = (await ask("/referents", {"song_id": hit["id"], "per_page": 50, "text_format": "plain"}))["referents"]
    details = (await ask(f"/songs/{hit['id']}", {"text_format": "plain"}))["song"]
    return GeniusResponse(url=hit.get("url"), notes=notes(referents), about=about(details))


async def search(query: str) -> list[dict]:
    """The hits' songs. The website's search lists them in sections (the "song" one only, here); the official one
    plainly."""
    try:
        response = await website("/search/song", {"q": query, "per_page": 5})
        return [hit["result"] for section in response["sections"] for hit in section["hits"]]
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        response = await official("/search", {"q": query}, because=e)
        return [hit["result"] for hit in response["hits"] if hit.get("type") == "song"]


async def ask(path: str, params: dict) -> dict:
    """The same path on either API: the website's first."""
    try:
        return await website(path, params)
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        return await official(path, params, because=e)


async def website(path: str, params: dict) -> dict:
    r = await http.client.get(WEBSITE + path, params=params)
    r.raise_for_status()
    return r.json()["response"]


async def official(path: str, params: dict, because: Exception) -> dict:
    token = settings.genius_access_token
    if not token:
        raise GeniusUnavailable(f"Genius's website API failed ({because!r}) and there is no GENIUS_ACCESS_TOKEN")
    logger.info("genius: the website's API failed (%r): the official API instead", because)
    try:
        r = await http.client.get(OFFICIAL + path, params=params, headers={"Authorization": f"Bearer {token}"})
        r.raise_for_status()
        return r.json()["response"]
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        raise GeniusUnavailable(f"both of Genius's APIs failed: {because!r}, then {e!r}") from e


def best_hit(hits: list[dict], song: GeniusRequest) -> dict | None:
    """The hit that is this song: its title and its main artist both close enough. None rather than a guess."""
    title, artist = plain(song.song_name), normalise(song.artist_name)
    best, best_score = None, 0
    for hit in hits:
        title_score = fuzz.ratio(plain(hit.get("title") or ""), title)
        hit_artist = normalise(((hit.get("primary_artist") or {}).get("name")) or "")
        # "Arijit Singh" asked, "Arijit Singh & Shreya Ghoshal" listed: the asked name inside the listed one counts
        artist_score = 100 if artist and artist in hit_artist else fuzz.ratio(hit_artist, artist)
        if title_score >= TITLE_MATCH and artist_score >= ARTIST_MATCH and title_score + artist_score > best_score:
            best, best_score = hit, title_score + artist_score
    return best


def plain(title: str) -> str:
    return normalise(EXTRAS.sub("", title))


def notes(referents: list[dict]) -> list[GeniusNote]:
    """One note per annotated fragment: its first annotation (Genius lists the accepted one first)."""
    found = []
    for referent in referents:
        fragment = (referent.get("fragment") or "").strip()
        annotations = referent.get("annotations") or []
        text = (((annotations[0].get("body") or {}).get("plain")) or "").strip() if annotations else ""
        if fragment and text:
            found.append(GeniusNote(fragment=fragment, text=text, verified=bool(annotations[0].get("verified"))))
    return found


def about(song: dict) -> GeniusAbout:
    description = ((song.get("description") or {}).get("plain") or "").strip()
    samples = [s.get("full_title") or s.get("title") for relation in song.get("song_relationships") or []
               if relation.get("relationship_type") == "samples" for s in relation.get("songs") or []]
    return GeniusAbout(
        description=None if description in ("", "?") else description,    # Genius writes "?" when there is none
        produced_by=[a["name"] for a in song.get("producer_artists") or [] if a.get("name")],
        samples=[s for s in samples if s],
    )
