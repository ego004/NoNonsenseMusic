"""Jam rooms (JAM-1): one room, one host plays out loud, everyone else holds the remote.

Stateless server-side about audio: the room keeps listings (what the apps already have from search),
never a song id, never a URL. The host plays a listing through /play like any other song; the room
only tracks who is host, what is current, the queue, and where the playhead is. Rooms live in this
process's memory (app.state.jams): a position that moves every second is not worth a table, and a
restart losing rooms matches losing in-flight YouTube links. A control command mutates the room
synchronously, then broadcasts the new state over every member's WebSocket — no lock needed:
the event loop runs one command at a time, and the mutation has no await inside it.
"""
import logging
import secrets
import time
from dataclasses import dataclass, field
from uuid import UUID, uuid4

from fastapi import WebSocket

from music_backend.models import JamCommand, JamMember, JamQueueEntry, JamState, Listing

logger = logging.getLogger(__name__)

MAX_QUEUE = 200            # one person's queue, not a server-wide archive
MAX_COMMANDS = 60          # per member per room per minute: a human cannot usefully exceed ~2/s
COMMAND_WINDOW = 60.0
CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"   # no l/1/0/o: a code read aloud or typed must not fail


class RoomNotFound(Exception):
    """No room with that id or code."""

class NotAMember(Exception):
    """You are not on this room's member list."""


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


class JamHub:
    """All rooms, in this process. Not thread-safe by design: only touched from the event loop."""

    def __init__(self) -> None:
        self._rooms: dict[UUID, Room] = {}
        self._by_code: dict[str, UUID] = {}
        self._command_hits: dict[tuple[UUID, UUID], list[float]] = {}   # (room, user) -> timestamps

    # ---- lifecycle ----

    def create(self, user_id: UUID, username: str, name: str | None) -> Room:
        code = self._fresh_code()
        room = Room(id=uuid4(), code=code, name=name, host_id=user_id,
                    members={user_id: username}, join_order=[user_id])
        self._rooms[room.id] = room
        self._by_code[code] = room.id
        return room

    def get(self, room_id: UUID) -> Room | None:
        return self._rooms.get(room_id)

    def require(self, room_id: UUID, user_id: UUID) -> Room:
        room = self._rooms.get(room_id)
        if room is None or user_id not in room.members:
            raise RoomNotFound()
        return room

    def join(self, user_id: UUID, username: str, code: str) -> Room:
        room_id = self._by_code.get(code.strip().lower())
        room = self._rooms.get(room_id) if room_id else None
        if room is None:
            raise RoomNotFound()
        if user_id not in room.members:
            room.members[user_id] = username
            room.join_order.append(user_id)
        return room

    def leave(self, user_id: UUID, room_id: UUID) -> Room | None:
        """Remove a member. Returns the room (still alive, possibly with a new host), or None when
        the room closed because its last member left. Raises RoomNotFound if no such room."""
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
        return room

    def take_host(self, user_id: UUID, room_id: UUID) -> Room:
        room = self.require(room_id, user_id)
        room.host_id = user_id
        return room

    # ---- sockets ----

    def register(self, ws: WebSocket, user_id: UUID, room_id: UUID) -> Room:
        room = self.require(room_id, user_id)     # membership checked again at connect time
        room.sockets[ws] = user_id
        return room

    def unregister(self, ws: WebSocket) -> tuple[UUID, UUID] | None:
        """(room_id, user_id) the socket belonged to, or None. Membership is kept: a dropped
        connection is not a leave; the member reconnects or leaves explicitly."""
        for room in self._rooms.values():
            if ws in room.sockets:
                user_id = room.sockets.pop(ws)
                return room.id, user_id
        return None

    async def broadcast(self, room: Room, message: dict) -> None:
        """Send one message to every open socket in the room; a dead socket is dropped, never
        killed (a member with two devices loses one, not the room)."""
        dead = []
        for ws in list(room.sockets):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            room.sockets.pop(ws, None)

    # ---- state ----

    def playhead(self, room: Room) -> float:
        """Where playback is right now: the stored position plus the time elapsed while playing,
        clamped to the current song's duration (the host sends skip when a song ends; the server
        does not run a timer)."""
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
        )

    # ---- commands ----

    def _command_allowed(self, room: Room, user_id: UUID) -> bool:
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
        """Mutate the room from one member's command, then tell everyone. Every member controls
        (not just the host); only the position heartbeat is host-only — it is the only message
        that knows where the speakers actually are. An unknown or malformed command answers the
        sender alone; a successful one broadcasts full state (or a light position push)."""
        if user_id not in room.members:
            # membership can shrink under a live socket (left from another device)
            await sender.send_json({"type": "error", "detail": "You are not in this room."})
            return
        if not self._command_allowed(room, user_id):
            await sender.send_json({"type": "error", "detail": "Too many commands. Slow down."})
            return
        if cmd.type == "position":
            if user_id != room.host_id:
                await sender.send_json({"type": "error", "detail": "Only the host reports the playhead."})
                return
            if cmd.seconds is None or cmd.seconds < 0 or room.current is None:
                return
            room.position_seconds = cmd.seconds
            room.position_at = time.time()
            room.is_playing = True
            await self.broadcast(room, {"type": "position", "seconds": self.playhead(room), "is_playing": True})
            return
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
            room.current = room.queue.pop(0) if room.queue else None
            room.position_seconds = 0.0
            room.position_at = time.time()
            room.is_playing = room.current is not None
        elif cmd.type == "add":
            if not cmd.listings:
                await sender.send_json({"type": "error", "detail": "Nothing to add."})
                return
            if len(room.queue) + len(cmd.listings) > MAX_QUEUE:
                await sender.send_json({"type": "error", "detail": f"Queue is full ({MAX_QUEUE})."})
                return
            entries = [JamQueueEntry(entry_id=uuid4(), listing=listing) for listing in cmd.listings]
            if room.current is None:
                room.current = entries[0]
                room.queue.extend(entries[1:])
                room.position_seconds = 0.0
                room.position_at = time.time()
                room.is_playing = True               # adding to an idle room starts it
            else:
                room.queue.extend(entries)
        elif cmd.type == "remove":
            if cmd.entry_id is None:
                await sender.send_json({"type": "error", "detail": "Which entry?"})
                return
            if room.current and cmd.entry_id == room.current.entry_id:
                room.current = room.queue.pop(0) if room.queue else None
                room.position_seconds = 0.0
                room.position_at = time.time()
                room.is_playing = room.current is not None
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
        elif cmd.type == "jump":
            if cmd.entry_id is None:
                await sender.send_json({"type": "error", "detail": "Which entry?"})
                return
            index = next((i for i, e in enumerate(room.queue) if e.entry_id == cmd.entry_id), None)
            if index is None:
                await sender.send_json({"type": "error", "detail": "No such entry."})
                return
            room.current = room.queue.pop(index)      # the song being played is dropped, not re-queued
            room.position_seconds = 0.0
            room.position_at = time.time()
            room.is_playing = True
        await self.broadcast(room, {"type": "state", "data": self.state(room).model_dump(mode="json")})

    # ---- code ----

    def _fresh_code(self) -> str:
        for _ in range(20):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
            if code not in self._by_code:
                return code
        raise RuntimeError("could not find a free room code")   # 8 chars from 32 symbols: not reachable
