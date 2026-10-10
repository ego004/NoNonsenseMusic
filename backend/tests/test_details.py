"""GET /album and GET /artist through the real endpoints (MUS-20): shapes, status codes, limits.

No network: every source's get_album / get_artist is replaced. Plain YouTube never gets a
get_album stub — that module must keep having no such attribute, or the 404 branch breaks.
"""
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import AlbumDetail, AlbumRef, ArtistDetail, Listing
from music_backend.services.matching import to_song
from music_backend.sources import SourceBlocked, SourceUnavailable, jiosaavn, ytmusic, youtube
from conftest import sign_up

TEST_URL = "postgresql:///music_test"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    # default: every source has nothing to show, so no test can accidentally reach the network
    for module in (jiosaavn, ytmusic):                 # plain YouTube must never grow a get_album
        monkeypatch.setattr(module, "get_album", no_album)
    for module in (jiosaavn, ytmusic, youtube):
        monkeypatch.setattr(module, "get_artist", no_artist)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        yield client


async def no_album(album_id: str):
    return None


async def no_artist(artist_id: str):
    return None


def set_get(monkeypatch, module, name, value=None, error=None):
    async def fake(id: str):
        if error is not None:
            raise error
        return value
    monkeypatch.setattr(module, name, fake)


def album_song(id, title, duration):
    return to_song([Listing(source="jiosaavn", id=id, title=title, artists=["The Weeknd"],
                            album="After Hours", duration=duration, popularity=None)])


def artist_song(id, title, duration):
    return to_song([Listing(source="ytmusic", id=id, title=title, artists=["The Weeknd"],
                            album="After Hours", duration=duration, popularity=None)])


def the_weeknd() -> ArtistDetail:
    return ArtistDetail(source="ytmusic", id="UC1", name="The Weeknd", image="https://x/i.jpg",
                        bio="Canadian singer.", followers=40100000, monthly_listeners=240000000,
                        songs=[artist_song("v1", "Save Your Tears", 216)],
                        albums=[AlbumRef(source="ytmusic", id="MPREb_1", title="After Hours",
                                         artists=["The Weeknd"], year=2020)])


# ---------- the happy paths ----------

def test_album_returns_its_tracks_in_order(client, monkeypatch):
    album = AlbumDetail(source="jiosaavn", id="19531208", title="After Hours", artists=["The Weeknd"],
                        year=2020, image="https://x/cover.jpg", explicit=True,
                        songs=[album_song("t1", "Alone Again", 240),
                               album_song("t2", "Blinding Lights", 200)])
    set_get(monkeypatch, jiosaavn, "get_album", value=album)

    r = client.get("/album/jiosaavn/19531208")
    assert r.status_code == 200
    body = r.json()
    assert (body["source"], body["id"], body["title"], body["artists"], body["year"]) == (
        "jiosaavn", "19531208", "After Hours", ["The Weeknd"], 2020)
    assert body["explicit"] is True
    # track order preserved; ordinary playable songs: score 0, one listing each
    assert [s["title"] for s in body["songs"]] == ["Alone Again", "Blinding Lights"]
    assert all(s["score"] == 0 and len(s["listings"]) == 1 for s in body["songs"])
    assert body["songs"][0]["best"]["source"] == "jiosaavn"
    assert body["songs"][0]["duration"] == 240


def test_artist_returns_info_songs_and_albums(client, monkeypatch):
    set_get(monkeypatch, ytmusic, "get_artist", value=the_weeknd())

    r = client.get("/artist/ytmusic/UC1")
    assert r.status_code == 200
    body = r.json()
    assert (body["source"], body["id"], body["name"]) == ("ytmusic", "UC1", "The Weeknd")
    assert body["bio"] == "Canadian singer."
    assert body["followers"] == 40100000 and body["monthly_listeners"] == 240000000
    assert [s["title"] for s in body["songs"]] == ["Save Your Tears"]
    assert body["songs"][0]["score"] == 0 and body["songs"][0]["duration"] == 216
    assert [a["id"] for a in body["albums"]] == ["MPREb_1"]


def test_youtube_artist_page_answers_too(client, monkeypatch):
    # every source has artist pages (a channel counts), even the one with no albums
    set_get(monkeypatch, youtube, "get_artist",
            value=ArtistDetail(source="youtube", id="UC1", name="The Weeknd",
                               songs=[to_song([Listing(source="youtube", id="v1",
                                                       title="The Weeknd - Blinding Lights (Official Video)",
                                                       artists=["The Weeknd"], album=None,
                                                       duration=263, popularity=1000)])]))
    body = client.get("/artist/youtube/UC1").json()
    assert body["name"] == "The Weeknd"
    assert body["songs"][0]["title"] == "The Weeknd - Blinding Lights (Official Video)"   # raw


# ---------- the status codes ----------

def test_plain_youtube_has_no_albums_404(client):
    r = client.get("/album/youtube/UC1")
    assert r.status_code == 404
    assert r.json()["detail"] == "This source has no albums"


def test_an_unknown_source_is_rejected_before_the_source_is_asked(client):
    assert client.get("/album/deezer/x").status_code == 422            # not in SourceName
    assert client.get("/artist/deezer/x").status_code == 422


def test_an_album_the_source_does_not_have_is_404(client):
    # the default stub answers None = "no such album"
    r = client.get("/album/jiosaavn/nonsense")
    assert r.status_code == 404 and r.json()["detail"] == "Album not found"


def test_an_artist_the_source_does_not_have_is_404(client):
    r = client.get("/artist/ytmusic/UCnonsense")
    assert r.status_code == 404 and r.json()["detail"] == "Artist not found"


def test_an_unreachable_source_is_502(client, monkeypatch):
    set_get(monkeypatch, jiosaavn, "get_album", error=SourceUnavailable("jiosaavn timed out"))
    set_get(monkeypatch, ytmusic, "get_artist", error=SourceUnavailable("ytmusic timed out"))
    album = client.get("/album/jiosaavn/19531208")
    artist = client.get("/artist/ytmusic/UC1")
    assert album.status_code == artist.status_code == 502
    assert album.json()["detail"] == "jiosaavn is unavailable right now"


def test_a_rate_limited_source_is_502_too(client, monkeypatch):
    # SourceBlocked subclasses SourceUnavailable: /play answers 502, these do the same
    set_get(monkeypatch, jiosaavn, "get_album", error=SourceBlocked("429"))
    assert client.get("/album/jiosaavn/19531208").status_code == 502


def test_both_endpoints_still_require_an_account(client):
    client.headers.pop("Authorization")
    assert client.get("/album/jiosaavn/1").status_code == 401
    assert client.get("/artist/ytmusic/UC1").status_code == 401


def test_the_album_endpoint_is_rate_limited_per_account(client, monkeypatch):
    # LIMITS says 60/min: each album page makes the server ask a source for a full track list
    for _ in range(60):
        assert client.get("/album/jiosaavn/19531208").status_code == 404
    r = client.get("/album/jiosaavn/19531208")
    assert r.status_code == 429
    assert r.headers.get("retry-after")
