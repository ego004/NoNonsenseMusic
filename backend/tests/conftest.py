"""What every test file shares. pytest finds this file by itself: no file imports it.

- anyio_backend: the async tests (marked @pytest.mark.anyio) run on asyncio. It was written out in 6 files.
- pool: a connection pool on the test database, with the schema applied. A file that needs more (test_library drops
  the tables first; test_lyrics_cache cleans its rows afterwards) defines its own `pool`, which wins for that file.
"""
import pytest

from music_backend import db

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
