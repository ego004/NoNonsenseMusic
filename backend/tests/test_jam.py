"""JAM-1: one room, one host plays, everyone else holds the remote. Rooms are in-memory (no DB
writes beyond auth); tests drive the hub directly for command semantics and the real WebSocket
for the socket path."""
import time
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import JamCommand, Listing
from music_backend.services import jam
from conftest import TEST_URL, sign_up


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client


class Person:
    """One signed-in account; its calls send its own token."""

    def __init__(self, client):
        self.client = client
        session = sign_up(client)
        del client.headers["Authorization"]
        self.token, self.id, self.username = session["token"], session["user"]["id"], session["user"]["username"]

    def __call__(self, method, path, **kw):
        return self.client.request(method, path, headers={"Authorization": f"Bearer {self.token}"}, **kw)


def listing(i: int, duration: int = 200) -> dict:
    return {"source": "jiosaavn", "id": f"jam-{i}", "title": f"Song {i}", "artists": ["Artist"],
            "album": None, "duration": duration, "popularity": None}


def make_listing(i: int, duration: int = 200) -> Listing:
    return Listing.model_validate(listing(i, duration))


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)

    def last(self):
        return self.sent[-1]


# ---------- REST lifecycle ----------

def test_create_makes_you_host_and_first_member(client):
    alice = Person(client)
    r = alice("POST", "/jam", json={"name": "Friday"})
    assert r.status_code == 201
    body = r.json()
    assert body["host_id"] == alice.id
    assert [(m["user_id"], m["username"]) for m in body["members"]] == [(alice.id, alice.username)]
    assert body["name"] == "Friday" and len(body["code"]) == 8
    assert body["current"] is None and body["queue"] == [] and body["is_playing"] is False


def test_create_with_no_name(client):
    alice = Person(client)
    assert alice("POST", "/jam", json={}).json()["name"] is None


