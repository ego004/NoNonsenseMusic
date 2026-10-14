"""Test the jam room: one host plays, everyone else holds the remote. Rooms are in memory, written to the
database only when the server stops (and read back when it starts). Tests drive the hub directly for command
semantics and the real WebSocket for the socket path."""
import time
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import JamCommand, ListingIn
from music_backend.services import jam
from conftest import TEST_URL, sign_up


@pytest.fixture
def client(monkeypatch):
    """Yield a TestClient for the app pointed at the test database."""
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client


class Person:
    """Represent a signed-in account whose requests carry that account's token."""

    def __init__(self, client):
        self.client = client
        session = sign_up(client)
        del client.headers["Authorization"]
        self.token, self.id, self.username = session["token"], session["user"]["id"], session["user"]["username"]

    def __call__(self, method, path, **kw):
        return self.client.request(method, path, headers={"Authorization": f"Bearer {self.token}"}, **kw)


def listing(i: int, duration: int = 200) -> dict:
    """Return a raw listing dict for song i, in the shape the API returns it."""
    return {"source": "jiosaavn", "id": f"jam-{i}", "title": f"Song {i}", "artists": ["Artist"],
            "album": None, "duration": duration, "popularity": None}


def make_listing(i: int, duration: int = 200) -> ListingIn:
    """Return the same listing as a validated model, in the form a client sends."""
    return ListingIn.model_validate(listing(i, duration))


class FakeWS:
    """Record everything the hub sends, in place of a real socket."""

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
    assert again.status_code == 200 and len(again.json()["members"]) == 2     # rejoin is idempotent


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


def test_only_host_can_choose_a_new_host_and_keeps_old_host_as_member(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    assert bob("POST", f"/jam/{room['room_id']}/host", json={"member_id": bob.id}).status_code == 403
    assert alice("POST", f"/jam/{room['room_id']}/host", json={"member_id": bob.id}).status_code == 204
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
    assert state["host_id"] == bob.id                                    # next member in join order
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
        assert alice("POST", f"/jam/{room['room_id']}/host", json={"member_id": alice.id}).status_code == 204
    assert alice("POST", f"/jam/{room['room_id']}/host", json={"member_id": alice.id}).status_code == 429
    assert bob("POST", f"/jam/{room['room_id']}/leave").status_code == 204    # Bob still has budget left


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
async def test_add_now_plays_at_once_and_add_next_goes_first():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(3)], placement="next"), sender)
    assert [e.listing.title for e in room.queue] == ["Song 3", "Song 2"]
    room.position_seconds = 50.0
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(4), make_listing(5)], placement="now"), sender)
    assert room.current.listing.title == "Song 4" and room.is_playing and room.position_seconds == 0.0
    assert [e.listing.title for e in room.queue] == ["Song 5", "Song 3", "Song 2"]


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
    numbers = iter(range(10_000))

    async def add(count):
        batch = [make_listing(next(numbers)) for _ in range(count)]
        await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=batch), sender)

    await add(1)                                    # becomes the current song
    for _ in range(jam.MAX_QUEUE // 50):            # a command carries at most 50 listings
        await add(50)
    assert len(room.queue) == jam.MAX_QUEUE
    await add(1)                                    # one past the cap
    assert sender.last()["type"] == "error" and "full" in sender.last()["detail"]
    assert len(room.queue) == jam.MAX_QUEUE


@pytest.mark.anyio
async def test_malformed_and_unknown_commands_answer_the_sender():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="play"), sender)
    assert sender.last() == {"type": "error", "detail": "Nothing to play."}


def test_command_rate_limit_per_member():
    hub = jam.JamHub()
    room = hub.create(uuid4(), "alice", None)
    for _ in range(jam.MAX_COMMANDS):
        assert hub.command_allowed(room, room.host_id)
    assert not hub.command_allowed(room, room.host_id)
    other = uuid4()
    assert hub.command_allowed(room, other)                                 # per member, not per room


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
    hub.command_allowed(room, room.host_id)
    assert hub.leave(room.host_id, room.id) is None
    assert room.code not in hub._by_code
    assert not any(k[0] == room.id for k in hub._command_hits)


# ---------- every member plays: copies to fall back on, and the host's "only my device" ----------

@pytest.mark.anyio
async def test_add_keeps_each_songs_other_copies_for_the_members():
    hub, room, sender = fresh_room()
    cmd = JamCommand(type="add", listings=[make_listing(1), make_listing(2)],
                     copies=[[make_listing(11), make_listing(12)], []])
    await hub.handle_command(room, room.host_id, cmd, sender)
    assert [c.title for c in room.current.copies] == ["Song 11", "Song 12"]
    assert room.queue[0].copies == []
    state = sender.last()["data"]
    assert [c["title"] for c in state["current"]["copies"]] == ["Song 11", "Song 12"]


@pytest.mark.anyio
async def test_an_app_that_sends_no_copies_still_adds():
    hub, room, sender = fresh_room()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1)]), sender)
    assert room.current.copies == [] and sender.last()["data"]["current"]["copies"] == []


