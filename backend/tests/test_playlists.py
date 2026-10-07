"""Playlist tests (MUS-2), through the real endpoints, against music_test (the real `music` is never touched)."""
import asyncio
from uuid import UUID, uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend import db, library
from music_backend.models import Listing

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


# ---------- step 2: add ----------

def listings(title, duration=200):
    """One JioSaavn listing with a fresh id and a title of its own, so every call is a new song."""
    tag = uuid4().hex[:8]
    return {"listings": [{"source": "jiosaavn", "id": f"test-{tag}", "title": f"{title} {tag}", "artists": ["Tester"],
                          "album": None, "duration": duration, "popularity": None, "image": None}]}


def items(playlist_id):
    """(item id, song id) of every item, in playlist order."""
    with psycopg.connect(TEST_URL) as conn:
        return conn.execute("SELECT id, song_id FROM playlist_items WHERE playlist_id = %s ORDER BY position, id",
                            [playlist_id]).fetchall()


def test_added_songs_go_at_the_bottom_in_order(client):
    gym = create(client, "Gym").json()["id"]
    refs = []
    for title, duration in (("One", 200), ("Two", 240), ("Three", 180)):
        r = client.post(f"/playlists/{gym}/items", json=listings(title, duration))
        assert r.status_code == 201
        refs.append((UUID(r.json()["item_id"]), UUID(r.json()["song_id"])))
    assert items(gym) == refs                                    # the reply's ids are the stored rows, in add order
    p = client.get("/playlists").json()["playlists"][0]
    assert (p["song_count"], p["duration"]) == (3, 620)


def test_the_same_song_added_twice_is_two_items(client):
    gym = create(client, "Gym").json()["id"]
    song = listings("Twice")
    first = client.post(f"/playlists/{gym}/items", json=song).json()
    second = client.post(f"/playlists/{gym}/items", json=song).json()
    assert first["song_id"] == second["song_id"]
    assert first["item_id"] != second["item_id"]
    assert len(items(gym)) == 2


def song_count():
    with psycopg.connect(TEST_URL) as conn:
        return conn.execute("SELECT count(*) FROM songs").fetchone()[0]


def test_adding_to_an_unknown_playlist_answers_404(client):
    before = song_count()
    r = client.post(f"/playlists/{uuid4()}/items", json=listings("Lost"))
    assert r.status_code == 404
    assert r.json()["detail"] == "Playlist not found"
    assert song_count() == before                                # one transaction: the song resolve_song made is undone too
    gym = create(client, "Gym").json()["id"]                     # the failed insert left the server working
    assert client.post(f"/playlists/{gym}/items", json=listings("After")).status_code == 201


@pytest.mark.parametrize("path, body", [
    ("/playlists/not-a-uuid/items", None),                       # a malformed id
    (None, {"listings": []}),                                    # no listings
])
def test_bad_input_answers_422(client, path, body):
    gym = create(client, "Gym").json()["id"]
    r = client.post(path or f"/playlists/{gym}/items", json=body or listings("Bad"))
    assert r.status_code == 422
    assert items(gym) == []


# ---------- step 2: open ----------

def add(client, playlist_id, body):
    return client.post(f"/playlists/{playlist_id}/items", json=body).json()


def test_open_shows_the_songs_in_order_with_the_metadata(client):
    gym = create(client, "Gym").json()["id"]
    refs = [add(client, gym, listings(title, duration)) for title, duration in (("One", 200), ("Two", 240), ("Three", 180))]
    r = client.get(f"/playlists/{gym}")
    assert r.status_code == 200
    p = r.json()
    assert (p["id"], p["name"], p["song_count"], p["duration"], p["thumbnail"]) == (gym, "Gym", 3, 620, None)
    assert [(i["item_id"], i["song"]["id"]) for i in p["items"]] == [(ref["item_id"], ref["song_id"]) for ref in refs]
    assert [i["song"]["title"].split()[0] for i in p["items"]] == ["One", "Two", "Three"]
    song = p["items"][0]["song"]                                 # each song arrives playable: its best copy and every copy
    assert song["best"]["source"] == "jiosaavn" and len(song["listings"]) == 1


def test_open_an_empty_playlist(client):
    gym = create(client, "Gym").json()["id"]
    p = client.get(f"/playlists/{gym}").json()
    assert (p["song_count"], p["duration"], p["items"]) == (0, 0, [])


def test_open_shows_a_song_added_twice_as_two_items(client):
    gym = create(client, "Gym").json()["id"]
    song = listings("Twice")
    first, second = add(client, gym, song), add(client, gym, song)
    items_ = client.get(f"/playlists/{gym}").json()["items"]
    assert [i["item_id"] for i in items_] == [first["item_id"], second["item_id"]]
    assert items_[0]["song"]["id"] == items_[1]["song"]["id"]


