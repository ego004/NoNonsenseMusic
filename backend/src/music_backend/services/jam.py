"""Provide jam rooms: listening together. Every member's device plays the room's song in step and every member
controls it. Two host settings, both off by default: only_host_plays (the room plays on the host's device alone) and
only_host_controls (members only add songs; playback and the queue are the host's).

The room is stateless about audio: it keeps listings, the same data the apps already have from
search, and never a song id or a URL. Each member's player plays a listing through /play like any other song;
the room tracks only who is host, what is current, the queue, and where the playhead is. Rooms live
in this process's memory (app.state.jams): a position that moves every second is not worth a table.
They are written to the database only when the server stops, and read back when it starts (save_rooms,
load_rooms): every deploy restarts it, and a restart used to end every jam (#31). A control command mutates the
room synchronously, then broadcasts the new state over every member's WebSocket. No lock is needed:
the event loop runs one command at a time, and the mutation has no await inside it.

What the room does, and what each app does with it, is written once, for the server and both apps: docs/jam.md.
"""
import logging
import asyncio
import secrets
import time
from dataclasses import dataclass, field
from uuid import UUID, uuid4

from fastapi import WebSocket
from psycopg import AsyncConnection
from psycopg.types.json import Jsonb

from music_backend.models import JamCommand, JamMember, JamQueueEntry, JamSong, JamState

logger = logging.getLogger(__name__)

MAX_QUEUE = 200            # one person's queue, not a server-wide archive
MAX_COMMANDS = 60          # per member per room per minute: a human cannot usefully exceed ~2/s
# a command is a few hundred bytes; the largest legitimate one is 50 songs with up to 4 other copies each (about 120 KB).
# Below the deployment's uvicorn --ws-max-size (256 KB)
MAX_FRAME_BYTES = 192 * 1024
COMMAND_WINDOW = 60.0
MAX_ROOMS_PER_USER = 20
ROOM_IDLE_SECONDS = 2 * 60 * 60
MAX_SOCKETS_PER_USER = 5
SEND_TIMEOUT = 3.0
# with only_host_controls on, what a member may not do (an add is allowed, at the end of the queue)
MEMBER_LOCKED = {"play", "pause", "seek", "skip", "remove", "move", "jump"}
CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"   # no l/1/0/o: a code read aloud or typed must not fail
# seconds: a room that was playing when the server stopped plays on if the server is back this soon. The members'
# players never stopped (a deploy takes about 4 s, 14 Oct), so the playhead counts the time between; after longer, the
# room waits, paused where it was
RESUME_WITHIN = 60
# seconds: an `ended` moves the room on only this close to the song's end by the room's clock. Every member's app sends
# one when the song ends there, so the room no longer waits for the host's app (gone, or hung as in #28); and a copy a
# second or two shorter than the host's (YouTube's video against YouTube Music's song) cannot cut the song for the others
END_WITHIN = 3.0


class RoomNotFound(Exception):
    """Raised when no room matches the given id or code."""

class NotAMember(Exception):
    """Raised when the user is not on the room's member list."""


class RoomLimit(Exception):
    """Raised when creating another room would exceed one user's small active-room cap."""


class NotHost(Exception):
    """Raised when a member attempts a host-only room action."""


class SocketLimit(Exception):
    """Raised when a user opens too many simultaneous jam channels."""


@dataclass
class Room:
    id: UUID
    code: str
    name: str | None
    host_id: UUID
    members: dict[UUID, str]                       # user_id -> username
    join_order: list[UUID]                         # hostship succession: next here inherits
    current: JamQueueEntry | None = None
    is_playing: bool = False
    position_seconds: float = 0.0
    position_at: float = field(default_factory=time.time)
    queue: list[JamQueueEntry] = field(default_factory=list)
    sockets: dict[WebSocket, UUID] = field(default_factory=dict)   # socket -> user_id
    only_host_plays: bool = False                  # the host's device plays the room alone; the others follow silently
    only_host_controls: bool = False               # members may only add songs to the end of the queue
    touched_at: float = field(default_factory=time.monotonic)


