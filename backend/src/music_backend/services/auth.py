"""Session, password and recovery-code authentication.

Tokens are stored only as SHA-256 hashes, passwords with Argon2. A forgotten
password is reset with a printed recovery code rather than email.
"""
import hashlib
import asyncio
import logging
from uuid import UUID
import secrets
from concurrent.futures import ThreadPoolExecutor
from music_backend.core.settings import settings
from argon2 import PasswordHasher
from fastapi import Header, HTTPException, Request
from psycopg import AsyncConnection, errors
from music_backend.models import User
from argon2.exceptions import VerifyMismatchError

logger = logging.getLogger(__name__)


class UsernameTaken(Exception):
    pass

class WrongCredentials(Exception):
    pass

hasher = PasswordHasher()
# A real Argon2 hash to verify against when no user matches, so an unknown
# username costs about the same time as a wrong password.
DUMMY_HASH = hasher.hash("anything")

# Argon2 runs here, not in asyncio's shared pool: each hash takes 64 MiB and ~0.15 s of CPU (measured 11 Oct on a 1 vCPU
# server), so a burst of sign-ins from many addresses would otherwise fill the threads that searches and lyrics wait
# on, and its memory would grow with every thread. Two at a time bounds it at 128 MiB; more would only share the CPU.
HASHING = ThreadPoolExecutor(max_workers=2, thread_name_prefix="argon2")


async def _hashing(fn, *args):
    """Run a password hash or check on the HASHING threads."""
    return await asyncio.get_running_loop().run_in_executor(HASHING, fn, *args)

def hash_token(token: str) -> bytes:
    """Return the SHA-256 digest of a token, which is the form stored in the database."""
    return hashlib.sha256(token.encode('utf-8')).digest()

async def create_user(conn, username:str, password:str) -> User:
    """Insert a user and return the created record.

    The password is hashed off the event loop. Raises UsernameTaken when the
    username is already registered.
    """
    h = await _hashing(hasher.hash, password)
    try:
        row = await (await conn.execute("INSERT INTO users (username, password_hash) VALUES (%s, %s) RETURNING id", (username, h))).fetchone()
    except errors.UniqueViolation as e:
        raise UsernameTaken() from e
    return User(username=username,id=row["id"])

async def create_session_token(conn: AsyncConnection, user_id: UUID, device_name: str) -> str:
    """Return a new session token for one signed-in device, storing only its hash.

    The session ends after settings.session_days without use; PostgreSQL computes
    the expiry date, so a single clock decides it.
    """
    token = secrets.token_urlsafe(32)
    await conn.execute(
        """INSERT INTO sessions (token_hash, user_id, device_name, expires_at)
           VALUES (%s, %s, %s, now() + make_interval(days => %s))""",
        (hash_token(token), user_id, device_name, settings.session_days))
    return token

async def check_password(conn, username:str, password:str) -> User:
    """Return the user whose username and password match.

    Raises WrongCredentials for an unknown username or a wrong password, with the
    same message for both. An unknown username is verified against DUMMY_HASH so
    the two cases cost about the same time.
    """
    row = await (await conn.execute(
        "SELECT id, username, password_hash FROM users WHERE lower(username) = lower(%s)",
        [username])).fetchone()
    if row is None:
        try:
            await _hashing(hasher.verify, DUMMY_HASH, password)
        finally:
            raise WrongCredentials("Invalid username or password")
    try:
        if await _hashing(hasher.verify, row["password_hash"], password):
            return User(username=row["username"], id=row["id"])
    except VerifyMismatchError as e:
        raise WrongCredentials("Invalid username or password") from e

class InvalidSession(Exception):
    """Report an unknown session or one that has ended: the caller must sign in again."""


async def verify_current_session_token(conn: AsyncConnection, token: str) -> User:
    """Return the user a token belongs to while its session is alive.

    Runs on every request, through current_user. Raises InvalidSession when the
    token is unknown or its session has expired.
    """
    token_hash = hash_token(token)                  # the table holds hashes only: look the token up by its hash

    # session and user in one query (a JOIN: sessions.user_id points at users.id)
    row = await (await conn.execute(
        """SELECT u.id, u.username, s.expires_at <= now() AS expired
             FROM sessions s
             JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = %s""",
        [token_hash])).fetchone()

    if row is None:                                 # never existed, or signed out
        raise InvalidSession()
    if row["expired"]:                              # went unused for session_days: tidy it away, then reject
        await delete_session(conn, token)
        raise InvalidSession()

    # Sliding expiry: this use pushes the end forward again, but at most once every
    # session_slide_minutes, so most requests only read; when the last slide is recent
    # the WHERE matches nothing and the statement changes no rows
    await conn.execute(
        """UPDATE sessions
              SET last_used_at = now(), expires_at = now() + make_interval(days => %s)
            WHERE token_hash = %s
              AND last_used_at < now() - make_interval(mins => %s)""",
        [settings.session_days, token_hash, settings.session_slide_minutes])

    return User(id=row["id"], username=row["username"])


