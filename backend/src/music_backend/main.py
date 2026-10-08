import asyncio
import logging
import time
from contextlib import asynccontextmanager
from typing import get_args, Annotated
from uuid import UUID

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, Query
from fastapi.responses import JSONResponse, RedirectResponse
from psycopg import errors

from music_backend.core import db
from music_backend.services import auth, library, cache, lyrics
from music_backend.services.matching import rank_songs
from music_backend.models import (EventRequest, LibrarySong, ListingsRequest, Listing, SearchResponse,
                                  SearchSourceInfo, SongRef, SourceName, PlaylistRequest, PlaylistMetadata,
                                  PlaylistsResponse, PlaylistItemRef, PlaylistItems, MoveRequest, PrefetchRequest,
                                  LyricsRequest, LyricsResponse, Session, SignInRequest, SignUpRequest, User,
                                  PlaylistUpdate, ShareRequest)
from music_backend.core.settings import settings
from music_backend.sources import SongNotFound, SourceUnavailable, jiosaavn, ytmusic


@asynccontextmanager
async def lifespan(app: FastAPI):
    # runs once at startup (before yield) and once at shutdown (after yield)
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    await db.apply_schema(pool)
    app.state.pool = pool
    app.state.url_cache = cache.ListingURLCache(SOURCES, pool)   # one cache for every request; it borrows connections from the pool
    app.state.lyrics_cache = cache.LyricsCache(pool)
    # the prefetch workers: N separate tasks, running by themselves; the list keeps them alive
    # (a list comprehension: `[create_task(...)] * N` would be ONE task listed N times)
    app.state.prefetch_workers = [asyncio.create_task(app.state.url_cache.prefetch_worker())
                                  for _ in range(settings.num_prefetch_workers)]
    # expired sessions: once now, before any request, then every 6 h
    async with pool.connection() as conn:
        await auth.delete_expired_sessions(conn)
    app.state.session_cleanup = asyncio.create_task(auth.clean_sessions_forever(pool))

    yield

    # shutdown, in this order: the workers, then lookups still running, then the pool they write to
    stopping = ([app.state.session_cleanup] + app.state.prefetch_workers + list(app.state.url_cache.running.values())
                + list(app.state.lyrics_cache.running.values()))
    for task in stopping:
        task.cancel()
    await asyncio.gather(*stopping, return_exceptions=True)       # wait until they have really stopped
    await asyncio.gather(*(source.http.close() for source in SOURCES.values()))   # the sources' kept connections
    await lyrics.http.close()                                                     # and LRCLIB's
    await pool.close()


app = FastAPI(title="music", lifespan=lifespan)
# INFO for everything, DEBUG for our own logger. httpx logs every request it sends at INFO ("HTTP Request: …"):
# WARNING for it, so the log keeps what matters (it was 80 of 2,178 lines, 7 Oct)
logging.basicConfig(level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)


class _NoHealthChecks(logging.Filter):
    """Leaves /health out of the access log: the app asks it while waiting for the server to start, and the lines
    say nothing (/health was 1,141 of 2,178 log lines, 7 Oct)."""
    def filter(self, record: logging.LogRecord) -> bool:
        return "/health" not in record.getMessage()


logging.getLogger("uvicorn.access").addFilter(_NoHealthChecks())
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

SOURCES = {"jiosaavn" : jiosaavn, "ytmusic" : ytmusic}
# fail at startup, not at the first request, if this table and SourceName ever drift apart
assert set(SOURCES) == set(get_args(SourceName)), f"SOURCES {set(SOURCES)} != SourceName {get_args(SourceName)}"


# ---------- signed in, and the playlist errors (AUTH-3) ----------
# `user: Signed` on a route = only for a signed-in request (else 401), and here is the user. Every route needs it but
# /health, /auth/signup and /auth/signin.
Signed = Annotated[User, Depends(auth.current_user)]

# the playlist errors, answered the same way everywhere: no try/except per route
@app.exception_handler(library.NoSuchPlaylist)
async def _no_such_playlist(request: Request, e: library.NoSuchPlaylist) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "Playlist not found"})