def test_open_marks_liked_songs(client):
    gym = create(client, "Gym").json()["id"]
    liked, plain = listings("Liked"), listings("Plain")
    add(client, gym, liked)
    add(client, gym, plain)
    client.post("/liked", json=liked)
    assert [i["song"]["liked"] for i in client.get(f"/playlists/{gym}").json()["items"]] == [True, False]


def test_a_shared_position_still_has_a_stable_order(client):
    # two adds at the same moment can compute the same position; the item id (UUIDv7, time-ordered) breaks the tie
    gym = create(client, "Gym").json()["id"]
    first, second = add(client, gym, listings("First")), add(client, gym, listings("Second"))
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("UPDATE playlist_items SET position = 'a0' WHERE playlist_id = %s", [gym])
    assert [i["item_id"] for i in client.get(f"/playlists/{gym}").json()["items"]] == [first["item_id"], second["item_id"]]


def test_open_an_unknown_or_malformed_id(client):
    assert client.get(f"/playlists/{uuid4()}").status_code == 404
    assert client.get("/playlists/not-a-uuid").status_code == 422


# ---------- step 3: rename, delete, remove ----------

def test_rename_keeps_the_songs(client):
    gym = create(client, "Gym").json()["id"]
    add(client, gym, listings("One", 200))
    r = client.patch(f"/playlists/{gym}", json={"name": "Workout"})
    assert r.status_code == 200
    assert (r.json()["name"], r.json()["song_count"], r.json()["duration"]) == ("Workout", 1, 200)
    assert [p["name"] for p in client.get("/playlists").json()["playlists"]] == ["Workout"]


def test_rename_errors(client):
    gym = create(client, "Gym").json()["id"]
    create(client, "Chill")
    assert client.patch(f"/playlists/{gym}", json={"name": "Chill"}).status_code == 409      # taken
    assert client.patch(f"/playlists/{gym}", json={"name": ""}).status_code == 422
    assert client.patch(f"/playlists/{uuid4()}", json={"name": "New"}).status_code == 404
    assert client.patch(f"/playlists/{gym}", json={"name": "Gym"}).status_code == 200        # its own name is fine
    assert [p["name"] for p in client.get("/playlists").json()["playlists"]] == ["Gym", "Chill"]


def test_delete_removes_the_items_but_not_the_songs(client):
    gym = create(client, "Gym").json()["id"]
    refs = [add(client, gym, listings(t)) for t in ("One", "Two", "Three")]
    assert client.delete(f"/playlists/{gym}").status_code == 204
    assert items(gym) == []
    with psycopg.connect(TEST_URL) as conn:
        kept = conn.execute("SELECT count(*) FROM songs WHERE id = ANY(%s)", [[UUID(r["song_id"]) for r in refs]]).fetchone()[0]
    assert kept == 3
    assert client.get(f"/playlists/{gym}").status_code == 404
    assert client.delete(f"/playlists/{gym}").status_code == 404                              # already gone


def test_remove_takes_out_one_item_only(client):
    gym = create(client, "Gym").json()["id"]
    song = listings("Twice")
    first, second = add(client, gym, song), add(client, gym, song)
    assert client.delete(f"/playlists/{gym}/items/{first['item_id']}").status_code == 204
    assert items(gym) == [(UUID(second["item_id"]), UUID(second["song_id"]))]                 # the other copy stays


def test_remove_checks_the_item_belongs_to_the_playlist(client):
    gym, chill = create(client, "Gym").json()["id"], create(client, "Chill").json()["id"]
    in_chill = add(client, chill, listings("Chill song"))
    assert client.delete(f"/playlists/{gym}/items/{in_chill['item_id']}").status_code == 404  # Gym's URL, Chill's item
    assert len(items(chill)) == 1
    assert client.delete(f"/playlists/{gym}/items/{uuid4()}").status_code == 404


# ---------- step 4: move ----------

def all_positions(table):
    with psycopg.connect(TEST_URL) as conn:
        return dict(conn.execute(f"SELECT id, position FROM {table}").fetchall())


def order(client, playlist_id):
    return [i["song"]["title"].split()[0] for i in client.get(f"/playlists/{playlist_id}").json()["items"]]


def abc(client):
    gym = create(client, "Gym").json()["id"]
    return gym, {t: add(client, gym, listings(t))["item_id"] for t in ("A", "B", "C")}


def move(client, gym, item, top=None, bottom=None):
    return client.post(f"/playlists/{gym}/items/{item}/move", json={"top_neighbour_id": top, "bottom_neighbour_id": bottom})