async def current_user(request: Request, authorization: str | None = Header(default=None)) -> User:
    """FastAPI dependency that returns the signed-in user of a request.

    A route declares it as `user: User = Depends(auth.current_user)`, runs only for
    a signed-in request, and receives its user. FastAPI fills both parameters: the
    request (for the pool) and the Authorization header ("Bearer <token>"), which is
    None when the client sent no header.
    """
    # 401 = "who are you?"; WWW-Authenticate is HTTP's standard way to ask for a Bearer token
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
    """Delete every expired session at once and return how many were deleted.

    A session is otherwise deleted only when its token is used again, so a device
    that never comes back keeps its row, and its device name, for good.
    """
    return (await conn.execute("DELETE FROM sessions WHERE expires_at < now()")).rowcount

async def clean_sessions_forever(pool) -> None:
    """Delete expired sessions every session_cleanup_hours, until the server stops.

    The task starts at startup, before any request (main.lifespan); the first round
    runs after one interval.
    """
    while True:
        await asyncio.sleep(settings.session_cleanup_hours * 3600)
        try:
            async with pool.connection() as conn:
                await delete_expired_sessions(conn)
        except Exception as e:
            # a database that is briefly down must not end the loop for good: the next round tries again.
            # Only the error's class is logged; its text can carry statement values
            logger.warning("session cleanup failed: %s", type(e).__name__)

async def rename_session(conn: AsyncConnection, token: str, device_name: str) -> None:
    """Rename the device of the session a token belongs to.

    The user chooses the name at sign-in and may change it later.
    """
    await conn.execute("UPDATE sessions SET device_name = %s WHERE token_hash = %s", [device_name, hash_token(token)])


# ---------- recovery codes ----------
# There is no email: a forgotten password is reset with one of ten codes the user kept. Crockford's base 32 (no I, L,
# O or U), 16 characters in groups of four: 80 random bits each. Typed back, case, spaces and dashes are ignored, and
# O, I and L read as 0, 1 and 1, the mistakes people make copying them.

RECOVERY_CODES = 10
_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

class WrongRecovery(Exception):
    pass

def new_recovery_code() -> str:
    """Return one code: 16 characters of the alphabet in groups of four."""
    raw = "".join(secrets.choice(_ALPHABET) for _ in range(16))
    return "-".join(raw[i:i + 4] for i in range(0, 16, 4))

def hash_recovery_code(text: str) -> bytes:
    """Return the SHA-256 digest of a code in its normalised form.

    Upper-case, spaces and dashes are dropped, and O, I and L read as 0, 1 and 1,
    so a code typed with those mistakes still matches.
    """
    plain = "".join(c for c in text.upper() if c.isalnum()).replace("O", "0").replace("I", "1").replace("L", "1")
    return hashlib.sha256(plain.encode()).digest()

async def replace_recovery_codes(conn: AsyncConnection, user_id: UUID) -> list[str]:
    """Replace a user's codes with a new set of ten and return them.

    The old set stops working. Codes are shown once and never stored as they are.
    """
    codes = [new_recovery_code() for _ in range(RECOVERY_CODES)]
    async with conn.transaction():
        await conn.execute("DELETE FROM recovery_codes WHERE user_id = %s", [user_id])
        async with conn.cursor() as cur:
            await cur.executemany("INSERT INTO recovery_codes (user_id, code_hash) VALUES (%s, %s)",
                                  [(user_id, hash_recovery_code(c)) for c in codes])
    return codes

async def recovery_codes_left(conn: AsyncConnection, user_id: UUID) -> int:
    return (await (await conn.execute("SELECT count(*) AS n FROM recovery_codes WHERE user_id = %s", [user_id])).fetchone())["n"]

async def recover(conn: AsyncConnection, username: str, code: str, new_password: str) -> User:
    """Use one recovery code to set a new password, all or none in one transaction.

    The code is used up, the password replaced and every session ended, so the user
    is signed out everywhere. Raises WrongRecovery for an unknown username or a code
    that is not, or no longer, the user's: one answer for both.
    """
    async with conn.transaction():
        row = await (await conn.execute(
            "SELECT id, username FROM users WHERE lower(username) = lower(%s)", [username])).fetchone()
        used = None
        if row is not None:
            used = await (await conn.execute(
                "DELETE FROM recovery_codes WHERE user_id = %s AND code_hash = %s RETURNING user_id",
                [row["id"], hash_recovery_code(code)])).fetchone()
        if used is None:
            raise WrongRecovery()
        password_hash = await _hashing(hasher.hash, new_password)
        await conn.execute("UPDATE users SET password_hash = %s WHERE id = %s", [password_hash, row["id"]])
        await conn.execute("DELETE FROM sessions WHERE user_id = %s", [row["id"]])
    return User(id=row["id"], username=row["username"])