@app.exception_handler(library.NotAllowed)
async def _not_allowed(request: Request, e: library.NotAllowed) -> JSONResponse:
    return JSONResponse(status_code=403, content={"detail": "Your role on this playlist does not allow that"})

@app.exception_handler(library.NoSuchUser)
async def _no_such_user(request: Request, e: library.NoSuchUser) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "No account with that username"})


@app.get("/health")
async def health():
    return {"status": "ok"}


async def search_one(name: SourceName, source, q: str) -> tuple[list[Listing], SearchSourceInfo]:
    """Run one source's search: time it, count its listings, and never raise.

    Any failure (timeout, a changed reply shape, bad data) becomes an error message
    in its SearchSourceInfo, so one broken source cannot take down the other.
    """
    start = time.perf_counter()
    try:
        listings = await source.search(q)
        error = None
    except Exception as e:
        logger.warning("%s failed for %r: %r", name, q, e)
        listings = []
        error = type(e).__name__
    ms = round((time.perf_counter() - start) * 1000)
    info = SearchSourceInfo(source = name, healthy = error is None, num_results = len(listings), ms = ms, error = error)
    return listings, info


@app.get("/search")
async def search(q: str, user: Signed) -> SearchResponse:
    logger.debug("Received search query : %s", q)
    # every source runs at the same time; each one's failure stays inside its own search_one
    results = await asyncio.gather(*(search_one(name, source, q) for name, source in SOURCES.items()))
    by_source = []
    sources = []
    for source_listings, info in results:
        by_source.append(source_listings)
        sources.append(info)
    return SearchResponse(query = q, sources = sources, songs = rank_songs(by_source))

@app.get("/play/{source}/{source_id}")
async def play(request: Request, user: Signed, source: SourceName, source_id: str, serve_fresh: bool = False) -> RedirectResponse:
    # source is checked by FastAPI against SourceName: an unknown source gets a 422 before we run
    try:
        if serve_fresh:
            # the app asks for this only when the cached URL failed to play: this log is the failure count
            logger.info("serve_fresh for %s %r", source, source_id)
        song_url = await request.app.state.url_cache(source, source_id, serve_fresh)
    except SongNotFound:
        logger.warning("%s has no playable song %r", source, source_id)
        raise HTTPException(status_code=404, detail="Song not found")
    except SourceUnavailable as e:
        logger.warning("%s unavailable while resolving %r: %s", source, source_id, e)
        raise HTTPException(status_code=502, detail=f"{source} is unavailable right now")
    # redirect, not proxy: the browser fetches the audio straight from the CDN, so it never passes
    # through this server. Fine while browser and server share an IP (YouTube URLs are tied to it).
    return RedirectResponse(song_url)

# ---------- prefetch ----------

@app.post("/prefetch", status_code = 202)
async def prefetch_urls(body: PrefetchRequest, request: Request, user: Signed) -> Response:
    """The listings coming next, in order: looked up in the background so they start at once when played.
    Answers 202 straight away; a newer list replaces what is still waiting. async def: it runs on the event loop,
    where the queue lives (asyncio.Queue is not thread-safe, and a plain def would run on another thread)."""
    request.app.state.url_cache.prefetch(user.id, body.listings)     # replaces YOUR waiting list only
    return Response(status_code = 202)


# ---------- library ----------

@app.post("/liked")
async def like_song(body: ListingsRequest, request: Request, user: Signed) -> SongRef:
    """Like a song. The app sends the song's listings; the server finds or creates the stored song."""
    async with request.app.state.pool.connection() as conn:
        song_id = await library.resolve_song(conn, body.listings)
        await library.like(conn, user.id, song_id)
    return SongRef(song_id = song_id)


@app.delete("/liked/{song_id}", status_code = 204)
async def unlike_song(song_id: UUID, request: Request, user: Signed) -> Response:
    async with request.app.state.pool.connection() as conn:
        if not await library.unlike(conn, user.id, song_id):
            raise HTTPException(status_code = 404, detail = "Song is not liked")
    return Response(status_code = 204)


@app.get("/liked")
async def get_liked(request: Request, user: Signed) -> list[LibrarySong]:
    async with request.app.state.pool.connection() as conn:
        return await library.liked_songs(conn, user.id)


