"""The database connection pool and schema.

A pool keeps a few connections open and lends them out per request, instead of opening a new
connection (slow: a handshake every time) for every request.
"""
from pathlib import Path

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from music_backend.settings import settings

DATABASE_URL = settings.database_url        # from .env or the environment; see settings.py
SCHEMA = Path(__file__).resolve().parents[2] / "schema.sql"   # backend/schema.sql


def make_pool(url: str) -> AsyncConnectionPool:
    # dict_row: rows come back as {"column": value} instead of bare tuples
    return AsyncConnectionPool(url, open = False, kwargs = {"row_factory" : dict_row})


async def apply_schema(pool: AsyncConnectionPool) -> None:
    """Create any missing tables. Every statement is IF NOT EXISTS, so this is safe on every start."""
    async with pool.connection() as conn:
        await conn.execute(SCHEMA.read_text())
