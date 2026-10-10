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


def test_the_owner_and_members_see_who_is_on_it_and_a_public_viewer_does_not(people):
    alex, sam, kai, trip, _ = people
    share(alex, trip, sam, "editor")
    share(alex, trip, kai, "viewer")
    expected = [(alex.username, "owner"), (sam.username, "editor"), (kai.username, "viewer")]
    for person in (alex, sam, kai):                                  # the owner first, then in the order invited
        r = person("GET", f"/playlists/{trip}/members")
        assert r.status_code == 200 and [(m["username"], m["role"]) for m in r.json()] == expected
    alex("DELETE", f"/playlists/{trip}/members/{kai.id}")
    alex("PATCH", f"/playlists/{trip}", json={"public": True})
    assert kai("GET", f"/playlists/{trip}").status_code == 200     # still opens it: it is public
    assert kai("GET", f"/playlists/{trip}/members").status_code == 403
    alex("PATCH", f"/playlists/{trip}", json={"public": False})
    assert kai("GET", f"/playlists/{trip}/members").status_code == 404


def test_a_playlist_link_page_hands_over_to_the_app_and_names_nothing(client, people):
    alex, _, _, trip, _ = people
    page = client.get(f"/p/{trip}", headers={"Authorization": ""})      # no sign-in needed
    assert page.status_code == 200 and page.headers["content-type"].startswith("text/html")
    assert f"nononsense://playlist/{trip}" in page.text
    assert "Road trip" not in page.text                              # private or not, the page shows nothing of it
    assert client.get("/p/not-a-uuid").status_code == 422


# ---------- playlist_invite notifications (closing the dead type) ----------

def invitees_notifications(person):
    return person("GET", "/notifications").json()


def test_invite_creates_a_playlist_invite_notification(people):
    alex, sam, _, trip, _ = people
    assert share(alex, trip, sam, "viewer").status_code == 204
    body = invitees_notifications(sam)
    assert body["unread_count"] == 1
    [n] = body["notifications"]
    assert n["type"] == "playlist_invite" and n["read"] is False
    payload = n["payload"]
    assert payload["playlist_id"] == trip
    assert payload["playlist_name"] == "Road trip"
    assert payload["from_user_id"] == alex.id
    assert payload["from_username"] == alex.username


def test_the_owner_gets_no_notification_for_their_own_invite(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    assert invitees_notifications(alex)["notifications"] == []


def test_a_role_change_is_not_a_new_invite(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "editor")
    share(alex, trip, sam, "viewer")                                 # demotion: membership updated, not created
    assert sam("GET", f"/playlists/{trip}").json()["role"] == "viewer"
    body = invitees_notifications(sam)
    assert body["unread_count"] == 1                                 # still just the first invite
    assert [n["payload"]["playlist_name"] for n in body["notifications"]] == ["Road trip"]


def test_self_invite_creates_nothing(people):
    alex, _, _, trip, _ = people
    assert alex("PUT", f"/playlists/{trip}/members", json={"username": alex.username, "role": "viewer"}).status_code == 204
    assert invitees_notifications(alex)["notifications"] == []


def test_unshare_then_reinvite_while_unread_is_deduped(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    assert alex("DELETE", f"/playlists/{trip}/members/{sam.id}").status_code == 204
    share(alex, trip, sam, "editor")                                 # first invite still unread: suppressed
    body = invitees_notifications(sam)
    assert body["unread_count"] == 1
    assert len(body["notifications"]) == 1


def test_reinvite_after_the_first_was_read_is_a_new_notification(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    [first] = invitees_notifications(sam)["notifications"]
    sam("POST", f"/notifications/{first['id']}/read")                # seen: no longer deduped
    assert alex("DELETE", f"/playlists/{trip}/members/{sam.id}").status_code == 204
    share(alex, trip, sam, "editor")
    body = invitees_notifications(sam)
    assert body["unread_count"] == 1
    assert len(body["notifications"]) == 2                           # history keeps both


def test_a_bad_invite_stores_no_notification(people):
    alex, sam, _, trip, _ = people
    assert share(alex, trip, sam, "owner").status_code == 422        # rejected before any write
    assert alex("PUT", f"/playlists/{trip}/members", json={"username": "no-such-person", "role": "viewer"}).status_code == 404
    assert invitees_notifications(sam)["notifications"] == []


def test_the_invitee_may_mark_it_read(people):
    alex, sam, _, trip, _ = people
    share(alex, trip, sam, "viewer")
    [n] = invitees_notifications(sam)["notifications"]
    assert sam("POST", f"/notifications/{n['id']}/read").status_code == 200
    assert invitees_notifications(sam)["unread_count"] == 0


def test_the_invite_pushes_over_the_invitees_websocket(client, people):
    alex, sam, _, trip, _ = people
    ticket = sam("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/notifications?ticket={ticket}") as ws:
        ws.receive_json()                                            # connected
        share(alex, trip, sam, "editor")
        msg = ws.receive_json()
        assert msg["type"] == "notification"
        assert msg["data"]["type"] == "playlist_invite"
        assert msg["data"]["payload"]["playlist_name"] == "Road trip"
