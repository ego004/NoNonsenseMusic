"""Playlist tests (MUS-2), through the real endpoints, against music_test (the real `music` is never touched)."""
import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend import db

TEST_URL = "postgresql:///music_test"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:          # "with" runs the lifespan (pool + schema) on music_test
        with psycopg.connect(TEST_URL) as conn:
            conn.execute("DELETE FROM playlists")          # every test starts with no playlists
        yield client


def positions():
    """Every playlist's name and position, in your order."""
    with psycopg.connect(TEST_URL) as conn:
        return conn.execute("SELECT name, position FROM playlists ORDER BY position").fetchall()


def create(client, name):
    return client.post("/playlists", json={"name": name})


def test_create_answers_201_with_an_empty_playlist(client):
    r = create(client, "Gym")
    assert r.status_code == 201
    body = r.json()
    assert body["name"] == "Gym"
    assert body["song_count"] == 0
    assert body["duration"] == 0
    assert body["thumbnail"] is None


def test_new_playlists_go_at_the_bottom(client):
    for name in ("Gym", "Chill", "Focus"):
        assert create(client, name).status_code == 201
    assert positions() == [("Gym", "a0"), ("Chill", "a1"), ("Focus", "a2")]


def test_a_name_in_use_answers_409_and_stores_nothing(client):
    create(client, "Gym")
    r = create(client, "Gym")
    assert r.status_code == 409
    assert r.json()["detail"] == "A playlist with this name already exists"
    assert positions() == [("Gym", "a0")]


def test_the_server_still_works_after_a_409(client):
    # the failed INSERT breaks its transaction; the connection must go back to the pool clean
    create(client, "Gym")
    create(client, "Gym")
    assert create(client, "Chill").status_code == 201
    assert positions() == [("Gym", "a0"), ("Chill", "a1")]


@pytest.mark.parametrize("body", [{"name": ""}, {}])
def test_an_empty_or_missing_name_answers_422(client, body):
    assert client.post("/playlists", json=body).status_code == 422
    assert positions() == []


def put_song(playlist_name, duration, position):
    """Puts a new song straight into a playlist with SQL (adding through the API is step 2)."""
    with psycopg.connect(TEST_URL) as conn:
        song_id = conn.execute(
            "INSERT INTO songs (title, artists, duration, normalised_title) VALUES ('Test', '{Tester}', %s, 'test') RETURNING id",
            [duration]).fetchone()[0]
        conn.execute(
            "INSERT INTO playlist_items (playlist_id, song_id, position) SELECT id, %s, %s FROM playlists WHERE name = %s",
            [song_id, position, playlist_name])


def test_no_playlists_is_an_empty_list(client):
    r = client.get("/playlists")
    assert r.status_code == 200
    assert r.json() == {"playlists": []}


def test_list_has_counts_and_durations_in_your_order(client):
    for name in ("Gym", "Chill", "Focus"):
        create(client, name)
    put_song("Gym", 200, "a0")
    put_song("Gym", 240, "a1")
    put_song("Focus", 180, "a0")
    playlists = client.get("/playlists").json()["playlists"]
    assert [(p["name"], p["song_count"], p["duration"]) for p in playlists] == [
        ("Gym", 2, 440), ("Chill", 0, 0), ("Focus", 1, 180)]      # Chill: the empty one in the middle


def test_the_same_song_twice_counts_twice(client):
    create(client, "Gym")
    put_song("Gym", 200, "a0")
    with psycopg.connect(TEST_URL) as conn:      # a second item for the same song
        conn.execute("""INSERT INTO playlist_items (playlist_id, song_id, position)
                        SELECT playlist_id, song_id, 'a1' FROM playlist_items""")
    p = client.get("/playlists").json()["playlists"][0]
    assert (p["song_count"], p["duration"]) == (2, 400)
