"""Notifications: persist them, and push them over a WebSocket when the user is connected.

Two halves, deliberately separated:

* The DB half (create / list / mark_read) is plain functions on a connection, like friends.py.
  Any service can call create() inside its own transaction — so the notification is written
  or the whole action rolls back, never half-done.

* The push half (NotificationHub) holds the open WebSocket connections. It is not aware of
  the database: after a row is committed the caller (main.py) asks the hub to fan the message
  out. Connections are kept per user AND per socket — one person on phone + desktop gets both.

Failures in push never undo a committed row: a dropped socket is cleaned up, not an error.
"""
import asyncio
import json
import logging
import secrets
import time
from typing import Any, Literal
from uuid import UUID

from fastapi import WebSocket
from psycopg import AsyncConnection

from music_backend.models import (NOTIFICATION_PAYLOAD_MODELS, Notification,
                                  NotificationsResponse)

logger = logging.getLogger(__name__)


# ---------- payload validation ----------

def validate_payload(notification_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Check the payload against its Pydantic model before it reaches the database.

    Unknown type or a malformed payload raises ValueError (a 500 in production — it means
    a caller has a bug, not that the client sent something wrong).
    """
    model = NOTIFICATION_PAYLOAD_MODELS.get(notification_type)
    if model is None:
        raise ValueError(f"unknown notification type {notification_type!r}")
    validated = model(**payload)
    # round-trip through model_dump so UUIDs become str (jsonb needs plain JSON types)
    return json.loads(json.dumps(validated.model_dump(mode="json"), default=str))


# ---------- DB half ----------

async def create(
    conn: AsyncConnection,
    user_id: UUID,
    notification_type: str,
    payload: dict[str, Any],
) -> Notification | None:
    """Insert one notification and return it.

    Returns None when the dedup index rejects it (an unread friend_request from the same
    sender already exists) — the action itself succeeded, there is just nothing new to push.
    Call inside the caller's transaction so the notification and the action commit together.
    """
    clean = validate_payload(notification_type, payload)
    row = await (await conn.execute(
        """INSERT INTO notifications (user_id, type, payload)
           VALUES (%s, %s, %s)
           ON CONFLICT DO NOTHING
           RETURNING id, user_id, type, payload, seq, read, created_at""",
        [user_id, notification_type, json.dumps(clean)],
    )).fetchone()
    if row is None:
        return None
    return _row_to_notification(row)


async def list_notifications(
    conn: AsyncConnection,
    user_id: UUID,
    *,
    unread_only: bool = False,
    after_seq: int = 0,
    before_seq: int | None = None,
    limit: int = 50,
) -> NotificationsResponse:
    """Page of notifications for one user plus the current unread count.

    after_seq: catch-up cursor — everything the client has not seen (WS reconnect).
    before_seq: backward pagination — older than this (scrolling an infinite list).
    Both can be combined, though in practice a client uses one or the other.
    """
    clauses = ["user_id = %s"]
    params: list[Any] = [user_id]
    if unread_only:
        clauses.append("read = false")
    if after_seq > 0:
        clauses.append("seq > %s")
        params.append(after_seq)
    if before_seq is not None:
        clauses.append("seq < %s")
        params.append(before_seq)
    params.append(limit)
    rows = await (await conn.execute(
        f"""SELECT id, user_id, type, payload, seq, read, created_at
              FROM notifications
             WHERE {' AND '.join(clauses)}
             ORDER BY seq DESC
             LIMIT %s""",
        params,
    )).fetchall()
    unread = await unread_count(conn, user_id)
    return NotificationsResponse(
        notifications=[_row_to_notification(r) for r in rows],
        unread_count=unread,
    )


async def mark_read(conn: AsyncConnection, user_id: UUID,
                    notification_id: UUID) -> Literal["read", "already_read", "not_found"]:
    """Mark one notification read. "not_found" only when it does not exist or is not yours;
    re-marking an already-read notification is "already_read" (idempotent, not an error)."""
    changed = (await conn.execute(
        "UPDATE notifications SET read = true WHERE id = %s AND user_id = %s AND read = false",
        [notification_id, user_id],
    )).rowcount
    if changed:
        return "read"
    exists = await (await conn.execute(
        "SELECT 1 FROM notifications WHERE id = %s AND user_id = %s",
        [notification_id, user_id],
    )).fetchone()
    return "already_read" if exists else "not_found"


async def mark_all_read(conn: AsyncConnection, user_id: UUID) -> int:
    """Mark every unread notification read. Returns how many changed."""
    return (await conn.execute(
        "UPDATE notifications SET read = true WHERE user_id = %s AND read = false",
        [user_id],
    )).rowcount


async def unread_count(conn: AsyncConnection, user_id: UUID) -> int:
    row = await (await conn.execute(
        "SELECT count(*) AS n FROM notifications WHERE user_id = %s AND read = false",
        [user_id],
    )).fetchone()
    return row["n"]


async def delete_old(conn: AsyncConnection, days: int = 30) -> int:
    """Remove notifications older than `days`."""
    return (await conn.execute(
        "DELETE FROM notifications WHERE created_at < now() - make_interval(days => %s)",
        [days],
    )).rowcount


async def clean_forever(pool, days: int = 30, every_seconds: int = 6 * 3600) -> None:
    """The server's cleanup task (main.lifespan, alongside sessions): every `every_seconds`,
    drop notifications older than `days`. Sleeps first — startup already has enough to do."""
    while True:
        await asyncio.sleep(every_seconds)
        async with pool.connection() as conn:
            await delete_old(conn, days)


def _row_to_notification(row) -> Notification:
    return Notification(
        id=row["id"],
        user_id=row["user_id"],
        type=row["type"],
        payload=row["payload"],
        seq=row["seq"],
        read=row["read"],
        created_at=row["created_at"],
    )


# ---------- push half: the connection registry ----------

class NotificationHub:
    """Open WebSocket connections, keyed by user. One user can have many sockets.

    Lives on app.state. Not thread-safe by design: it is only touched from the event loop
    (async def endpoints), so no lock is needed — there is no await between check and mutate
    in push().
    """

    def __init__(self) -> None:
        self._connections: dict[UUID, set[WebSocket]] = {}
        # single-use WS tickets: ticket string -> (user_id, expires_at monotonic)
        self._tickets: dict[str, tuple[UUID, float]] = {}

    # --- connections ---

    def register(self, user_id: UUID, ws: WebSocket) -> None:
        self._connections.setdefault(user_id, set()).add(ws)

    def unregister(self, user_id: UUID, ws: WebSocket) -> None:
        conns = self._connections.get(user_id)
        if conns is not None:
            conns.discard(ws)
            if not conns:
                del self._connections[user_id]

    def connection_count(self, user_id: UUID) -> int:
        return len(self._connections.get(user_id, ()))

    async def push(self, user_id: UUID, message: dict[str, Any]) -> int:
        """Send one JSON message to every socket this user has open. Returns how many got it.

        A socket that raises (closed, network gone) is removed; the others still receive.

        Two races this is careful about, both real: send_json awaits, and anything on the event
        loop may run during that await. (1) iterate a *copy* of the set — a disconnecting socket's
        task calls unregister() and mutates the original mid-loop, which would raise "set changed
        size during iteration". (2) only forget the user if the dict still holds *this* set —
        a socket that dies and reconnects during the await has already replaced it with a fresh
        set, and popping that would leave the new connection dark (registered in a set nobody
        has a reference to).
        """
        conns = self._connections.get(user_id)
        if not conns:
            return 0
        sent = 0
        dead: list[WebSocket] = []
        for ws in list(conns):
            try:
                await ws.send_json(message)
                sent += 1
            except Exception:
                dead.append(ws)
        for ws in dead:
            conns.discard(ws)
        if not conns and self._connections.get(user_id) is conns:
            del self._connections[user_id]
        return sent

    # --- tickets (flaw #2: the JWT never appears in a URL) ---

    def issue_ticket(self, user_id: UUID, ttl_seconds: int = 30) -> str:
        """Mint a single-use ticket for the WS handshake. The client trades its JWT for this."""
        self._prune_tickets()
        ticket = secrets.token_urlsafe(32)
        self._tickets[ticket] = (user_id, time.monotonic() + ttl_seconds)
        return ticket

    def redeem_ticket(self, ticket: str) -> UUID | None:
        """Consume a ticket: returns the user_id once, then the ticket is gone (single-use)."""
        entry = self._tickets.pop(ticket, None)
        if entry is None:
            return None
        user_id, expires_at = entry
        if time.monotonic() > expires_at:
            return None
        return user_id

    def _prune_tickets(self) -> None:
        now = time.monotonic()
        expired = [t for t, (_, exp) in self._tickets.items() if now > exp]
        for t in expired:
            del self._tickets[t]