@pytest.mark.parametrize("moved, top, bottom, expected", [
    ("C", None, "A", ["C", "A", "B"]),          # to the top
    ("A", "B", "C", ["B", "A", "C"]),           # between two
    ("A", "C", None, ["B", "C", "A"]),          # to the bottom
])
def test_move_changes_exactly_one_row(client, moved, top, bottom, expected):
    gym, ids = abc(client)
    before = all_positions("playlist_items")
    r = move(client, gym, ids[moved], ids.get(top), ids.get(bottom))
    assert r.status_code == 204
    assert order(client, gym) == expected
    after = all_positions("playlist_items")
    assert [k for k in before if before[k] != after[k]] == [UUID(ids[moved])]


def test_move_errors_change_nothing(client):
    gym, ids = abc(client)
    chill = create(client, "Chill").json()["id"]
    elsewhere = add(client, chill, listings("Elsewhere"))["item_id"]
    before = all_positions("playlist_items")
    assert move(client, gym, ids["A"], top=elsewhere).status_code == 404                    # neighbour from another playlist
    assert move(client, gym, uuid4(), top=ids["A"]).status_code == 404                      # no such item
    assert move(client, gym, ids["A"], top=ids["C"], bottom=ids["B"]).status_code == 422    # wrong order
    assert move(client, gym, ids["A"], top=ids["A"]).status_code == 422                     # its own neighbour
    assert move(client, gym, ids["A"]).status_code == 204                                   # no neighbours: stays put
    assert all_positions("playlist_items") == before


def test_moving_playlists_reorders_the_list(client):
    gym, chill, focus = (create(client, n).json()["id"] for n in ("Gym", "Chill", "Focus"))
    before = all_positions("playlists")
    r = client.post(f"/playlists/{focus}/move", json={"bottom_neighbour_id": gym})
    assert r.status_code == 204
    assert [p["name"] for p in client.get("/playlists").json()["playlists"]] == ["Focus", "Gym", "Chill"]
    after = all_positions("playlists")
    assert [k for k in before if before[k] != after[k]] == [UUID(focus)]
    assert client.post(f"/playlists/{uuid4()}/move", json={"top_neighbour_id": gym}).status_code == 404


# ---------- BUG-6: writes that pick a position take turns, and no tie stays ----------

@pytest.mark.anyio
async def test_two_adds_at_once_take_turns_and_get_their_own_places(pool):
    # both read the same last position and stored the same key: a tie nothing could be moved between
    async def in_transaction(write):
        async with pool.connection() as conn, conn.transaction():
            return await write(conn)
    gym = await in_transaction(lambda conn: library.create_playlist(conn, f"Gym {uuid4().hex[:6]}"))
    song = await in_transaction(lambda conn: library.resolve_song(conn, [Listing(**listings("Song")["listings"][0])]))
    async with pool.connection() as first, first.transaction():
        await library.add_to_playlist(first, gym, song)              # holds the playlist's turn until it commits
        second = asyncio.create_task(in_transaction(lambda conn: library.add_to_playlist(conn, gym, song)))
        await asyncio.sleep(0.2)
        assert not second.done()                                     # waiting for it
    await second
    with psycopg.connect(TEST_URL) as conn:
        assert conn.execute("SELECT count(DISTINCT position) FROM playlist_items WHERE playlist_id = %s", [gym]).fetchone()[0] == 2


def test_a_move_between_two_tied_songs_works(client):
    # a tie from before the turns answered 422 for good; the playlist gets fresh keys once
    gym, ids = abc(client)
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("UPDATE playlist_items SET position = 'a1' WHERE id = ANY(%s)", [[UUID(ids["A"]), UUID(ids["B"])]])
    assert move(client, gym, ids["C"], top=ids["A"], bottom=ids["B"]).status_code == 204
    assert order(client, gym) == ["A", "C", "B"]


def test_two_moves_into_the_same_slot_both_land_there(client):
    # the same neighbours give the same key: the second move (the app had not seen the first) would have tied with it
    gym, ids = abc(client)
    d = add(client, gym, listings("D"))["item_id"]
    move(client, gym, ids["C"], top=ids["A"], bottom=ids["B"])
    assert move(client, gym, d, top=ids["A"], bottom=ids["B"]).status_code == 204
    assert order(client, gym) == ["A", "C", "D", "B"]
    assert len(set(all_positions("playlist_items").values())) == len(all_positions("playlist_items"))


def test_a_move_between_two_tied_playlists_works(client):
    gym, chill, focus = (create(client, n).json()["id"] for n in ("Gym", "Chill", "Focus"))
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("UPDATE playlists SET position = 'a0' WHERE id = ANY(%s)", [[UUID(gym), UUID(chill)]])
    names = lambda: [p["name"] for p in client.get("/playlists").json()["playlists"]]
    assert names() == ["Gym", "Chill", "Focus"]                      # a tie keeps its order: then by id
    assert client.post(f"/playlists/{focus}/move", json={"top_neighbour_id": gym, "bottom_neighbour_id": chill}).status_code == 204
    assert names() == ["Gym", "Focus", "Chill"]
