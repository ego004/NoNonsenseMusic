"""AUTH-1: accounts and sessions, through the real routes, against music_test."""
import hashlib
from uuid import uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import Listing
from conftest import TEST_URL, new_username, sign_up

PASSWORD = "a test password"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def sign_in(client, username, password=PASSWORD):
    return client.post("/auth/signin", json={"username": username, "password": password})


def sql(query, params=()):
    with psycopg.connect(TEST_URL) as conn:
        cur = conn.execute(query, params)
        return cur.fetchall() if cur.description else None      # an UPDATE has no rows to fetch


# ---------- sign up ----------

def test_sign_up_answers_a_token_and_the_user(client):
    name = new_username()
    session = sign_up(client, name)
    assert session["user"]["username"] == name and len(session["token"]) >= 40
    assert client.get("/auth/me").json() == session["user"]


def test_a_taken_username_answers_409_whatever_its_case(client):
    name = new_username()
    sign_up(client, name)
    r = client.post("/auth/signup", json={"username": name.upper().replace("TEST-", "test-"), "password": PASSWORD})
    assert r.status_code == 409


@pytest.mark.parametrize("body", [
    {"username": "ab", "password": PASSWORD},                   # username under 3
    {"username": "x" * 33, "password": PASSWORD},               # over 32
    {"username": "test-ok", "password": "short"},               # password under 8
    {"username": "test-ok", "password": "p" * 65},              # over 64
])
def test_bad_sign_up_answers_422(client, body):
    assert client.post("/auth/signup", json=body).status_code == 422


def test_the_database_holds_no_password_and_no_token(client):
    session = sign_up(client)
    user = session["user"]["id"]
    (password_hash,), = sql("SELECT password_hash FROM users WHERE id = %s", [user])
    assert password_hash.startswith("$argon2id$") and PASSWORD not in password_hash
    stored = [bytes(r[0]) for r in sql("SELECT token_hash FROM sessions WHERE user_id = %s", [user])]
    assert stored == [hashlib.sha256(session["token"].encode()).digest()]     # the hash, never the token


# ---------- sign in ----------

def test_sign_in_gives_a_second_session(client):
    name = new_username()
    first = sign_up(client, name)
    r = sign_in(client, name)
    assert r.status_code == 200 and r.json()["token"] != first["token"]
    assert len(sql("SELECT 1 FROM sessions WHERE user_id = %s", [first["user"]["id"]])) == 2


def test_wrong_password_and_unknown_user_answer_the_same(client):
    name = new_username()
    sign_up(client, name)
    wrong, unknown = sign_in(client, name, "not the password"), sign_in(client, new_username())
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json()          # nothing tells an attacker which usernames exist


# ---------- the token ----------

@pytest.mark.parametrize("header", [None, "", "Bearer", "Bearer nonsense", "Basic dXNlcjpwYXNz", "bearer"])
def test_no_or_a_bad_token_answers_401_with_the_bearer_challenge(client, header):
    headers = {} if header is None else {"Authorization": header}
    r = client.get("/auth/me", headers=headers)
    assert r.status_code == 401 and r.headers["www-authenticate"] == "Bearer"


def test_sign_out_ends_that_session_only(client):
    name = new_username()
    phone = sign_up(client, name)["token"]
    laptop = sign_in(client, name).json()["token"]
    assert client.post("/auth/signout", headers=bearer(phone)).status_code == 204
    assert client.get("/auth/me", headers=bearer(phone)).status_code == 401
    assert client.get("/auth/me", headers=bearer(laptop)).status_code == 200


def test_an_expired_session_answers_401_and_is_deleted(client):
    session = sign_up(client)
    token_hash = hashlib.sha256(session["token"].encode()).digest()
    sql("UPDATE sessions SET expires_at = now() - interval '1 second' WHERE token_hash = %s", [token_hash])
    assert client.get("/auth/me").status_code == 401
    assert sql("SELECT 1 FROM sessions WHERE token_hash = %s", [token_hash]) == []      # the delete committed


