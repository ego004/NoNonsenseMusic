"""AUTH-3: who may do what with a playlist. Owner: everything. Editor: add, remove, reorder songs. Viewer: look and
play. A public playlist: everyone signed in is a viewer. A private one you are not on: 404, as if it did not exist."""
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from conftest import TEST_URL, sign_up


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client


class Person:
    """One signed-in account. Its calls send its own token."""

    def __init__(self, client):
        self.client = client
        session = sign_up(client)
        del client.headers["Authorization"]          # each Person sends its own token, below
        self.token, self.id, self.username = session["token"], session["user"]["id"], session["user"]["username"]

    def __call__(self, method, path, **kw):
        return self.client.request(method, path, headers={"Authorization": f"Bearer {self.token}"}, **kw)

    def add(self, playlist, title="Song"):
        listing = {"source": "jiosaavn", "id": f"share-{uuid4().hex[:8]}", "title": title, "artists": ["Artist"],
                   "album": None, "duration": 200, "popularity": None}
        return self("POST", f"/playlists/{playlist}/items", json={"listings": [listing]})


@pytest.fixture
def people(client):
    """Alex owns "Road trip" with one song; Sam and Kai have accounts and no access yet."""
    alex, sam, kai = Person(client), Person(client), Person(client)
    trip = alex("POST", "/playlists", json={"name": "Road trip"}).json()["id"]
    item = alex.add(trip).json()["item_id"]
    return alex, sam, kai, trip, item


def share(owner, playlist, person, role):
    return owner("PUT", f"/playlists/{playlist}/members", json={"username": person.username, "role": role})


def test_a_private_playlist_is_404_to_everyone_else(people):
    alex, sam, _, trip, item = people
    for method, path, body in [("GET", f"/playlists/{trip}", None), ("PATCH", f"/playlists/{trip}", {"name": "x"}),
                               ("DELETE", f"/playlists/{trip}", None), ("DELETE", f"/playlists/{trip}/items/{item}", None)]:
        assert sam(method, path, json=body).status_code == 404, (method, path)
    assert sam.add(trip).status_code == 404
    assert [p["name"] for p in alex("GET", "/playlists").json()["playlists"]] == ["Road trip"]
    assert sam("GET", "/playlists").json()["playlists"] == []


def test_public_lets_everyone_view_and_nobody_else_edit(people):
    alex, sam, _, trip, item = people
    r = alex("PATCH", f"/playlists/{trip}", json={"public": True})
    assert r.status_code == 200 and r.json()["public"] is True
    opened = sam("GET", f"/playlists/{trip}")
    assert opened.status_code == 200 and opened.json()["role"] == "viewer" and len(opened.json()["items"]) == 1
    assert sam.add(trip).status_code == 403
    assert sam("DELETE", f"/playlists/{trip}/items/{item}").status_code == 403
    assert sam("GET", "/playlists").json()["playlists"] == []      # public is opened by link, not listed
    alex("PATCH", f"/playlists/{trip}", json={"public": False})
    assert sam("GET", f"/playlists/{trip}").status_code == 404


def test_a_viewer_sees_it_in_their_list_and_cannot_edit(people):
    alex, sam, _, trip, item = people
    assert share(alex, trip, sam, "viewer").status_code == 204
    [listed] = sam("GET", "/playlists").json()["playlists"]
    assert (listed["id"], listed["role"]) == (trip, "viewer")
    assert sam.add(trip).status_code == 403
    assert sam("POST", f"/playlists/{trip}/items/{item}/move", json={}).status_code == 403


def test_an_editor_changes_songs_but_not_the_playlist(people):
    alex, sam, _, trip, item = people
    share(alex, trip, sam, "editor")
    second = sam.add(trip, "Second")
    assert second.status_code == 201
    second = second.json()["item_id"]
    assert sam("POST", f"/playlists/{trip}/items/{second}/move", json={"bottom_neighbour_id": item}).status_code == 204
    assert [i["item_id"] for i in alex("GET", f"/playlists/{trip}").json()["items"]] == [second, item]
    assert sam("DELETE", f"/playlists/{trip}/items/{item}").status_code == 204
    # the playlist itself stays the owner's
    assert sam("PATCH", f"/playlists/{trip}", json={"name": "Mine now"}).status_code == 403
    assert sam("PATCH", f"/playlists/{trip}", json={"public": True}).status_code == 403
    assert sam("DELETE", f"/playlists/{trip}").status_code == 403
    assert share(sam, trip, sam, "editor").status_code == 403


def test_the_owner_changes_a_role_and_removes_people(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "editor")
    share(alex, trip, sam, "viewer")                                     # the same invite again changes the role
    assert sam("GET", f"/playlists/{trip}").json()["role"] == "viewer"
    assert alex("DELETE", f"/playlists/{trip}/members/{sam.id}").status_code == 204
    assert sam("GET", f"/playlists/{trip}").status_code == 404
    assert alex("DELETE", f"/playlists/{trip}/members/{sam.id}").status_code == 404    # not a member any more


def test_a_member_may_leave_but_not_remove_others(people):
    alex, sam, kai, trip, _ = people
    share(alex, trip, sam, "editor")
    share(alex, trip, kai, "viewer")
    assert sam("DELETE", f"/playlists/{trip}/members/{kai.id}").status_code == 403
    assert sam("DELETE", f"/playlists/{trip}/members/{sam.id}").status_code == 204
    assert sam("GET", "/playlists").json()["playlists"] == []
    assert kai("GET", f"/playlists/{trip}").status_code == 200


def test_invites_to_nobody_and_to_yourself(people):
    alex, _, _, trip, _ = people
    r = alex("PUT", f"/playlists/{trip}/members", json={"username": "test-nobody-here", "role": "viewer"})
    assert r.status_code == 404 and r.json()["detail"] == "No account with that username"
    assert alex("PUT", f"/playlists/{trip}/members", json={"username": alex.username, "role": "viewer"}).status_code == 204
    assert alex("GET", f"/playlists/{trip}").json()["role"] == "owner"     # still the owner, not demoted
    assert alex("PUT", f"/playlists/{trip}/members", json={"username": "x", "role": "owner"}).status_code == 422


def test_liked_marks_are_the_viewers_own(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    song = alex("GET", f"/playlists/{trip}").json()["items"][0]["song"]
    alex("POST", "/liked", json={"listings": song["listings"]})
    assert alex("GET", f"/playlists/{trip}").json()["items"][0]["song"]["liked"] is True
    assert sam("GET", f"/playlists/{trip}").json()["items"][0]["song"]["liked"] is False


def test_a_refused_add_stores_no_song(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    import psycopg
    with psycopg.connect(TEST_URL) as conn:
        before = conn.execute("SELECT count(*) FROM songs").fetchone()[0]
        assert sam.add(trip).status_code == 403
        assert conn.execute("SELECT count(*) FROM songs").fetchone()[0] == before


def test_deleting_the_playlist_removes_it_for_members_too(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "editor")
    assert alex("DELETE", f"/playlists/{trip}").status_code == 204
    assert sam("GET", "/playlists").json()["playlists"] == []
    assert sam("GET", f"/playlists/{trip}").status_code == 404