class JamHub:
    """Hold every room in this process. Not thread-safe: only the event loop touches it."""

    def __init__(self) -> None:
        self._rooms: dict[UUID, Room] = {}
        self._by_code: dict[str, UUID] = {}
        self._command_hits: dict[tuple[UUID, UUID], list[float]] = {}   # (room, user) -> timestamps

    # ---- lifecycle ----

    def create(self, user_id: UUID, username: str, name: str | None, song: JamSong | None = None) -> Room:
        """Open a room with its creator as host and only member, and the song on their screen as its first, if any."""
        self._discard_expired()
        if sum(user_id in room.members for room in self._rooms.values()) >= MAX_ROOMS_PER_USER:
            raise RoomLimit()
        code = self._fresh_code()
        room = Room(id=uuid4(), code=code, name=name, host_id=user_id,
                    members={user_id: username}, join_order=[user_id])
        self._rooms[room.id] = room
        self._by_code[code] = room.id
        if song is not None:
            self._take(room, song)
        return room

    def get(self, room_id: UUID) -> Room | None:
        self._discard_expired()
        return self._rooms.get(room_id)

    def require(self, room_id: UUID, user_id: UUID) -> Room:
        """Return the room, or raise RoomNotFound if it is absent or the user is not a member."""
        self._discard_expired()
        room = self._rooms.get(room_id)
        if room is None or user_id not in room.members:
            raise RoomNotFound()
        self.touch(room)
        return room

    def join(self, user_id: UUID, username: str, code: str, song: JamSong | None = None) -> tuple[Room, bool]:
        """Add a member to the room whose code matches, ignoring case and surrounding space. A room with no song takes
        the one on the joiner's screen. Return the room and whether it changed (a new member, or the song).

        Raise RoomNotFound when no room has the code.
        """
        self._discard_expired()
        room_id = self._by_code.get(code.strip().lower())
        room = self._rooms.get(room_id) if room_id else None
        if room is None:
            raise RoomNotFound()
        added = user_id not in room.members
        if added:
            room.members[user_id] = username
            room.join_order.append(user_id)
        took = song is not None and room.current is None
        if took:
            self._take(room, song)
        self.touch(room)
        return room, added or took

    @staticmethod
    def _take(room: Room, song: JamSong) -> None:
        """Make `song` the room's current song, at its second, playing or paused as it was on the screen it came from."""
        room.current = JamQueueEntry(entry_id=uuid4(), listing=song.listing, copies=list(song.copies))
        duration = song.listing.duration
        room.position_seconds = min(song.seconds, duration) if duration > 0 else song.seconds
        room.position_at = time.time()
        room.is_playing = song.playing

    def leave(self, user_id: UUID, room_id: UUID) -> Room | None:
        """Remove a member from a room.

        Return the room, still open and possibly with a new host, or None when the last member
        left and the room closed. Raise RoomNotFound for an unknown room, NotAMember when the
        user is not on the member list.
        """
        self._discard_expired()
        room = self._rooms.get(room_id)
        if room is None:
            raise RoomNotFound()
        if user_id not in room.members:
            raise NotAMember()
        del room.members[user_id]
        room.join_order = [u for u in room.join_order if u != user_id]
        room.sockets = {ws: uid for ws, uid in room.sockets.items() if uid != user_id}
        if not room.members:
            del self._rooms[room.id]
            self._by_code.pop(room.code, None)
            self._command_hits = {k: v for k, v in self._command_hits.items() if k[0] != room.id}
            return None
        if room.host_id == user_id:
            room.host_id = room.join_order[0]     # next by join order inherits the speakers
        self.touch(room)
        return room

    def set_host(self, user_id: UUID, room_id: UUID, member_id: UUID) -> Room:
        room = self.require(room_id, user_id)
        if user_id != room.host_id:
            raise NotHost()
        if member_id not in room.members:
            raise NotAMember()
        room.host_id = member_id
        self.touch(room)
        return room

    def remove_member(self, user_id: UUID, room_id: UUID, member_id: UUID) -> Room | None:
        """Let the host remove another member; removing yourself remains the leave route."""
        room = self.require(room_id, user_id)
        if user_id != room.host_id:
            raise NotHost()
        if member_id == user_id:
            raise NotAMember()
        return self.leave(member_id, room_id)

    # ---- sockets ----

    def register(self, ws: WebSocket, user_id: UUID, room_id: UUID) -> Room:
        room = self.require(room_id, user_id)     # membership checked again at connect time
        if sum(uid == user_id for candidate in self._rooms.values() for uid in candidate.sockets.values()) >= MAX_SOCKETS_PER_USER:
            raise SocketLimit()
        room.sockets[ws] = user_id
        self.touch(room)
        return room

    def unregister(self, ws: WebSocket) -> tuple[UUID, UUID] | None:
        """Return the (room_id, user_id) the socket belonged to, or None if it belongs to no room.

        Membership is kept: a dropped connection is not a leave, and the member reconnects or
        leaves explicitly.
        """
        for room in self._rooms.values():
            if ws in room.sockets:
                user_id = room.sockets.pop(ws)
                self.touch(room)
                return room.id, user_id
        return None

    async def broadcast(self, room: Room, message: dict, skip: WebSocket | None = None) -> None:
        """Send one message to every open socket in the room, but `skip`.

        A socket that raises is removed from the room and left open: a member with two devices
        loses one socket, not the room.
        """
        sockets = [ws for ws in room.sockets if ws is not skip]

        async def send(ws: WebSocket) -> bool:
            try:
                await asyncio.wait_for(ws.send_json(message), timeout=SEND_TIMEOUT)
                return True
            except Exception:
                return False

        delivered = await asyncio.gather(*(send(ws) for ws in sockets))
        dead = [ws for ws, sent in zip(sockets, delivered) if not sent]
        for ws in dead:
            room.sockets.pop(ws, None)

    @staticmethod
    async def put_out(sockets: list[WebSocket], reason: str) -> None:
        """Tell sockets already off their room why ("removed": the host removed you; "left": you left on another device),
        then close them. A removed member's socket used to stay open and silent: its pings still worked, so the app went
        on showing the room, frozen, and never learnt it was out."""
        async def end(ws: WebSocket) -> None:
            try:
                await asyncio.wait_for(ws.send_json({"type": "out", "reason": reason}), timeout=SEND_TIMEOUT)
                await asyncio.wait_for(ws.close(code=4404, reason=reason), timeout=SEND_TIMEOUT)
            except Exception:
                pass
        await asyncio.gather(*(end(ws) for ws in sockets))

    # ---- state ----

    def playhead(self, room: Room) -> float:
        """Return the current playback position: the stored position plus the time elapsed while
        playing, clamped to the current song's duration. The host sends skip when a song ends;
        the server runs no timer.
        """
        if not room.is_playing:
            return room.position_seconds
        position = room.position_seconds + (time.time() - room.position_at)
        duration = room.current.listing.duration if room.current else 0
        return min(position, duration) if duration > 0 else position

    def state(self, room: Room) -> JamState:
        return JamState(
            room_id=room.id,
            code=room.code,
            name=room.name,
            host_id=room.host_id,
            members=[JamMember(user_id=u, username=name) for u, name in room.members.items()],
            current=room.current,
            is_playing=room.is_playing,
            position_seconds=self.playhead(room),
            queue=list(room.queue),
            only_host_plays=room.only_host_plays,
            only_host_controls=room.only_host_controls,
        )

    # ---- commands ----

    def command_allowed(self, room: Room, user_id: UUID) -> bool:
        """Record a message from a member (any message, valid or not) and return whether it fits the rate limit."""
        key = (room.id, user_id)
        now = time.time()
        hits = self._command_hits.setdefault(key, [])
        cutoff = now - COMMAND_WINDOW
        hits[:] = [t for t in hits if t > cutoff]
        if len(hits) >= MAX_COMMANDS:
            return False
        hits.append(now)
        return True

    async def handle_command(self, room: Room, user_id: UUID, cmd: JamCommand, sender: WebSocket) -> None:
        """Mutate the room from one member's command, then tell everyone.

        Every member controls playback, not only the host, unless the host turned on only_host_controls: then a
        member may only add songs to the end of the queue. Always host-only: the position heartbeat, because the
        host's player is the room's clock, and the two settings.
        An unknown or malformed command answers the sender alone; a successful one broadcasts
        full state, except a heartbeat, which pushes only the new position, and an `ended` that changes nothing.
        """
        if user_id not in room.members:
            # membership can shrink under a live socket (left from another device)
            await sender.send_json({"type": "error", "detail": "You are not in this room."})
            return
        if room.only_host_controls and user_id != room.host_id and (
                cmd.type in MEMBER_LOCKED or cmd.type == "add" and cmd.placement != "end"):
            await sender.send_json({"type": "error", "detail": "The host controls this jam. You can add songs to the queue."})
            return
        if cmd.type == "position":
            if user_id != room.host_id:
                await sender.send_json({"type": "error", "detail": "Only the host reports the playhead."})
                return
            # a heartbeat from before a pause is stale: dropping it, rather than setting is_playing
            # back to True, keeps the room frozen where the pause put it; an in-flight heartbeat
            # after a pause would otherwise desync the room until the host plays again
            if cmd.seconds is None or cmd.seconds < 0 or room.current is None or not room.is_playing:
                return
            room.position_seconds = cmd.seconds
            room.position_at = time.time()
            self.touch(room)
            # not back to the host: its own place is the one thing it never needs (4 messages a minute, 17 Oct)
            await self.broadcast(room, {"type": "position", "seconds": self.playhead(room), "is_playing": True},
                                 skip=sender)
            return
        if cmd.type == "ended":
            # every member's app sends it as the song ends there: the first one near the end moves the room on; the
            # others, and one far from the end, change nothing and answer nothing
            if cmd.entry_id is None or room.current is None or cmd.entry_id != room.current.entry_id:
                return
            duration = room.current.listing.duration
            if duration > 0 and self.playhead(room) < duration - END_WITHIN:
                return
            self._advance(room)
        if cmd.type == "play":
            if room.current is None:
                await sender.send_json({"type": "error", "detail": "Nothing to play."})
                return
            if not room.is_playing:
                room.is_playing = True
                room.position_at = time.time()      # resume from where position_seconds stands
        elif cmd.type == "pause":
            room.position_seconds = self.playhead(room)
            room.is_playing = False
        elif cmd.type == "seek":
            if room.current is None or cmd.seconds is None or cmd.seconds < 0:
                await sender.send_json({"type": "error", "detail": "Nothing to seek."})
                return
            room.position_seconds = cmd.seconds
            room.position_at = time.time()
        elif cmd.type == "skip":
            if room.current is None and not room.queue:
                await sender.send_json({"type": "error", "detail": "Nothing to skip."})
                return
            self._advance(room)
        elif cmd.type == "add":
            if not cmd.listings:
                await sender.send_json({"type": "error", "detail": "Nothing to add."})
                return
            if len(room.queue) + len(cmd.listings) > MAX_QUEUE:
                await sender.send_json({"type": "error", "detail": f"Queue is full ({MAX_QUEUE})."})
                return
            if cmd.copies is not None and len(cmd.copies) != len(cmd.listings):
                await sender.send_json({"type": "error", "detail": "The copies don't match the songs."})
                return
            copies = cmd.copies or [[] for _ in cmd.listings]
            entries = [JamQueueEntry(entry_id=uuid4(), listing=listing, copies=list(others))
                       for listing, others in zip(cmd.listings, copies)]
            if room.current is None:
                room.current = entries[0]
                room.queue.extend(entries[1:])
                room.position_seconds = 0.0
                room.position_at = time.time()
                room.is_playing = True               # adding to an idle room starts it
            elif cmd.placement == "now":
                room.current = entries[0]            # Play: this song at once; the one playing is dropped, as jump does
                room.queue[0:0] = entries[1:]
                room.position_seconds = 0.0
                room.position_at = time.time()
                room.is_playing = True
            elif cmd.placement == "next":
                room.queue[0:0] = entries            # Play Next: first in the queue, in the order given
            else:
                room.queue.extend(entries)
        elif cmd.type == "remove":
            if cmd.entry_id is None:
                await sender.send_json({"type": "error", "detail": "Which entry?"})
                return
            if room.current and cmd.entry_id == room.current.entry_id:
                self._advance(room)
            else:
                before = len(room.queue)
                room.queue = [e for e in room.queue if e.entry_id != cmd.entry_id]
                if len(room.queue) == before:
                    await sender.send_json({"type": "error", "detail": "No such entry."})
                    return
        elif cmd.type == "move":
            if cmd.entry_id is None or cmd.to_index is None or not (0 <= cmd.to_index < len(room.queue)):
                await sender.send_json({"type": "error", "detail": "Bad move."})
                return
            index = next((i for i, e in enumerate(room.queue) if e.entry_id == cmd.entry_id), None)
            if index is None:
                await sender.send_json({"type": "error", "detail": "No such entry."})
                return
            entry = room.queue.pop(index)
            room.queue.insert(cmd.to_index, entry)
        elif cmd.type in ("only_host_plays", "only_host_controls"):
            if user_id != room.host_id:
                await sender.send_json({"type": "error", "detail": "Only the host changes the jam's settings."})
                return
            if cmd.on is None:
                await sender.send_json({"type": "error", "detail": "On or off?"})
                return
            setattr(room, cmd.type, cmd.on)
        elif cmd.type == "jump":
            if cmd.entry_id is None:
                await sender.send_json({"type": "error", "detail": "Which entry?"})
                return
            index = next((i for i, e in enumerate(room.queue) if e.entry_id == cmd.entry_id), None)
            if index is None:
                await sender.send_json({"type": "error", "detail": "No such entry."})
                return
            room.current = room.queue.pop(index)      # the entry leaves the queue; the song playing is dropped
            room.position_seconds = 0.0
            room.position_at = time.time()
            room.is_playing = True
        self.touch(room)
        await self.broadcast(room, {"type": "state", "data": self.state(room).model_dump(mode="json")})

    @staticmethod
    def _advance(room: Room) -> None:
        """The next song in the queue, from its start, playing; with none left, the room is empty and still."""
        room.current = room.queue.pop(0) if room.queue else None
        room.position_seconds = 0.0
        room.position_at = time.time()
        room.is_playing = room.current is not None

    def touch(self, room: Room) -> None:
        room.touched_at = time.monotonic()

    def _discard_expired(self) -> None:
        """Forget idle rooms before a create or lookup can grow the in-memory registry."""
        cutoff = time.monotonic() - ROOM_IDLE_SECONDS
        for room in [room for room in self._rooms.values() if room.touched_at <= cutoff]:
            self._close_room(room)

    def _close_room(self, room: Room) -> None:
        self._rooms.pop(room.id, None)
        self._by_code.pop(room.code, None)
        self._command_hits = {key: hits for key, hits in self._command_hits.items() if key[0] != room.id}

    async def close_user(self, user_id: UUID, *, code: int = 4401, reason: str = "signed out") -> None:
        """End a user's jam sockets; membership remains so another signed-in device can return."""
        sockets = [ws for room in self._rooms.values() for ws, uid in room.sockets.items() if uid == user_id]
        for room in self._rooms.values():
            room.sockets = {ws: uid for ws, uid in room.sockets.items() if uid != user_id}
        async def close(ws: WebSocket) -> None:
            try:
                await asyncio.wait_for(ws.close(code=code, reason=reason), timeout=SEND_TIMEOUT)
            except Exception:
                pass
        await asyncio.gather(*(close(ws) for ws in sockets), return_exceptions=True)

    # ---- across a restart (save_rooms, load_rooms) ----

    def snapshot(self) -> list[tuple[UUID, dict]]:
        """Every open room as JSON: everything but its sockets, the playhead as it stands now, and how long it has
        been idle."""
        self._discard_expired()
        now, idle_now = time.time(), time.monotonic()
        return [(room.id, {
            "code": room.code,
            "name": room.name,
            "host_id": str(room.host_id),
            "members": {str(user_id): username for user_id, username in room.members.items()},
            "join_order": [str(user_id) for user_id in room.join_order],
            "current": room.current.model_dump(mode="json") if room.current else None,
            "queue": [entry.model_dump(mode="json") for entry in room.queue],
            "is_playing": room.is_playing,
            "position_seconds": self.playhead(room),
            "only_host_plays": room.only_host_plays,
            "only_host_controls": room.only_host_controls,
            "idle_seconds": idle_now - room.touched_at,
            "saved_at": now,
        }) for room in self._rooms.values()]

    def restore(self, saved: list[tuple[UUID, dict]]) -> None:
        """Reopen rooms from snapshot(). One that was playing plays on, its playhead counting the time the server
        was away, if it is back within RESUME_WITHIN; otherwise it waits, paused where it was. The time away counts as
        idle, so a room still closes ROOM_IDLE_SECONDS after its last use."""
        now = time.time()
        for room_id, s in saved:
            away = max(0.0, now - s["saved_at"])
            playing = s["is_playing"] and away <= RESUME_WITHIN and s["current"] is not None
            room = Room(
                id=room_id,
                code=s["code"],
                name=s["name"],
                host_id=UUID(s["host_id"]),
                members={UUID(user_id): username for user_id, username in s["members"].items()},
                join_order=[UUID(user_id) for user_id in s["join_order"]],
                current=JamQueueEntry.model_validate(s["current"]) if s["current"] else None,
                is_playing=playing,
                position_seconds=s["position_seconds"],
                position_at=s["saved_at"] if playing else now,
                queue=[JamQueueEntry.model_validate(entry) for entry in s["queue"]],
                only_host_plays=s["only_host_plays"],
                only_host_controls=s["only_host_controls"],
                touched_at=time.monotonic() - s["idle_seconds"] - away,
            )
            if not room.members or room.code in self._by_code:
                continue
            self._rooms[room.id] = room
            self._by_code[room.code] = room.id
        self._discard_expired()

    # ---- code ----

    def _fresh_code(self) -> str:
        for _ in range(20):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
            if code not in self._by_code:
                return code
        raise RuntimeError("could not find a free room code")   # 8 chars from 32 symbols: not reachable


async def save_rooms(conn: AsyncConnection, hub: JamHub) -> int:
    """Write every open room for the next start, in place of what was saved before; return how many."""
    rooms = hub.snapshot()
    async with conn.transaction():
        await conn.execute("DELETE FROM jam_rooms")
        async with conn.cursor() as cur:
            await cur.executemany("INSERT INTO jam_rooms (id, state) VALUES (%s, %s)",
                                  [(room_id, Jsonb(state)) for room_id, state in rooms])
    return len(rooms)


async def load_rooms(conn: AsyncConnection, hub: JamHub) -> int:
    """Reopen the rooms saved when the server last stopped, and empty the table: a crash later never brings back rooms
    that have moved on since. Return how many."""
    rows = await (await conn.execute("DELETE FROM jam_rooms RETURNING id, state")).fetchall()
    hub.restore([(row["id"], row["state"]) for row in rows])
    return len(rows)