@pytest.mark.anyio
async def test_copies_that_do_not_match_the_songs_are_refused():
    hub, room, sender = fresh_room()
    cmd = JamCommand(type="add", listings=[make_listing(1), make_listing(2)], copies=[[make_listing(11)]])
    await hub.handle_command(room, room.host_id, cmd, sender)
    assert sender.last()["type"] == "error" and room.current is None


def test_a_song_brings_at_most_four_other_copies():
    with pytest.raises(ValueError):
        JamCommand(type="add", listings=[make_listing(1)], copies=[[make_listing(i) for i in range(10, 15)]])


@pytest.mark.anyio
async def test_every_member_plays_until_the_host_chooses_only_their_device():
    hub, room, sender = fresh_room()
    assert hub.state(room).only_host_plays is False
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_plays", on=True), sender)
    assert room.only_host_plays and sender.last()["data"]["only_host_plays"] is True
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_plays", on=False), sender)
    assert not room.only_host_plays and sender.last()["data"]["only_host_plays"] is False


@pytest.mark.anyio
async def test_only_the_host_chooses_where_the_jam_plays():
    hub, room, sender = fresh_room()
    member = uuid4()
    room.members[member] = "bob"
    room.join_order.append(member)
    await hub.handle_command(room, member, JamCommand(type="only_host_plays", on=True), sender)
    assert sender.last()["type"] == "error" and not room.only_host_plays
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_plays"), sender)
    assert sender.last()["type"] == "error" and not room.only_host_plays, "on or off must be said"


@pytest.mark.anyio
async def test_only_host_plays_stays_with_the_room_when_the_host_changes():
    hub, room, sender = fresh_room()
    member = uuid4()
    room.members[member] = "bob"
    room.join_order.append(member)
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_plays", on=True), sender)
    hub.set_host(room.host_id, room.id, member)
    assert room.host_id == member and hub.state(room).only_host_plays


def test_ws_the_apps_messages_for_copies_and_settings_reach_every_member(client):
    """The JSON the Mac and Windows apps send, through the real socket: copies travel with the song to the other member,
    the host's settings reach everyone, and a member's own setting is refused to that member alone."""
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    ticket_a = alice("POST", "/ws-ticket").json()["ticket"]
    ticket_b = bob("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/jam?ticket={ticket_a}&room_id={room['room_id']}") as ws_a:
        assert ws_a.receive_json()["data"]["only_host_plays"] is False, "every device plays by default"
        with client.websocket_connect(f"/ws/jam?ticket={ticket_b}&room_id={room['room_id']}") as ws_b:
            ws_b.receive_json()
            ws_a.send_json({"type": "add", "listings": [listing(1)], "copies": [[listing(11), listing(12)]], "placement": "end"})
            for ws in (ws_a, ws_b):
                current = ws.receive_json()["data"]["current"]
                assert [c["title"] for c in current["copies"]] == ["Song 11", "Song 12"]
            ws_b.send_json({"type": "only_host_plays", "on": True})
            assert ws_b.receive_json()["type"] == "error"
            ws_a.send_json({"type": "only_host_plays", "on": True})
            for ws in (ws_a, ws_b):
                assert ws.receive_json()["data"]["only_host_plays"] is True


# ---------- only_host_controls: members add songs; playback and the queue are the host's ----------

def room_with_a_member():
    hub, room, sender = fresh_room()
    member = uuid4()
    room.members[member] = "bob"
    room.join_order.append(member)
    return hub, room, sender, member


