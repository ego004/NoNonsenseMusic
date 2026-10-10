"""Pinned albums (MUS-20): a source's album becomes a playlist-shaped row you own, read-only after pinning.

The source is never asked over the network here: get_album on jiosaavn and ytmusic is stubbed per test
(plain YouTube has no get_album at all, which is exactly what its 404 exercises).
"""
from uuid import uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import AlbumDetail, Listing
from music_backend.services.matching import to_song
from music_backend.sources import SourceBlocked, SourceUnavailable, jiosaavn, ytmusic
from conftest import sign_up

TEST_URL = "postgresql:///music_test"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    async def no_album(album_id: str):
        return None
    monkeypatch.setattr(jiosaavn, "get_album", no_album)
    monkeypatch.setattr(ytmusic, "get_album", no_album)
    from music_backend.main import app
    with TestClient(app) as client:          # "with" runs the lifespan: pool + schema (the kind columns too)
        with psycopg.connect(TEST_URL) as conn:
            conn.execute("DELETE FROM playlists")      # every test starts with no playlists
        sign_up(client)
        yield client


def album_song(i: int):
    """Track i of the pinned album: one jiosaavn listing, score 0 (what a source's get_album returns)."""
    return to_song([Listing(source = "jiosaavn", id = f"pin{i}", title = f"Track {i}",
                            artists = ["The Weeknd"], album = "After Hours", duration = 200 + i,
                            popularity = 9, image = None, explicit = False)])


def the_album(tracks: int = 3, title: str = "After Hours") -> AlbumDetail:
    return AlbumDetail(source = "jiosaavn", id = "19531208", title = title, artists = ["The Weeknd"],
                       year = 2020, image = None, explicit = False,
                       songs = [album_song(i) for i in range(tracks)])


def set_album(monkeypatch, value = None, error = None):
    async def fake(album_id: str):
        if error is not None:
            raise error
        return value
    monkeypatch.setattr(jiosaavn, "get_album", fake)


def pin(client, source = "jiosaavn", source_id = "19531208"):
    return client.post("/albums/pin", json = {"source": source, "source_id": source_id})


def test_pin_stores_the_album_and_its_tracks_in_order(client, monkeypatch):
    set_album(monkeypatch, the_album())
    r = pin(client)
    assert r.status_code == 201
    body = r.json()
    assert body["kind"] == "album"
    assert body["source"] == "jiosaavn"
    assert body["source_id"] == "19531208"
    assert body["name"] == "After Hours"
    assert body["song_count"] == 3
    assert body["duration"] == 200 + 201 + 202
    assert body["role"] == "owner"
    assert body["public"] is False

    listed = client.get("/playlists").json()["playlists"]
    assert [(p["name"], p["kind"]) for p in listed] == [("After Hours", "album")]

    items = client.get(f"/playlists/{body['id']}").json()["items"]
    assert [i["song"]["title"] for i in items] == ["Track 0", "Track 1", "Track 2"]
    assert all(i["song"]["best"]["source"] == "jiosaavn" for i in items)


def test_pin_twice_answers_409_and_stores_nothing_new(client, monkeypatch):
    set_album(monkeypatch, the_album())
    assert pin(client).status_code == 201
    r = pin(client)
    assert r.status_code == 409
    assert r.json()["detail"] == "You already pinned this album"
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(*) FROM playlists").fetchone()[0] == 1
        assert conn.execute("SELECT count(*) FROM playlist_items").fetchone()[0] == 3


def test_a_different_album_with_the_same_title_pins_too(client, monkeypatch):
    set_album(monkeypatch, the_album(title = "After Hours"))
    assert pin(client).status_code == 201
    set_album(monkeypatch, the_album(tracks = 1, title = "After Hours"))
    r = pin(client, source_id = "other-album-id")
    assert r.status_code == 201
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(*) FROM playlists WHERE kind = 'album'").fetchone()[0] == 2


def test_plain_youtube_has_no_albums_to_pin(client):
    r = pin(client, source = "youtube", source_id = "UC0WP5P-ufpRfjbNrmOWwLBQ")
    assert r.status_code == 404
    assert r.json()["detail"] == "This source has no albums"


def test_an_unknown_album_answers_404(client):          # the fixture's get_album returns None
    r = pin(client, source_id = "made-up-id")
    assert r.status_code == 404
    assert r.json()["detail"] == "Album not found"


def test_an_album_with_no_tracks_answers_404(client, monkeypatch):
    set_album(monkeypatch, the_album(tracks = 0))
    r = pin(client)
    assert r.status_code == 404
    assert r.json()["detail"] == "Album not found"
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(*) FROM playlists").fetchone()[0] == 0


@pytest.mark.parametrize("error", [SourceUnavailable("down"), SourceBlocked("blocked")])
def test_a_source_that_is_down_answers_502(client, monkeypatch, error):
    set_album(monkeypatch, error = error)
    r = pin(client)
    assert r.status_code == 502
    assert r.json()["detail"] == "jiosaavn is unavailable right now"
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(*) FROM playlists").fetchone()[0] == 0