@app.get("/recent")
async def get_recent(request: Request, user: Signed, limit: Annotated[int, Query(ge=1, le=200)] = 50) -> list[LibrarySong]:
    async with request.app.state.pool.connection() as conn:
        return await library.recent_songs(conn, user.id, limit)


@app.post("/events")
async def add_event(body: EventRequest, request: Request, user: Signed) -> SongRef:
    """Record a play, a skip (and at which second), or a finish."""
    async with request.app.state.pool.connection() as conn:
        song_id = await library.resolve_song(conn, body.listings)
        await library.record_event(conn, user.id, song_id, body.type, body.position)
    return SongRef(song_id = song_id)

#----- playlists -----
# who may do what is decided in library (_require): NoSuchPlaylist -> 404, NotAllowed -> 403, by the handlers above

@app.post("/playlists", status_code = 201)
async def create_playlist(body: PlaylistRequest, request: Request, user: Signed) -> PlaylistMetadata:
    async with request.app.state.pool.connection() as conn:
        try:
            playlist_id = await library.create_playlist(conn, user.id, body.name)
        except errors.UniqueViolation:
            raise HTTPException(status_code = 409, detail = "You already have a playlist with this name")
    return PlaylistMetadata(id = playlist_id, name = body.name, duration = 0, song_count = 0)

@app.get("/playlists")
async def get_playlists(request: Request, user: Signed) -> PlaylistsResponse:
    """Yours, then those shared with you, each with your role."""
    async with request.app.state.pool.connection() as conn:
        return PlaylistsResponse(playlists = await library.get_playlists(conn, user.id))

@app.post("/playlists/{playlist_id}/items", status_code = 201)
async def add_to_playlist(playlist_id: UUID, body: ListingsRequest, request: Request, user: Signed) -> PlaylistItemRef:
    async with request.app.state.pool.connection() as conn:
        # one transaction: a refused add (404, 403) also undoes the song resolve_song just stored
        async with conn.transaction():
            song_id = await library.resolve_song(conn, body.listings)
            item_id = await library.add_to_playlist(conn, user.id, playlist_id, song_id)
    return PlaylistItemRef(item_id = item_id, song_id = song_id)

@app.get("/playlists/{playlist_id}")
async def get_playlist_items(playlist_id: UUID, request: Request, user: Signed) -> PlaylistItems:
    async with request.app.state.pool.connection() as conn:
        metadata = await library.get_playlist_metadata(conn, user.id, playlist_id)
        items_list = await library.get_playlist_items(conn, user.id, playlist_id)
    return PlaylistItems(**metadata.model_dump(), items = items_list)

@app.patch("/playlists/{playlist_id}")
async def update_playlist(playlist_id: UUID, body: PlaylistUpdate, request: Request, user: Signed) -> PlaylistMetadata:
    """Rename, make public or private, or both: the owner only."""
    async with request.app.state.pool.connection() as conn:
        try:
            if body.name is not None:
                await library.rename_playlist(conn, user.id, playlist_id, body.name)
        except errors.UniqueViolation:
            raise HTTPException(status_code = 409, detail = "You already have a playlist with this name")
        if body.public is not None:
            await library.set_public(conn, user.id, playlist_id, body.public)
        return await library.get_playlist_metadata(conn, user.id, playlist_id)

@app.delete("/playlists/{playlist_id}", status_code = 204)
async def delete_playlist(playlist_id: UUID, request: Request, user: Signed) -> Response:
    async with request.app.state.pool.connection() as conn:
        await library.delete_playlist(conn, user.id, playlist_id)
    return Response(status_code = 204)

@app.delete("/playlists/{playlist_id}/items/{item_id}", status_code = 204)
async def remove_from_playlist(playlist_id: UUID, item_id: UUID, request: Request, user: Signed) -> Response:
    async with request.app.state.pool.connection() as conn:
        if not await library.remove_from_playlist(conn, user.id, playlist_id, item_id):
            raise HTTPException(status_code = 404, detail = "Song not in this playlist")
    return Response(status_code = 204)