@pytest.mark.anyio
async def test_every_member_controls_the_jam_by_default():
    hub, room, sender, member = room_with_a_member()
    assert hub.state(room).only_host_controls is False
    await hub.handle_command(room, member, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    await hub.handle_command(room, member, JamCommand(type="skip"), sender)
    assert room.current.listing.title == "Song 2" and sender.last()["type"] == "state"


@pytest.mark.anyio
async def test_with_only_host_controls_a_member_can_add_to_the_queue_and_nothing_else():
    hub, room, sender, member = room_with_a_member()
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_controls", on=True), sender)
    assert sender.last()["data"]["only_host_controls"] is True
    entry = room.queue[0].entry_id
    for cmd in [JamCommand(type="play"), JamCommand(type="pause"), JamCommand(type="seek", seconds=30), JamCommand(type="skip"),
                JamCommand(type="jump", entry_id=entry), JamCommand(type="remove", entry_id=entry),
                JamCommand(type="move", entry_id=entry, to_index=0),
                JamCommand(type="add", listings=[make_listing(3)], placement="now"),
                JamCommand(type="add", listings=[make_listing(3)], placement="next")]:
        await hub.handle_command(room, member, cmd, sender)
        assert sender.last()["type"] == "error", cmd.type
    assert room.current.listing.title == "Song 1" and room.is_playing and [e.listing.title for e in room.queue] == ["Song 2"]
    await hub.handle_command(room, member, JamCommand(type="add", listings=[make_listing(3)]), sender)
    assert [e.listing.title for e in room.queue] == ["Song 2", "Song 3"], "adding to the end stays open to everyone"


@pytest.mark.anyio
async def test_the_host_keeps_control_and_only_the_host_changes_the_settings():
    hub, room, sender, member = room_with_a_member()
    await hub.handle_command(room, member, JamCommand(type="only_host_controls", on=True), sender)
    assert sender.last()["type"] == "error" and not room.only_host_controls
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_controls", on=True), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="add", listings=[make_listing(1), make_listing(2)]), sender)
    await hub.handle_command(room, room.host_id, JamCommand(type="skip"), sender)
    assert room.current.listing.title == "Song 2", "the host is not locked out"
    await hub.handle_command(room, room.host_id, JamCommand(type="only_host_controls", on=False), sender)
    await hub.handle_command(room, member, JamCommand(type="pause"), sender)
    assert not room.is_playing, "turned off: the member controls again"


def test_ws_a_locked_member_is_told_and_the_room_is_unchanged(client):
    alice, bob = Person(client), Person(client)
    room = alice("POST", "/jam", json={}).json()
    bob("POST", "/jam/join", json={"code": room["code"]})
    ticket_a = alice("POST", "/ws-ticket").json()["ticket"]
    ticket_b = bob("POST", "/ws-ticket").json()["ticket"]
    with client.websocket_connect(f"/ws/jam?ticket={ticket_a}&room_id={room['room_id']}") as ws_a:
        assert ws_a.receive_json()["data"]["only_host_controls"] is False
        with client.websocket_connect(f"/ws/jam?ticket={ticket_b}&room_id={room['room_id']}") as ws_b:
            ws_b.receive_json()
            ws_a.send_json({"type": "only_host_controls", "on": True})
            for ws in (ws_a, ws_b):
                assert ws.receive_json()["data"]["only_host_controls"] is True
            ws_b.send_json({"type": "skip"})
            assert ws_b.receive_json() == {"type": "error", "detail": "The host controls this jam. You can add songs to the queue."}


# ---------- across a restart (#31) ----------

def snapshot_after(hub: jam.JamHub, seconds_away: float) -> list:
    """The hub's rooms as saved, with the server away for this long before they are read back."""
    return [(room_id, {**state, "saved_at": state["saved_at"] - seconds_away}) for room_id, state in hub.snapshot()]


@pytest.mark.anyio
async def test_a_room_comes_back_as_it_was_after_a_restart():
    hub = jam.JamHub()
    room = hub.create(alice := uuid4(), "alice", "Friday")
    room.members[bob := uuid4()] = "bob"
    room.join_order.append(bob)
    room.only_host_controls = True
    await hub.handle_command(room, alice, JamCommand(type="add", listings=[make_listing(1, 300), make_listing(2)]), FakeWS())
    await hub.handle_command(room, alice, JamCommand(type="seek", seconds=100), FakeWS())

    restarted = jam.JamHub()
    restarted.restore(snapshot_after(hub, 4))                                # a deploy: about 4 s away
    back = restarted.require(room.id, bob)
    assert (back.code, back.name, back.host_id, back.members, back.join_order) == (room.code, "Friday", alice, room.members, [alice, bob])
    assert restarted.state(back).model_dump(include={"current", "queue", "only_host_controls"}) == \
           hub.state(room).model_dump(include={"current", "queue", "only_host_controls"})        # as the apps see it
    assert back.is_playing and restarted.playhead(back) == pytest.approx(104, abs=1)   # the players never stopped
    assert restarted.join(uuid4(), "carol", room.code)[0] is back           # its code still works


@pytest.mark.anyio
async def test_a_room_away_for_long_waits_paused_where_it_was():
    hub = jam.JamHub()
    room = hub.create(alice := uuid4(), "alice", None)
    await hub.handle_command(room, alice, JamCommand(type="add", listings=[make_listing(1, 300)]), FakeWS())
    await hub.handle_command(room, alice, JamCommand(type="seek", seconds=100), FakeWS())
    restarted = jam.JamHub()
    restarted.restore(snapshot_after(hub, jam.RESUME_WITHIN + 1))
    back = restarted.require(room.id, alice)
    assert not back.is_playing and restarted.playhead(back) == pytest.approx(100, abs=1)


def test_a_room_idle_too_long_is_not_reopened():
    hub = jam.JamHub()
    room = hub.create(alice := uuid4(), "alice", None)
    room.touched_at -= jam.ROOM_IDLE_SECONDS - 30                         # 30 s of its idle time left
    restarted = jam.JamHub()
    restarted.restore(snapshot_after(hub, 60))                               # the time away counts as idle
    assert restarted.get(room.id) is None


def test_open_jams_survive_the_server_restarting(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as first:
        alice, bob = Person(first), Person(first)
        room = alice("POST", "/jam", json={"name": "Friday"}).json()
        bob("POST", "/jam/join", json={"code": room["code"]})
    # the server stopped, saving its rooms; it starts again and reads them back
    with TestClient(app) as again:
        r = again.get(f"/jam/{room['room_id']}", headers={"Authorization": f"Bearer {bob.token}"})
        assert r.status_code == 200
        assert {m["username"] for m in r.json()["members"]} == {alice.username, bob.username}
        assert r.json()["host_id"] == alice.id and r.json()["name"] == "Friday"