def test_use_slides_the_expiry_but_at_most_once_an_hour(client):
    session = sign_up(client)
    token_hash = hashlib.sha256(session["token"].encode()).digest()
    expiry = lambda: sql("SELECT expires_at FROM sessions WHERE token_hash = %s", [token_hash])[0][0]
    before = expiry()
    client.get("/auth/me")
    assert expiry() == before                                   # used a moment ago: no write
    sql("UPDATE sessions SET last_used_at = now() - interval '2 hours', expires_at = now() + interval '1 day' "
        "WHERE token_hash = %s", [token_hash])
    client.get("/auth/me")
    assert (expiry() - before).total_seconds() > -60           # back to 30 days from now


# ---------- every route but three needs it ----------

def test_every_route_but_health_signup_and_signin_answers_401_without_a_token(client):
    from music_backend.main import app
    open_routes = {"/health", "/auth/signup", "/auth/signin", "/p/{playlist_id}"}   # /p: a link page, names nothing
    checked = 0
    for route in app.routes:
        if not hasattr(route, "dependant") or route.path in open_routes:
            continue
        path = route.path
        for name in route.param_convertors:
            path = path.replace("{" + name + "}", str(uuid4()))
        path = path.replace("{source}", "ytmusic").replace("{source_id}", "x")
        for method in route.methods - {"HEAD"}:
            r = client.request(method, path, json={})
            assert r.status_code == 401, (method, route.path, r.status_code)
            checked += 1
    assert checked >= 20


# ---------- each user has their own library ----------

def test_likes_and_plays_are_per_user(client):
    body = {"listings": [Listing(source="jiosaavn", id=f"auth-{uuid4().hex[:8]}", title="Song", artists=["Artist"],
                                 album=None, duration=200, popularity=None).model_dump()]}
    alex, sam = sign_up(client)["token"], sign_up(client)["token"]
    song = client.post("/liked", json=body, headers=bearer(alex)).json()["song_id"]
    client.post("/events", json=body | {"type": "play", "position": 0}, headers=bearer(alex))
    assert [s["id"] for s in client.get("/liked", headers=bearer(alex)).json()] == [song]
    assert client.get("/liked", headers=bearer(sam)).json() == []
    assert client.get("/recent", headers=bearer(sam)).json() == []
    assert client.delete(f"/liked/{song}", headers=bearer(sam)).status_code == 404     # Sam cannot unlike Alex's


# ---------- expired sessions are cleaned up ----------

def test_expired_sessions_are_deleted_at_startup_and_live_ones_kept(monkeypatch):
    # a device that never comes back: its expired session went only when its token was used again (8 Oct)
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        gone, kept = sign_up(client)["token"], sign_up(client)["token"]
    gone_hash, kept_hash = (hashlib.sha256(t.encode()).digest() for t in (gone, kept))
    sql("UPDATE sessions SET expires_at = now() - interval '1 day' WHERE token_hash = %s", [gone_hash])
    with TestClient(app):                                        # a restart: the cleanup runs at once
        assert sql("SELECT 1 FROM sessions WHERE token_hash = %s", [gone_hash]) == []
        assert len(sql("SELECT 1 FROM sessions WHERE token_hash = %s", [kept_hash])) == 1
    assert app.state.session_cleanup.done()                      # and stops with the server


def test_a_device_renames_its_own_session_only(client):
    name = new_username()
    phone = sign_up(client, name)["token"]
    laptop = sign_in(client, name).json()["token"]
    assert client.patch("/auth/me/device", json={"device_name": "Kai's phone"}, headers=bearer(phone)).status_code == 204
    names = dict(sql("SELECT token_hash, device_name FROM sessions WHERE token_hash = ANY(%s)",
                     [[hashlib.sha256(t.encode()).digest() for t in (phone, laptop)]]))
    assert names[hashlib.sha256(phone.encode()).digest()] == "Kai's phone"
    assert names[hashlib.sha256(laptop.encode()).digest()] == "Unknown Device"
    assert client.patch("/auth/me/device", json={"device_name": ""}, headers=bearer(phone)).status_code == 422
    assert client.patch("/auth/me/device", json={"device_name": "x"}, headers={"Authorization": ""}).status_code == 401