@app.post("/playlists/{playlist_id}/items/{item_id}/move", status_code = 204)
async def move_in_playlist(playlist_id: UUID, item_id: UUID, body: MoveRequest, request: Request, user: Signed) -> Response:
    async with request.app.state.pool.connection() as conn:
        try:
            await library.move_item(conn, user.id, playlist_id, item_id, body.top_neighbour_id, body.bottom_neighbour_id)
        except library.NotInList:
            raise HTTPException(status_code = 404, detail = "Song not in this playlist")
        except library.BadMove as e:
            raise HTTPException(status_code = 422, detail = str(e))
    return Response(status_code = 204)

@app.post("/playlists/{playlist_id}/move", status_code = 204)
async def move_playlist(playlist_id: UUID, body: MoveRequest, request: Request, user: Signed) -> Response:
    """Reorders YOUR list; shared playlists keep their owner's order."""
    async with request.app.state.pool.connection() as conn:
        try:
            await library.move_playlist(conn, user.id, playlist_id, body.top_neighbour_id, body.bottom_neighbour_id)
        except library.NotInList:
            raise HTTPException(status_code = 404, detail = "Playlist not found")
        except library.BadMove as e:
            raise HTTPException(status_code = 422, detail = str(e))
    return Response(status_code = 204)

@app.put("/playlists/{playlist_id}/members", status_code = 204)
async def share_playlist(playlist_id: UUID, body: ShareRequest, request: Request, user: Signed) -> Response:
    """The owner invites someone (or changes their role): viewer or editor."""
    async with request.app.state.pool.connection() as conn:
        await library.share_playlist(conn, user.id, playlist_id, body.username, body.role)
    return Response(status_code = 204)

@app.delete("/playlists/{playlist_id}/members/{member_id}", status_code = 204)
async def unshare_playlist(playlist_id: UUID, member_id: UUID, request: Request, user: Signed) -> Response:
    """The owner removes someone; anyone may remove themselves (leave)."""
    async with request.app.state.pool.connection() as conn:
        if not await library.unshare_playlist(conn, user.id, playlist_id, member_id):
            raise HTTPException(status_code = 404, detail = "Not a member of this playlist")
    return Response(status_code = 204)

# ---- lyrics -----

@app.post("/lyrics")
async def get_lyrics(body: LyricsRequest, request: Request, user: Signed) -> LyricsResponse:
    """Always 200: no lyrics is an empty `lines`, not an error. From the lyrics table when it has them."""
    return await request.app.state.lyrics_cache(body)


# ---- accounts (AUTH-1): sign up, sign in, who am I, sign out ----

@app.post("/auth/signup", status_code=201)
async def signup(body: SignUpRequest, request: Request) -> Session:
    """A new account, signed in at once: the user and their first session on one connection, so both happen or
    neither does. 409 when the name is taken, whatever its capitals."""
    async with request.app.state.pool.connection() as conn:
        try:
            user = await auth.create_user(conn, body.username, body.password)
        except auth.UsernameTaken:
            raise HTTPException(status_code=409, detail="That username is taken")
        token = await auth.create_session_token(conn, user.id, body.device_name)
    return Session(token=token, user=user)


@app.post("/auth/signin")
async def signin(body: SignInRequest, request: Request) -> Session:
    """A new session for this device. One answer for a wrong password and for a name that does not exist."""
    async with request.app.state.pool.connection() as conn:
        try:
            user = await auth.check_password(conn, body.username, body.password)
        except auth.WrongCredentials:
            raise HTTPException(status_code=401, detail="Wrong username or password")
        token = await auth.create_session_token(conn, user.id, body.device_name)
    return Session(token=token, user=user)


@app.get("/auth/me")
async def me(user: Signed) -> User:
    """Who this token belongs to: the app's "am I still signed in?"."""
    return user


@app.post("/auth/signout", status_code=204)
async def signout(request: Request, user: Signed, authorization: str | None = Header(default=None)) -> None:
    """Ends this device's session only. current_user has already checked the token is valid (else 401)."""
    token = (authorization or "").partition(" ")[2]
    async with request.app.state.pool.connection() as conn:
        await auth.delete_session(conn, token)
