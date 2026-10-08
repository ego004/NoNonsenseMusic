"""What every test file shares. pytest finds this file by itself: no file imports it.

- anyio_backend: the async tests (marked @pytest.mark.anyio) run on asyncio. It was written out in 6 files.
- pool: a connection pool on the test database, with the schema applied. A file that needs more (test_library drops
  the tables first; test_lyrics_cache cleans its rows afterwards) defines its own `pool`, which wins for that file.
- sign_up(client): AUTH-3 made every route but /health, /auth/signup and /auth/signin need a token. This signs up a
  fresh account through the real route and puts its token on the test client, so later requests are that user.
- user_id: a fresh account for tests that call the library functions directly.
Test accounts are named test-<random>; they are deleted once all the tests have run (their rows go with them).
"""
from uuid import uuid4

import psycopg
import pytest

from music_backend.core import db
from music_backend.services import auth

TEST_URL = "postgresql:///music_test"      # never your library: tests write and delete


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def pool():
    pool = db.make_pool(TEST_URL)
    await pool.open()
    await db.apply_schema(pool)
    yield pool
    await pool.close()


def new_username():
    return "test-" + uuid4().hex[:10]


def sign_up(client, username=None) -> dict:
    """Sign up through /auth/signup and send that token from now on. Returns the body: {"token", "user"}."""
    r = client.post("/auth/signup", json={"username": username or new_username(), "password": "a test password"})
    assert r.status_code == 201, r.text
    session = r.json()
    client.headers["Authorization"] = f"Bearer {session['token']}"
    return session


@pytest.fixture
async def user_id(pool):
    async with pool.connection() as conn:
        return (await auth.create_user(conn, new_username(), "a test password")).id


@pytest.fixture(scope="session", autouse=True)
def _delete_test_accounts():
    yield
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("DELETE FROM users WHERE username LIKE 'test-%'")
