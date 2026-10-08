"""Genius notes (experimental, 8 Oct). Offline: Genius is a fake transport answering in the shapes of its website API
and its official API. Every word here is made up: real lyrics never go in the repo."""
from uuid import uuid4

import httpx
import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.core.http_client import SharedClient
from music_backend.core.settings import settings
from music_backend.models import GeniusRequest
from music_backend.services import genius
from conftest import TEST_URL, sign_up

HIT = {"id": 42, "title": "Made Up Song (Remastered)", "url": "https://genius.example/made-up-song",
       "primary_artist": {"name": "Kai & The Testers"}}
OTHER = {"id": 7, "title": "A Different Song", "url": "https://genius.example/other", "primary_artist": {"name": "Sam"}}
REFERENTS = {"referents": [
    {"fragment": "first made-up line", "annotations": [{"body": {"plain": "A note on the first line."}, "verified": True}]},
    {"fragment": "second made-up line", "annotations": [{"body": {"plain": "A note on the second."}}]},
    {"fragment": "a line nobody explained", "annotations": []},
]}
SONG = {"song": {"description": {"plain": "A song written for these tests."},
                 "producer_artists": [{"name": "Alex"}],
                 "song_relationships": [{"relationship_type": "samples", "songs": [{"full_title": "Older Song by Sam"}]},
                                        {"relationship_type": "covered_by", "songs": [{"full_title": "Not a sample"}]}]}}


@pytest.fixture
def fake_genius(monkeypatch):
    """What each API answers; records every request. `website` False: the website's API answers 500."""
    state = {"website": True, "hits": [HIT], "requests": []}

    def handler(request: httpx.Request):
        state["requests"].append(request)
        official = request.url.host == "api.genius.com"
        if not official and not state["website"]:
            return httpx.Response(500)
        if official and request.headers.get("authorization") != "Bearer a test token":
            return httpx.Response(401)
        path = request.url.path.removeprefix("/api")
        if path in ("/search/song", "/search"):
            hits = [{"type": "song", "result": h} for h in state["hits"]]
            body = {"hits": hits} if official else {"sections": [{"type": "song", "hits": hits}]}
        elif path == "/referents":
            body = REFERENTS
        elif path == "/songs/42":
            body = SONG
        else:
            return httpx.Response(404)
        return httpx.Response(200, json={"meta": {"status": 200}, "response": body})
    monkeypatch.setattr(genius, "http", SharedClient(transport=httpx.MockTransport(handler)))
    return state


def song(name="Made Up Song", artist="Kai"):
    return GeniusRequest(song_name=name, artist_name=artist)


@pytest.mark.anyio
async def test_notes_and_about_from_the_website_api_and_never_the_lyrics(fake_genius):
    reply = await genius.find_notes(song())
    assert [(n.fragment, n.text, n.verified) for n in reply.notes] == [
        ("first made-up line", "A note on the first line.", True), ("second made-up line", "A note on the second.", False)]
    assert reply.about.description == "A song written for these tests."
    assert (reply.about.produced_by, reply.about.samples) == (["Alex"], ["Older Song by Sam"])
    assert reply.url == HIT["url"]
    paths = [r.url.path for r in fake_genius["requests"]]
    assert paths == ["/api/search/song", "/api/referents", "/api/songs/42"], "search, notes, about: no lyrics page"
    assert all(r.url.host == "genius.com" for r in fake_genius["requests"]), "no token needed while the website answers"


@pytest.mark.anyio
async def test_another_songs_notes_are_never_taken(fake_genius):
    fake_genius["hits"] = [OTHER]
    reply = await genius.find_notes(song())
    assert (reply.url, reply.notes, reply.about) == (None, [], None)
    assert len(fake_genius["requests"]) == 1, "nothing asked about a song that is not this one"


@pytest.mark.anyio
async def test_the_official_api_with_the_token_when_the_website_api_breaks(fake_genius, monkeypatch):
    fake_genius["website"] = False
    monkeypatch.setattr(settings, "genius_access_token", None)
    with pytest.raises(genius.GeniusUnavailable):
        await genius.find_notes(song())
    monkeypatch.setattr(settings, "genius_access_token", "a test token")
    reply = await genius.find_notes(song())
    assert len(reply.notes) == 2
    assert {r.url.host for r in fake_genius["requests"] if r.headers.get("authorization")} == {"api.genius.com"}


def test_the_route_asks_genius_once_for_everyone_and_keeps_no_failure(fake_genius, monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    monkeypatch.setattr(settings, "genius_access_token", None)
    asked = {"song_name": f"Made Up Song {uuid4().hex[:6]}", "artist_name": "Kai"}
    fake_genius["hits"] = [dict(HIT, title=asked["song_name"])]
    with TestClient(app) as client:
        assert client.post("/genius", json=asked).status_code == 401, "signed in only, as every route"
        sign_up(client)
        fake_genius["website"] = False
        r = client.post("/genius", json=asked)
        assert (r.status_code, r.json()["detail"]) == (502, "Genius is unavailable right now")
        fake_genius["website"] = True
        assert len(client.post("/genius", json=asked).json()["notes"]) == 2, "a failure was not kept: asked again"
        sign_up(client)                                    # someone else, the same song
        before = len(fake_genius["requests"])
        assert len(client.post("/genius", json=asked).json()["notes"]) == 2
        assert len(fake_genius["requests"]) == before, "kept for everyone: Genius not asked again"
    with psycopg.connect(TEST_URL) as conn:              # the cache kept this answer: remove it
        conn.execute("DELETE FROM genius WHERE song_name = %s", [asked["song_name"]])
