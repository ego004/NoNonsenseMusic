"""AUTH-3, once per existing database: likes, plays and playlists get an owner.

    cd ~/projects/music/backend && uv run python scripts/migrate_auth3.py --username <you>

Gives every existing like, play and playlist to that account (made here if it does not exist yet: the password is
typed in this terminal, never shown, stored only as its Argon2id hash), then turns on the per-user rules: user_id
required, a like unique per person and song, a playlist name unique per person. One transaction: if any step fails,
nothing changes. A database made after AUTH-3 (fresh from schema.sql) never needs this; the server refuses to start
on one that needs it and has not had it (db.apply_schema).
"""
import argparse
import asyncio
import getpass

import psycopg
from psycopg.rows import dict_row

from music_backend.core import db
from music_backend.core.settings import settings
from music_backend.models import User
from music_backend.services import auth


async def main(username: str) -> None:
    async with await psycopg.AsyncConnection.connect(settings.database_url, row_factory=dict_row) as conn:
        if not await db.needs_auth3(conn):
            print("Nothing to do: this database already has per-user likes, plays and playlists.")
            return
        async with conn.transaction():
            # 1. the columns, empty: schema.sql's new indexes need them to exist
            for table in ("likes", "events", "playlists"):
                await conn.execute(f"ALTER TABLE {table} ADD COLUMN user_id uuid")
            # 2. everything else schema.sql adds (users and sessions if missing, the new indexes)
            await conn.execute(db.SCHEMA.read_text())
            # 3. the owner
            row = await (await conn.execute("SELECT id, username FROM users WHERE lower(username) = lower(%s)", [username])).fetchone()
            if row is None:
                print(f"No account named {username!r} yet: making it.")
                password = getpass.getpass("Password for it (8 to 64 characters): ")
                if getpass.getpass("Again: ") != password:
                    raise SystemExit("The two passwords differ: nothing was changed.")
                owner = await auth.create_user(conn, username, password)
            else:
                owner = User(id=row["id"], username=row["username"])
            # 4. every existing row is the owner's
            moved = {}
            for table in ("likes", "events", "playlists"):
                moved[table] = (await conn.execute(f"UPDATE {table} SET user_id = %s", [owner.id])).rowcount
            # 5. the rules
            await conn.execute("""
                ALTER TABLE likes ALTER COLUMN user_id SET NOT NULL,
                    ADD FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
                    DROP CONSTRAINT likes_pkey, ADD PRIMARY KEY (user_id, song_id);
                ALTER TABLE events ALTER COLUMN user_id SET NOT NULL,
                    ADD FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;
                ALTER TABLE playlists ALTER COLUMN user_id SET NOT NULL,
                    ADD FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
                    DROP CONSTRAINT playlists_name_key,
                    ADD CONSTRAINT playlists_user_id_name_key UNIQUE (user_id, name);
            """)
        print(f"Done: {moved['likes']} likes, {moved['events']} plays and {moved['playlists']} playlists are {owner.username}'s.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--username", required=True, help="the account that gets the existing library")
    asyncio.run(main(parser.parse_args().username))
