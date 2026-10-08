import hashlib
import asyncio
from uuid import UUID
import secrets
from music_backend.core.settings import settings
from argon2 import PasswordHasher
from fastapi import Header, HTTPException, Request
from psycopg import AsyncConnection, errors
from music_backend.models import User
from argon2.exceptions import VerifyMismatchError


class UsernameTaken(Exception):
    pass

class WrongCredentials(Exception):
    pass

hasher = PasswordHasher()
DUMMY_HASH = hasher.hash("anything")

def hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode('utf-8')).digest()

async def create_user(conn, username:str, password:str) -> User:
    h = await asyncio.to_thread(hasher.hash, password)
    try:
        row = await (await conn.execute("INSERT INTO users (username, password_hash) VALUES (%s, %s) RETURNING id", (username, h))).fetchone()
    except errors.UniqueViolation as e:
        raise UsernameTaken() from e
    return User(username=username,id=row["id"])

async def create_session_token(conn: AsyncConnection, user_id: UUID, device_name: str) -> str:
    """A new session (one signed-in device): the token is returned, only its hash is stored. It ends after
    settings.session_days without use; PostgreSQL works out the date, so one clock decides."""
    token = secrets.token_urlsafe(32)
    await conn.execute(
        """INSERT INTO sessions (token_hash, user_id, device_name, expires_at)
           VALUES (%s, %s, %s, now() + make_interval(days => %s))""",
        (hash_token(token), user_id, device_name, settings.session_days))
    return token

async def check_password(conn, username:str, password:str) -> User:
    row = await (await conn.execute(
        "SELECT id, username, password_hash FROM users WHERE lower(username) = lower(%s)",
        [username])).fetchone()
    if row is None:
        try:
            await asyncio.to_thread(hasher.verify,DUMMY_HASH, password)
        finally:
            raise WrongCredentials("Invalid username or password")
    try:
        if await asyncio.to_thread(hasher.verify,row["password_hash"], password):
            return User(username=row["username"], id=row["id"])
    except VerifyMismatchError as e:
        raise WrongCredentials("Invalid username or password") from e

class InvalidSession(Exception):
    """No such session, or it has ended: the caller must sign in again."""


async def verify_current_session_token(conn: AsyncConnection, token: str) -> User:
    """The user this token belongs to, if its session is still alive. Called on every request (through current_user)."""
    token_hash = hash_token(token)                  # the table holds hashes only: look the token up by its hash

    # the session and its user in one query (a JOIN: sessions.user_id points at users.id)
    row = await (await conn.execute(
        """SELECT u.id, u.username, s.expires_at <= now() AS expired
             FROM sessions s
             JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = %s""",
        [token_hash])).fetchone()

    if row is None:                                 # never existed, or signed out
        raise InvalidSession()
    if row["expired"]:                              # it existed, but went unused for session_days: tidy it away
        await delete_session(conn, token)
        raise InvalidSession()

    # sliding: this use pushes the end forward again. At most once every session_slide_minutes, so most requests only
    # read; when it was slid recently the WHERE matches nothing and the statement does nothing
    await conn.execute(
        """UPDATE sessions
              SET last_used_at = now(), expires_at = now() + make_interval(days => %s)
            WHERE token_hash = %s
              AND last_used_at < now() - make_interval(mins => %s)""",
        [settings.session_days, token_hash, settings.session_slide_minutes])

    return User(id=row["id"], username=row["username"])


async def current_user(request: Request, authorization: str | None = Header(default=None)) -> User:
    """The FastAPI side of the check: a route that writes `user: User = Depends(auth.current_user)` runs only for a
    signed-in request, and gets its user. FastAPI fills both parameters: the request (for the pool) and the
    Authorization header ("Bearer <token>", or None when the app sent none)."""
    # 401 = "who are you?"; the WWW-Authenticate header is HTTP's standard way to say "send a Bearer token"
    unauthorised = HTTPException(status_code=401, detail="Sign in first", headers={"WWW-Authenticate": "Bearer"})

    scheme, _, token = (authorization or "").partition(" ")     # "Bearer abc" -> ("Bearer", " ", "abc")
    if scheme != "Bearer" or not token:
        raise unauthorised

    # its own connection: this runs before the route, which borrows its own afterwards
    async with request.app.state.pool.connection() as conn:
        try:
            return await verify_current_session_token(conn, token)
        except InvalidSession:
            pass
    # the 401 is raised only here, after the block has ended normally: a borrowed connection commits when its block
    # ends and rolls back when an exception leaves it, so raising inside undid the deletion of an expired session
    raise unauthorised

async def delete_session(conn: AsyncConnection, token: str) -> None:
    await conn.execute("DELETE FROM sessions WHERE token_hash = %s", [hash_token(token)])

async def delete_expired_sessions(conn: AsyncConnection) -> int:
    """Every expired session, at once; how many went. A session is otherwise deleted only when its token is used again,
    so a device that never comes back would keep its row (and its device name) for good."""
    return (await conn.execute("DELETE FROM sessions WHERE expires_at < now()")).rowcount

async def clean_sessions_forever(pool) -> None:
    """The server's cleanup task: every `session_cleanup_hours`, until the server stops (cancelled). The first round
    runs at startup, before any request (main.lifespan)."""
    while True:
        await asyncio.sleep(settings.session_cleanup_hours * 3600)
        async with pool.connection() as conn:
            await delete_expired_sessions(conn)