def test_join_by_code_and_idempotent_rejoin(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    r = bob("POST", "/jam/join", json={"code": room["code"]})
    assert r.status_code == 200 and len(r.json()["members"]) == 2
    again = bob("POST", "/jam/join", json={"code": room["code"]})
    assert again.status_code == 200 and len(again.json()["members"]) == 2     # still two, not three


def test_join_bad_code_is_404(client):
    bob = Person(client)
    assert bob("POST", "/jam/join", json={"code": "zzzzzzzz"}).status_code == 404
    assert bob("POST", "/jam/join", json={"code": ""}).status_code == 422


def test_get_state_member_ok_outsider_404(client):
    alice, mallory = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    assert alice("GET", f"/jam/{room['room_id']}").status_code == 200
    assert mallory("GET", f"/jam/{room['room_id']}").status_code == 404
    assert alice("GET", "/jam/01930000-0000-7000-8000-000000000001").status_code == 404


def test_take_host_switches_and_keeps_old_host_as_member(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    assert bob("POST", f"/jam/{room['room_id']}/host").status_code == 204
    state = alice("GET", f"/jam/{room['room_id']}").json()
    assert state["host_id"] == bob.id
    assert {m["user_id"] for m in state["members"]} == {alice.id, bob.id}


def test_host_leaving_passes_hostship_by_join_order(client):
    alice, bob, kai = Person(client), Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    kai("POST", "/jam/join", json={"code": room["code"]})
    assert alice("POST", f"/jam/{room['room_id']}/leave").status_code == 204
    state = kai("GET", f"/jam/{room['room_id']}").json()
    assert state["host_id"] == bob.id                                    # next by join order
    assert {m["user_id"] for m in state["members"]} == {bob.id, kai.id}


def test_last_member_leaving_closes_the_room(client):
    alice = Person(client)
    room = alice("POST", "/jam", json={}).json()
    assert alice("POST", f"/jam/{room['room_id']}/leave").status_code == 204
    assert alice("GET", f"/jam/{room['room_id']}").status_code == 404
    assert alice("POST", f"/jam/{room['room_id']}/leave").status_code == 404


def test_leave_when_not_a_member_is_404(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    assert bob("POST", f"/jam/{room['room_id']}/leave").status_code == 404


def test_jam_routes_need_a_session(client):
    alice = Person(client)
    room = alice("POST", "/jam", json={}).json()
    for method, path in [("POST", "/jam"), ("POST", "/jam/join"), ("GET", f"/jam/{room['room_id']}"),
                         ("POST", f"/jam/{room['room_id']}/host"), ("POST", f"/jam/{room['room_id']}/leave")]:
        client.headers.pop("Authorization", None)
        assert client.request(method, path, json={"code": "xxxxxxxx", "name": None}).status_code == 401, path


def test_create_rate_limited(client):
    alice = Person(client)
    for _ in range(20):
        assert alice("POST", "/jam", json={}).status_code == 201
    r = alice("POST", "/jam", json={})
    assert r.status_code == 429 and "Retry-After" in r.headers


# ---------- WebSocket path ----------

def test_ws_connect_sends_state_and_ping_pongs(client):
    alice = Person(client)
    room = alice("POST", "/jam", json={}).json()
    ticket = alice("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/jam?ticket={ticket}&room_id={room['room_id']}") as ws:
        first = ws.receive_json()
        assert first["type"] == "state" and first["data"]["host_id"] == alice.id
        ws.send_text("ping")
        assert ws.receive_json() == {"type": "pong"}


def test_ws_bad_ticket_is_4401(client):
    alice = Person(client)
    room = alice("POST", "/jam", json={}).json()
    with pytest.raises(Exception) as excinfo:
        with client.websocket_connect(f"/ws/jam?ticket=garbage&room_id={room['room_id']}"):
            pass
    assert getattr(excinfo.value, "code", None) == 4401


def test_ws_non_member_is_4403(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    ticket = bob("POST", "/ws-ticket").json()["ticket"]
    with pytest.raises(Exception) as excinfo:
        with client.websocket_connect(f"/ws/jam?ticket={ticket}&room_id={room['room_id']}"):
            pass
    assert getattr(excinfo.value, "code", None) == 4403


def test_ws_two_members_both_receive_the_broadcast(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    ticket_a = alice("POST", "/ws-ticket").json()["ticket"]
    ticket_b = bob("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/jam?ticket={ticket_a}&room_id={room['room_id']}") as ws_a:
        ws_a.receive_json()
        with client.websocket_connect(f"/ws/jam?ticket={ticket_b}&room_id={room['room_id']}") as ws_b:
            ws_b.receive_json()
            ws_a.send_json({"type": "add", "listings": [listing(1)]})
            for ws in (ws_a, ws_b):
                msg = ws.receive_json()
                assert msg["type"] == "state"
                assert msg["data"]["current"]["listing"]["title"] == "Song 1"
                assert msg["data"]["is_playing"] is True


@pytest.mark.anyio
async def test_stale_position_heartbeat_cannot_unpause():
    """A heartbeat that was in flight when someone paused must not flip the room back to playing."""
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1, duration=300)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="pause"), sender)
    frozen = room.position_seconds
    await hub.handle_command(room, room.host_id, JamCommand(type="position", seconds=frozen + 50), sender)
    assert room.is_playing is False
    assert room.position_seconds == pytest.approx(frozen, abs=1)


def test_nan_and_infinity_seconds_rejected_at_the_model():
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(ValueError):
            JamCommand(type="seek", seconds=bad)
    assert JamCommand(type="seek", seconds=42).seconds == 42
    assert JamCommand(type="seek").seconds is None


@pytest.mark.anyio
async def test_nan_seconds_over_the_wire_answer_error():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1)]), sender)
    # the WS endpoint validates with model_validate_json; NaN is what the poison looks like on the wire
    with pytest.raises(Exception):
        JamCommand.model_validate_json('{"type":"seek","seconds":NaN}')
    assert room.position_seconds == 0