def test_pin_needs_a_session(client, monkeypatch):
    set_album(monkeypatch, the_album())
    client.headers.pop("Authorization")                    # sign_up sent its token with every request
    r = client.post("/albums/pin", json = {"source": "jiosaavn", "source_id": "19531208"})
    assert r.status_code == 401


@pytest.mark.parametrize("body", [{}, {"source": "jiosaavn"}, {"source": "deezer", "source_id": "x"}])
def test_pin_validates_its_body(client, body):
    assert client.post("/albums/pin", json = body).status_code == 422


def test_a_pinned_album_is_read_only(client, monkeypatch):
    set_album(monkeypatch, the_album())
    playlist_id = pin(client).json()["id"]

    renamed = client.patch(f"/playlists/{playlist_id}", json = {"name": "My Copy"})
    made_public = client.patch(f"/playlists/{playlist_id}", json = {"public": True})
    shared = client.put(f"/playlists/{playlist_id}/members", json = {"username": "nobodyatall", "role": "viewer"})
    added = client.post(f"/playlists/{playlist_id}/items",
                        json = {"listings": [{"source": "jiosaavn", "id": "extra", "title": "Extra",
                                              "artists": ["X"], "album": None, "duration": 100,
                                              "popularity": None}]})
    removed = client.delete(f"/playlists/{playlist_id}/items/{uuid4()}")
    moved = client.post(f"/playlists/{playlist_id}/items/{uuid4()}/move", json = {})

    for r in (renamed, made_public, shared, added, removed, moved):
        assert r.status_code == 400, r.text
        assert r.json()["detail"] == "This is a pinned album; delete it to unpin"
    with psycopg.connect(TEST_URL) as conn:
        row = conn.execute("SELECT name, public FROM playlists WHERE id = %s", [playlist_id]).fetchone()
        assert row == ("After Hours", False)            # nothing slipped through
        assert conn.execute("SELECT count(*) FROM playlist_items").fetchone()[0] == 3


def test_reading_a_pinned_album_still_works(client, monkeypatch):
    set_album(monkeypatch, the_album())
    playlist_id = pin(client).json()["id"]
    opened = client.get(f"/playlists/{playlist_id}")
    assert opened.status_code == 200
    assert opened.json()["kind"] == "album"
    members = client.get(f"/playlists/{playlist_id}/members")
    assert members.status_code == 200
    assert [(m["role"]) for m in members.json()] == ["owner"]     # its owner, and no one else


def test_deleting_a_pinned_album_unpins_it_and_the_songs_stay(client, monkeypatch):
    set_album(monkeypatch, the_album())
    playlist_id = pin(client).json()["id"]
    with psycopg.connect(TEST_URL) as conn:
        songs_before = conn.execute("SELECT count(*) FROM songs").fetchone()[0]

    assert client.delete(f"/playlists/{playlist_id}").status_code == 204

    assert client.get("/playlists").json()["playlists"] == []
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(*) FROM playlists").fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM playlist_items").fetchone()[0] == 0
        # unpinning keeps the stored songs, like deleting any playlist
        assert conn.execute("SELECT count(*) FROM songs").fetchone()[0] == songs_before


def test_a_pin_reuses_a_song_you_already_stored(client, monkeypatch):
    r = client.post("/events", json = {"listings": [{"source": "jiosaavn", "id": "pin0", "title": "Track 0",
                                                     "artists": ["The Weeknd"], "album": "After Hours",
                                                     "duration": 200, "popularity": None}],
                                       "type": "play", "position": 10})
    assert r.status_code == 200
    already = r.json()["song_id"]

    set_album(monkeypatch, the_album())
    items = client.get(f"/playlists/{pin(client).json()['id']}").json()["items"]
    assert items[0]["song"]["id"] == already              # the same stored song, not a second copy


def test_a_pin_and_a_playlist_may_share_a_name(client, monkeypatch):
    assert client.post("/playlists", json = {"name": "After Hours"}).status_code == 201
    set_album(monkeypatch, the_album())
    assert pin(client).status_code == 201                 # the old (user_id, name) constraint would have said 409
    kinds = [(p["name"], p["kind"]) for p in client.get("/playlists").json()["playlists"]]
    assert kinds == [("After Hours", "playlist"), ("After Hours", "album")]


def test_a_normal_playlist_stays_a_playlist(client):
    body = client.post("/playlists", json = {"name": "Gym"}).json()
    assert body["kind"] == "playlist"
    assert body["source"] is None
    assert body["source_id"] is None


def test_reordering_your_list_may_move_an_album(client, monkeypatch):
    gym_id = client.post("/playlists", json = {"name": "Gym"}).json()["id"]
    set_album(monkeypatch, the_album())
    album_id = pin(client).json()["id"]
    r = client.post(f"/playlists/{album_id}/move", json = {"top_neighbour_id": None,
                                                           "bottom_neighbour_id": gym_id})
    assert r.status_code == 204
    with psycopg.connect(TEST_URL) as conn:
        order = conn.execute("SELECT name FROM playlists ORDER BY position, id").fetchall()
    assert order == [("After Hours",), ("Gym",)]
