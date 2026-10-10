"""Rate limits (8 Oct): how often one address, one username or one account may do something.

Per address (IP): signing in, signing up and recovering, the guessable doors. Per username: signing in and recovering,
so guessing one account from many addresses is slowed too. Per account, after sign-in: the routes that make this
server ask YouTube, JioSaavn, LRCLIB or Genius, so one account cannot make the sources block the server for everyone.

A sliding window per key, in this process's memory: one server needs no Redis; a restart forgets the counts. Addresses
are kept only as a short SHA-256, in memory, never logged. Requests from this computer itself (127.0.0.1, ::1) are not
counted: your own Mac's server and the test servers. A hosted server sees the real addresses (Render passes them in
X-Forwarded-For; uvicorn reads it with --proxy-headers). Over a limit: 429, with Retry-After in seconds.
"""
import hashlib
import time
from collections import deque

from fastapi import HTTPException, Request

# action → (how many, in how many seconds)
LIMITS: dict[str, tuple[int, int]] = {
    "signin_address": (10, 60),
    "signin_username": (20, 3600),
    "signup_address": (5, 3600),
    "recover_address": (5, 900),
    "recover_username": (10, 3600),
    "search": (60, 60),
    "lyrics": (60, 60),
    "genius": (30, 60),
    "prefetch": (60, 60),
    "play": (120, 60),
    "friends": (30, 60),
    "friend_request": (20, 60),
    "notifications": (60, 60),          # /ws-ticket: stops ticket-minting floods
    "album": (60, 60),                  # GET /album: each one asks a source for a full track list
    "artist": (60, 60),                 # GET /artist: each one may fan out to several album pages
    "radio": (30, 60),                  # POST /radio: each one asks a source for a station batch
    "jam": (20, 60),                    # POST /jam and /jam/join: opening rooms, not the controls inside them
}
LOCAL = {"127.0.0.1", "::1", "localhost"}


class Limiter:
    def __init__(self) -> None:
        self._hits: dict[tuple[str, str], deque[float]] = {}
        self._checks = 0

    def check(self, action: str, who: str) -> None:
        """Counts one `action` by `who`; 429 when that is one too many within its window."""
        count, window = LIMITS[action]
        now = time.monotonic()
        hits = self._hits.setdefault((action, who), deque())
        while hits and hits[0] <= now - window:
            hits.popleft()
        if len(hits) >= count:
            wait = int(hits[0] + window - now) + 1
            raise HTTPException(status_code=429, detail=f"Too many attempts. Try again in {wait} s.",
                                headers={"Retry-After": str(wait)})
        hits.append(now)
        self._checks += 1
        if self._checks % 1000 == 0:
            self._forget_old(now)

    def check_address(self, request: Request, action: str) -> None:
        host = request.client.host if request.client else ""
        if host in LOCAL:
            return
        self.check(action, hashlib.sha256(host.encode()).hexdigest()[:16])

    def _forget_old(self, now: float) -> None:
        """Keys with no hit inside the longest window: memory does not grow with every address ever seen."""
        longest = max(w for _, w in LIMITS.values())
        for key in [k for k, hits in self._hits.items() if not hits or hits[-1] <= now - longest]:
            del self._hits[key]