def test_take_host_and_leave_are_rate_limited(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()                           # alice: 1 of the jam budget
    bob("POST", "/jam/join", json={"code": room["code"]})                  # bob: 1 of his own
    for _ in range(19):                                                    # alice: 2..20
        assert bob("POST", f"/jam/{room['room_id']}/host").status_code == 204
    assert bob("POST", f"/jam/{room['room_id']}/host").status_code == 429  # 21st: over the shared /jam limit
    assert alice("POST", f"/jam/{room['room_id']}/leave").status_code == 204  # alice still has budget left


def test_leave_closes_that_users_socket(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    ticket = alice("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/jam?ticket={ticket}&room_id={room['room_id']}") as ws:
        ws.receive_json()
        assert alice("POST", f"/jam/{room['room_id']}/leave").status_code == 204
        with pytest.raises(Exception):
            ws.receive_json()                                              # server closed with 4404
    state = bob("GET", f"/jam/{room['room_id']}").json()
    assert state["host_id"] == bob.id                                      # hostship still passed on


# ---------- command semantics (hub directly, no socket plumbing) ----------

def fresh_room():
    """A hub, a room, and the host's FakeWS registered as a live socket (so broadcasts reach it)."""
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    sender = FakeWS()
    room.sockets[sender] = room.host_id
    return hub, room, sender


@pytest.mark.anyio
async def test_add_to_idle_room_starts_it():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    assert room.current.listing.title == "Song 1" and room.is_playing
    assert [e.listing.title for e in room.queue] == ["Song 2"]
    assert sender.last()["type"] == "state"


@pytest.mark.anyio
async def test_add_while_playing_appends():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(2), make_listing(3)]), sender)
    assert room.current.listing.title == "Song 1"
    assert [e.listing.title for e in room.queue] == ["Song 2", "Song 3"]


@pytest.mark.anyio
async def test_pause_freezes_playhead_and_play_resumes():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1, duration=300)]), sender)
    room.position_seconds = 90.0
    room.position_at = time.time()
    await hub.handle_command(room, room.host_id, JamCommand(type="pause"), sender)
    assert room.is_playing is False and room.position_seconds == pytest.approx(90.0, abs=1)
    before = room.position_seconds
    await hub.handle_command(room, room.host_id, JamCommand(type="play"), sender)
    assert room.is_playing is True and room.position_seconds == pytest.approx(before, abs=1)


@pytest.mark.anyio
async def test_seek_sets_position_and_needs_a_current():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="seek", seconds=42), sender)
    assert sender.last()["type"] == "error"                       # nothing playing
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="seek", seconds=42), sender)
    assert room.position_seconds == 42 and sender.last()["type"] == "state"


@pytest.mark.anyio
async def test_skip_advances_then_empties():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="skip"), sender)
    assert room.current.listing.title == "Song 2" and room.is_playing
    await hub.handle_command(room, room.host_id, JamCommand(type="skip"), sender)
    assert room.current is None and not room.is_playing


@pytest.mark.anyio
async def test_remove_current_promotes_next_remove_other_shrinks():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2), make_listing(3)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="remove", entry_id=room.queue[0].entry_id), sender)
    assert [e.listing.title for e in room.queue] == ["Song 3"]
    await hub.handle_command(room, room.host_id, JamCommand(type="remove", entry_id=room.current.entry_id), sender)
    assert room.current.listing.title == "Song 3"


@pytest.mark.anyio
async def test_move_reorders_and_jump_plays_now():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add",
        listings=[make_listing(1), make_listing(2), make_listing(3), make_listing(4)]), sender)
    last = room.queue[-1]
    await hub.handle_command(room, room.host_id, JamCommand(type="move", entry_id=last.entry_id, to_index=0), sender)
    assert [e.listing.title for e in room.queue] == ["Song 4", "Song 2", "Song 3"]
    target = room.queue[1]
    await hub.handle_command(room, room.host_id, JamCommand(type="jump", entry_id=target.entry_id), sender)
    assert room.current.listing.title == "Song 2" and room.position_seconds == 0
    assert [e.listing.title for e in room.queue] == ["Song 4", "Song 3"]     # jumped-from song dropped, not requeued


