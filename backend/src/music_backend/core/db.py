"""The database connection pool and schema.

A pool keeps a few connections open and lends them out per request, instead of opening a new
connection (slow: a handshake every time) for every request.
"""
from pathlib import Path

from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from music_backend.core.settings import settings

DATABASE_URL = settings.database_url        # from .env or the environment; see settings.py
SCHEMA = Path(__file__).resolve().parents[3] / "schema.sql"   # backend/schema.sql (this file: backend/src/music_backend/core/)


def make_pool(url: str) -> AsyncConnectionPool:
    # dict_row: rows come back as {"column": value} instead of bare tuples.
    # One connection kept open, up to 8 under load (4 prefetch workers and your requests), extras closed after a
    # minute idle. The default kept 4 open all the time: 4 Postgres processes, 7-11 MB each (measured 7 Oct)
    return AsyncConnectionPool(url, open = False, kwargs = {"row_factory" : dict_row},
                               min_size = 1, max_size = 8, max_idle = 60)


async def needs_auth3(conn: AsyncConnection) -> bool:
    """A database from before accounts: its likes table exists but has no owner column. schema.sql only creates what is
    missing, so it cannot change those tables: scripts/migrate_auth3.py does, once."""
    row = await (await conn.execute(
        """SELECT to_regclass('likes') IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                                   WHERE table_name = 'likes' AND column_name = 'user_id') AS needs""")).fetchone()
    return row["needs"]


async def apply_schema(pool: AsyncConnectionPool) -> None:
    """Create any missing tables. Every statement is IF NOT EXISTS, so this is safe on every start."""
    async with pool.connection() as conn:
        if await needs_auth3(conn):
            raise RuntimeError("This database is from before accounts. Run once, then start again:  "
                               "cd ~/projects/music/backend && uv run python scripts/migrate_auth3.py --username <you>")
        await conn.execute(SCHEMA.read_text())
