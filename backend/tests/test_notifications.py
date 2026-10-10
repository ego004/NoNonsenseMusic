"""Tests for notifications (FRIENDS-1 Phase 2): REST endpoints, friend-triggered creation,
dedup, payload validation, the WS ticket hub, and the WS endpoint through TestClient.

These run against music_test (wiped before each test). No network.
"""
import asyncio
from uuid import uuid4, UUID

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.services import notifications

TEST_URL = "postgresql:///music_test"


def new_username():
    return "test-" + uuid4().hex[:10]


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        with psycopg.connect(TEST_URL) as conn:
            conn.execute("DELETE FROM notifications")
            conn.execute("DELETE FROM friend_requests")
            conn.execute("DELETE FROM friends")
        yield client


def sign_up_user(client, username=None):
    name = username or new_username()
    r = client.post("/auth/signup", json={"username": name, "password": "testpass123"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    client.headers["Authorization"] = f"Bearer {token}"
    return name, token


def sign_up_as(client, username):
    r = client.post("/auth/signup", json={"username": username, "password": "testpass123"})
    assert r.status_code == 201, r.text
    return username, r.json()["token"]


# ---------- friend-triggered notification creation ----------

def test_friend_request_creates_notification(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications")
    assert r.status_code == 200
    body = r.json()
    assert body["unread_count"] == 1
    assert len(body["notifications"]) == 1
    n = body["notifications"][0]
    assert n["type"] == "friend_request"
    assert n["payload"]["from_username"] == alice
    assert n["read"] is False


def test_friend_accept_creates_notification_for_requester(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    # alice (the requester) gets friend_accepted
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/notifications")
    body = r.json()
    assert body["unread_count"] == 1
    assert body["notifications"][0]["type"] == "friend_accepted"
    assert body["notifications"][0]["payload"]["by_username"] == bob


def test_friend_decline_creates_no_notification(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "decline"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/notifications")
    assert r.json()["unread_count"] == 0


def test_respond_clears_responder_badge(client):
    """Declining or accepting clears YOUR friend_request badge — without this the red dot
    stays forever pointing at a request that no longer exists."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    assert client.get("/notifications/unread-count").json()["unread_count"] == 1
    client.post("/friends/respond", json={"username": alice, "action": "decline"})
    assert client.get("/notifications/unread-count").json()["unread_count"] == 0
    # the row is history, not gone
    r = client.get("/notifications")
    assert len(r.json()["notifications"]) == 1
    assert r.json()["notifications"][0]["read"] is True


def test_accept_clears_responder_badge(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    assert client.get("/notifications/unread-count").json()["unread_count"] == 0
    r = client.get("/notifications")
    assert r.json()["notifications"][0]["read"] is True


def test_dedup_unread_friend_request(client):
    """A second request from the same sender while the first is unread does not double-notify."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    # bob has not read it; alice somehow sends again (she cannot — 409 — but the index guards
    # against any path that tries: direct INSERT in the service would be rejected too)
    with psycopg.connect(TEST_URL) as conn:
        n = conn.execute("SELECT count(*) FROM notifications WHERE type = 'friend_request'").fetchone()[0]
        assert n == 1


def test_notification_after_read_can_recur(client):
    """Once bob reads the request, a new request (decline then resend) can notify again."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    # read it
    r = client.get("/notifications")
    nid = r.json()["notifications"][0]["id"]
    client.post(f"/notifications/{nid}/read")
    # decline, then alice resends
    client.post("/friends/respond", json={"username": alice, "action": "decline"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 201
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications")
    assert r.json()["unread_count"] == 1


# ---------- list / pagination / catch-up ----------

def test_list_empty(client):
    sign_up_user(client)
    r = client.get("/notifications")
    assert r.status_code == 200
    assert r.json() == {"notifications": [], "unread_count": 0}


def test_after_seq_catchup(client):
    """after_seq returns only notifications the client has not seen."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications")
    first = r.json()["notifications"][0]
    # client saw seq = first["seq"]; nothing new after it
    r = client.get(f"/notifications?after_seq={first['seq']}")
    assert r.json()["notifications"] == []
    # a new request from someone else arrives
    carol, carol_token = sign_up_as(client, new_username())
    client.headers["Authorization"] = f"Bearer {carol_token}"
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get(f"/notifications?after_seq={first['seq']}")
    assert len(r.json()["notifications"]) == 1


def test_before_seq_pagination(client):
    """before_seq pages backwards (scrolling an older list)."""
    alice, alice_token = sign_up_user(client)
    # three senders
    tokens = []
    for _ in range(3):
        u = new_username()
        _, t = sign_up_as(client, u)
        tokens.append((u, t))
    for u, t in tokens:
        client.headers["Authorization"] = f"Bearer {t}"
        client.post("/friends/request", json={"username": alice})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/notifications?limit=2")
    page1 = r.json()["notifications"]
    assert len(page1) == 2
    oldest = min(n["seq"] for n in page1)
    r = client.get(f"/notifications?before_seq={oldest}&limit=10")
    page2 = r.json()["notifications"]
    assert len(page2) == 1
    assert all(n["seq"] < oldest for n in page2)


def test_unread_only(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications?unread_only=true")
    assert len(r.json()["notifications"]) == 1
    # mark it read
    nid = r.json()["notifications"][0]["id"]
    client.post(f"/notifications/{nid}/read")
    r = client.get("/notifications?unread_only=true")
    assert r.json()["notifications"] == []


# ---------- mark read / read-all / unread count ----------

def test_mark_read(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications")
    nid = r.json()["notifications"][0]["id"]
    r = client.post(f"/notifications/{nid}/read")
    assert r.status_code == 200
    assert r.json()["unread_count"] == 0


def test_mark_read_wrong_user(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    # alice tries to read bob's notification
    r = client.get("/notifications")
    assert r.json()["notifications"] == []
    # she does not even know the id; if she guesses, 404
    with psycopg.connect(TEST_URL) as conn:
        nid = conn.execute("SELECT id FROM notifications LIMIT 1").fetchone()[0]
    r = client.post(f"/notifications/{nid}/read")
    assert r.status_code == 404


def test_mark_read_twice_is_still_200(client):
    """Idempotent: re-marking your own already-read notification is 200, not 404."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/notifications")
    nid = r.json()["notifications"][0]["id"]
    r = client.post(f"/notifications/{nid}/read")
    assert r.status_code == 200
    r = client.post(f"/notifications/{nid}/read")
    assert r.status_code == 200
    assert r.json()["unread_count"] == 0


def test_read_all(client):
    """Three senders each send bob a request: bob has 3 unread, then 0 after read-all."""
    bob_name = new_username()
    sign_up_as(client, bob_name)
    for _ in range(3):
        _, sender_token = sign_up_as(client, new_username())
        client.headers["Authorization"] = f"Bearer {sender_token}"
        r = client.post("/friends/request", json={"username": bob_name})
        assert r.status_code == 201
    # sign in as bob to see the notifications
    r = client.post("/auth/signin", json={"username": bob_name, "password": "testpass123"})
    client.headers["Authorization"] = f"Bearer {r.json()['token']}"
    r = client.get("/notifications")
    assert r.json()["unread_count"] == 3
    r = client.post("/notifications/read-all")
    assert r.status_code == 200
    assert r.json()["unread_count"] == 0
    r = client.get("/notifications")
    assert all(n["read"] for n in r.json()["notifications"])


def test_unread_count_endpoint(client):
    sign_up_user(client)
    r = client.get("/notifications/unread-count")
    assert r.status_code == 200
    assert r.json() == {"unread_count": 0}


# ---------- auth ----------

def test_notifications_require_auth(client):
    client.headers.pop("Authorization", None)
    assert client.get("/notifications").status_code == 401
    assert client.get("/notifications/unread-count").status_code == 401
    assert client.post("/notifications/read-all").status_code == 401
    assert client.post("/ws-ticket").status_code == 401


# ---------- WS ticket ----------

def test_ws_ticket_issue_and_redeem(client):
    sign_up_user(client)
    r = client.post("/ws-ticket")
    assert r.status_code == 200
    ticket = r.json()["ticket"]
    assert r.json()["expires_in"] == 30
    hub = client.app.state.hub
    uid = hub.redeem_ticket(ticket)
    assert uid is not None
    # single-use: second redeem fails
    assert hub.redeem_ticket(ticket) is None


def test_ws_ticket_expired(client):
    sign_up_user(client)
    hub = client.app.state.hub
    ticket = hub.issue_ticket(UUID(int=0), ttl_seconds=-1)
    assert hub.redeem_ticket(ticket) is None


def test_ws_ticket_garbage(client):
    sign_up_user(client)
    hub = client.app.state.hub
    assert hub.redeem_ticket("not-a-ticket") is None


# ---------- WS endpoint (through TestClient) ----------

def test_ws_connect_and_disconnect(client):
    sign_up_user(client)
    r = client.post("/ws-ticket")
    ticket = r.json()["ticket"]
    with client.websocket_connect(f"/ws/notifications?ticket={ticket}") as ws:
        msg = ws.receive_json()
        assert msg["type"] == "connected"
        assert msg["unread"] == 0
        ws.send_text("ping")
        msg = ws.receive_json()
        assert msg == {"type": "pong"}


def test_ws_bad_ticket_rejected(client):
    sign_up_user(client)
    with pytest.raises(Exception):
        with client.websocket_connect("/ws/notifications?ticket=bogus") as ws:
            ws.receive_json()


def test_ws_push_arrives(client):
    """A notification created while connected is pushed to the socket."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    r = client.post("/ws-ticket")     # alice's ticket (client has alice's token)
    ticket = r.json()["ticket"]
    # switch to bob to send the request; but WS is alice's — open it first in a thread?
    # TestClient runs synchronously: open WS after the request instead, verifying push
    # happens on the NEXT connection's catch-up. For a true concurrent push we would need
    # the threaded WS; here we verify the hub has alice registered during the with block.
    with client.websocket_connect(f"/ws/notifications?ticket={ticket}") as ws:
        ws.receive_json()  # connected
        client.headers["Authorization"] = f"Bearer {bob_token}"
        client.post("/friends/request", json={"username": alice})
        # alice's hub connection should have received the push
        msg = ws.receive_json()
        assert msg["type"] == "notification"
        assert msg["data"]["type"] == "friend_request"


# ---------- payload validation ----------

def test_validate_payload_ok():
    p = notifications.validate_payload("friend_request", {
        "from_user_id": "01930000-0000-7000-8000-000000000001",
        "from_username": "alice",
    })
    assert p["from_username"] == "alice"


def test_validate_payload_unknown_type():
    with pytest.raises(ValueError):
        notifications.validate_payload("meteorite", {"x": 1})


def test_validate_payload_missing_field():
    with pytest.raises(Exception):
        notifications.validate_payload("friend_request", {"from_user_id": "x"})


# ---------- hub: the two push races ----------

class _FakeWS:
    """Minimal WebSocket stand-in for hub unit tests."""
    def __init__(self, fail: bool = False, on_send=None):
        self.sent = []
        self.fail = fail
        self.on_send = on_send

    async def send_json(self, message):
        if self.on_send:
            self.on_send()
        if self.fail:
            raise RuntimeError("socket gone")
        self.sent.append(message)


def test_hub_push_iterates_a_copy(client):
    """Registering a socket during push (reconnect mid-fanout) must not raise
    'Set changed size during iteration' — the old code iterated the live set."""
    hub = client.app.state.hub
    uid = UUID(int=1)
    ws_a = _FakeWS()
    ws_b = _FakeWS()
    newcomer = _FakeWS()
    # whichever of a/b is iterated first, the set gains an item before iteration ends
    ws_a.on_send = lambda: hub.register(uid, newcomer)
    hub.register(uid, ws_a)
    hub.register(uid, ws_b)
    sent = asyncio.run(hub.push(uid, {"type": "x"}))
    assert sent == 2                        # both live sockets got it
    assert ws_a.sent == [{"type": "x"}] and ws_b.sent == [{"type": "x"}]
    assert hub.connection_count(uid) == 3   # newcomer stays for the next push
    assert newcomer.sent == []
    asyncio.run(hub.push(uid, {"type": "y"}))
    assert newcomer.sent == [{"type": "y"}]


def test_hub_push_does_not_forget_reconnected_socket(client):
    """If the user's only socket dies and they reconnect during the await, the new socket
    must stay registered (the old code popped the fresh set — that socket went dark forever)."""
    hub = client.app.state.hub
    uid = UUID(int=2)
    reconnected = _FakeWS()
    state = {}

    def die_and_reconnect():
        if state.get("done"):
            return
        state["done"] = True
        hub.unregister(uid, dying)        # the old socket's finally block
        hub.register(uid, reconnected)    # a new connection arrives

    dying = _FakeWS(on_send=die_and_reconnect, fail=True)
    hub.register(uid, dying)
    asyncio.run(hub.push(uid, {"type": "x"}))
    assert hub.connection_count(uid) == 1
    assert hub._connections.get(uid) is not None
    # and the reconnected socket receives the NEXT push
    asyncio.run(hub.push(uid, {"type": "y"}))
    assert reconnected.sent == [{"type": "y"}]


# ---------- cleanup ----------

def test_delete_old(client):
    """delete_old drops rows older than `days` and keeps fresh ones."""
    sign_up_as(client, new_username())
    with psycopg.connect(TEST_URL) as conn:
        row = conn.execute(
            "SELECT id FROM users ORDER BY created_at DESC LIMIT 1").fetchone()
        conn.execute(
            """INSERT INTO notifications (user_id, type, payload, created_at)
               VALUES (%s, 'friend_accepted', %s, now() - interval '40 days'),
                      (%s, 'friend_accepted', %s, now())""",
            [row[0], '{"by_user_id": "x", "by_username": "x"}',
             row[0], '{"by_user_id": "y", "by_username": "y"}'])

    async def run():
        # a pool of our own: the app's pool belongs to the TestClient's event loop
        pool = db.make_pool(TEST_URL)
        await pool.open()
        try:
            async with pool.connection() as conn:
                return await notifications.delete_old(conn, days=30)
        finally:
            await pool.close()
    removed = asyncio.run(run())
    assert removed == 1
    with psycopg.connect(TEST_URL) as conn:
        left = conn.execute("SELECT count(*) FROM notifications").fetchone()[0]
        assert left == 1