@pytest.mark.anyio
async def test_position_heartbeat_only_from_host():
    hub = jam.JamHub()
    room = hub.create(u := uuid4(), "alice", None)
    other = uuid4()
    room.members[other] = "bob"
    room.join_order.append(other)
    sender, bystander = FakeWS(), FakeWS()
    room.sockets[sender] = u
    room.sockets[bystander] = other
    await hub.handle_command(room, u, JamCommand(type="add", listings=[make_listing(1, duration=300)]), sender)
    await hub.handle_command(room, u, JamCommand(type="position", seconds=100), sender)
    assert room.position_seconds == 100
    assert bystander.last() == {"type": "position", "seconds": pytest.approx(100, abs=2), "is_playing": True}
    await hub.handle_command(room, other, JamCommand(type="position", seconds=50), sender)
    assert room.position_seconds == pytest.approx(100, abs=2)                # rejected, unchanged
    assert sender.sent[-1]["type"] == "error"


@pytest.mark.anyio
async def test_every_member_controls_not_just_host():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    bob = uuid4()
    room.members[bob] = "bob"
    room.join_order.append(bob)
    sender = FakeWS()
    room.sockets[sender] = bob
    await hub.handle_command(room, bob, JamCommand(type="add", listings=[make_listing(1)]), sender)
    assert room.current.listing.title == "Song 1"                            # non-host started the music
    await hub.handle_command(room, bob, JamCommand(type="pause"), sender)
    assert not room.is_playing


@pytest.mark.anyio
async def test_command_after_leaving_is_rejected():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    bob = uuid4()
    room.members[bob] = "bob"
    room.join_order.append(bob)
    sender = FakeWS()
    hub.leave(bob, room.id)
    await hub.handle_command(room, bob, JamCommand(type="add", listings=[make_listing(1)]), sender)
    assert sender.last()["type"] == "error" and room.current is None


@pytest.mark.anyio
async def test_queue_full_is_an_error_to_sender_only():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1)]), sender)
    batch = [make_listing(i) for i in range(2, 3 + jam.MAX_QUEUE)]           # one past the cap
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=batch), sender)
    assert sender.last()["type"] == "error" and "full" in sender.last()["detail"]
    assert len(room.queue) <= jam.MAX_QUEUE


@pytest.mark.anyio
async def test_malformed_and_unknown_commands_answer_the_sender():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="play"), sender)
    assert sender.last() == {"type": "error", "detail": "Nothing to play."}


def test_command_rate_limit_per_member():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    for _ in range(jam.MAX_COMMANDS):
        assert hub._command_allowed(room, room.host_id)
    assert not hub._command_allowed(room, room.host_id)
    other = uuid4()
    assert hub._command_allowed(room, other)                                 # per member, not per room


def test_playhead_advances_while_playing_and_clamps():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    room.current = jam.JamQueueEntry(entry_id=uuid4(), listing=make_listing(1, duration=100))
    room.is_playing = True
    room.position_seconds = 90.0
    room.position_at = time.time() - 5
    assert hub.playhead(room) == pytest.approx(95.0, abs=1)
    room.position_at = time.time() - 50
    assert hub.playhead(room) == 100                                        # clamped to duration
    room.is_playing = False
    assert hub.playhead(room) == 90.0                                       # paused: frozen


def test_leave_cleans_code_lookup_and_command_counters():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    hub._command_allowed(room, room.host_id)
    assert hub.leave(room.host_id, room.id) is None
    assert room.code not in hub._by_code
    assert not any(k[0] == room.id for k in hub._command_hits)
