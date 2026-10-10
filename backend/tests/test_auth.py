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
    open_routes = {"/health", "/auth/signup", "/auth/signin", "/auth/recover", "/p/{playlist_id}"}   # /p: a link page, names nothing
    checked = 0
    for route in app.routes:
        if not hasattr(route, "dependant") or route.path in open_routes:
            continue
        if not hasattr(route, "methods"):          # WebSocket routes have no methods (FRIENDS-1 Phase 2)
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


# ---------- recovery codes ----------

def test_sign_up_shows_ten_codes_once_and_stores_only_their_hashes(client):
    session = sign_up(client)
    codes = session["recovery_codes"]
    assert len(codes) == 10 and len(set(codes)) == 10
    assert all(len(c) == 19 and c.count("-") == 3 for c in codes)                 # XXXX-XXXX-XXXX-XXXX
    stored = [bytes(r[0]) for r in sql("SELECT code_hash FROM recovery_codes WHERE user_id = %s", [session["user"]["id"]])]
    assert sorted(stored) == sorted(hashlib.sha256(c.replace("-", "").encode()).digest() for c in codes)
    assert client.get("/auth/recovery-codes").json() == {"left": 10}
    assert sign_in(client, session["user"]["username"]).json().get("recovery_codes") is None   # never again


def test_a_code_resets_the_password_signs_out_everywhere_and_works_once(client):
    name = new_username()
    session = sign_up(client, name)
    old_token, code = session["token"], session["recovery_codes"][3]
    typed = code.lower().replace("-", " ").replace("0", "o")          # as a person might type it back
    r = client.post("/auth/recover", json={"username": name.upper().replace("TEST-", "test-"), "code": typed,
                                            "new_password": "a new password", "device_name": "Kai's laptop"})
    assert r.status_code == 200
    assert client.get("/auth/me", headers=bearer(old_token)).status_code == 401     # every old session ended
    assert client.get("/auth/me", headers=bearer(r.json()["token"])).status_code == 200
    assert sign_in(client, name).status_code == 401                                 # the old password is gone
    assert sign_in(client, name, "a new password").status_code == 200
    again = client.post("/auth/recover", json={"username": name, "code": code, "new_password": "another one"})
    assert again.status_code == 401                                                 # used up
    assert client.get("/auth/recovery-codes", headers=bearer(r.json()["token"])).json() == {"left": 9}


def test_a_wrong_code_and_an_unknown_name_answer_the_same(client):
    name = new_username()
    sign_up(client, name)
    wrong = client.post("/auth/recover", json={"username": name, "code": "AAAA-AAAA-AAAA-AAAA", "new_password": PASSWORD})
    unknown = client.post("/auth/recover", json={"username": new_username(), "code": "AAAA-AAAA-AAAA-AAAA", "new_password": PASSWORD})
    assert wrong.status_code == unknown.status_code == 401 and wrong.json() == unknown.json()
    assert sign_in(client, name).status_code == 200                                 # nothing changed


def test_someone_elses_code_does_not_work(client):
    alex, sam = sign_up(client), sign_up(client)
    r = client.post("/auth/recover", json={"username": alex["user"]["username"], "code": sam["recovery_codes"][0],
                                            "new_password": "taken over"})
    assert r.status_code == 401


def test_a_new_set_needs_the_password_and_replaces_the_old(client):
    name = new_username()
    first = sign_up(client, name)["recovery_codes"]
    assert client.post("/auth/recovery-codes", json={"password": "not it"}).status_code == 401
    r = client.post("/auth/recovery-codes", json={"password": PASSWORD})
    assert r.status_code == 200 and len(r.json()["codes"]) == 10 and set(r.json()["codes"]).isdisjoint(first)
    old = client.post("/auth/recover", json={"username": name, "code": first[0], "new_password": "a new password"})
    assert old.status_code == 401                                                   # the old set stopped working


@pytest.mark.anyio
async def test_two_resets_with_one_code_at_once_only_one_wins(pool, user_id):
    from music_backend.services import auth
    async with pool.connection() as conn:
        code = (await auth.replace_recovery_codes(conn, user_id))[0]
        name = (await (await conn.execute("SELECT username FROM users WHERE id = %s", [user_id])).fetchone())["username"]

    async def attempt(password):
        async with pool.connection() as conn:
            try:
                await auth.recover(conn, name, code, password)
                return True
            except auth.WrongRecovery:
                return False
    import asyncio
    results = await asyncio.gather(attempt("first password"), attempt("second password"))
    assert sorted(results) == [False, True]
