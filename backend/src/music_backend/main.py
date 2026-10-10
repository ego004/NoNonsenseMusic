import asyncio
import logging
import time
from contextlib import asynccontextmanager
from typing import get_args, Annotated, Literal
from uuid import UUID

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from psycopg import errors

from music_backend.core import db, ratelimit
from music_backend.services import auth, library, cache, genius, lyrics, friends, notifications, jam
from music_backend.services.matching import rank_songs, merge_youtube, rank_albums, rank_artists
from music_backend.models import (EventRequest, LibrarySong, ListingsRequest, Listing, SearchResponse,
                                  SearchSourceInfo, SongRef, SourceName, PlaylistRequest, PlaylistMetadata,
                                  PlaylistsResponse, PlaylistItemRef, PlaylistItems, MoveRequest, PrefetchRequest,
                                  RadioRequest, RadioResponse,
                                  LyricsRequest, LyricsResponse, Session, SignInRequest, SignUpRequest, User,
                                  PlaylistUpdate, ShareRequest, DeviceNameRequest, Member, GeniusRequest,
                                  RecoverRequest, PasswordRequest, RecoveryCodes, RecoveryCodesLeft,
                                  GeniusResponse, FriendUser, FriendRequests, RespondRequest, FriendRequest,
                                  Notification, NotificationsResponse, WSTicket, MarkReadResponse,
                                  AlbumRef, ArtistRef, AlbumDetail, ArtistDetail, PinAlbumRequest,
                                  JamCreateRequest, JamJoinRequest, JamCommand, JamState)
from music_backend.core.settings import settings
from music_backend.sources import SongNotFound, SourceUnavailable, jiosaavn, ytmusic, youtube


@asynccontextmanager
async def lifespan(app: FastAPI):
    # runs once at startup (before yield) and once at shutdown (after yield)
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    await db.apply_schema(pool)
    app.state.pool = pool
    app.state.limits = ratelimit.Limiter()                        # rate limits (core/ratelimit.py): counts in memory
    app.state.url_cache = cache.ListingURLCache(SOURCES, pool)   # one cache for every request; it borrows connections from the pool
    app.state.lyrics_cache = cache.LyricsCache(pool)
    app.state.genius_cache = cache.GeniusCache(pool)
    app.state.hub = notifications.NotificationHub()               # WebSocket connections + one-time WS tickets
    app.state.jams = jam.JamHub()                                 # jam rooms: in memory, lost on restart by design
    # the prefetch workers: N separate tasks, running by themselves; the list keeps them alive
    # (a list comprehension: `[create_task(...)] * N` would be ONE task listed N times)
    app.state.prefetch_workers = [asyncio.create_task(app.state.url_cache.prefetch_worker())
                                  for _ in range(settings.num_prefetch_workers)]
    # expired sessions: once now, before any request, then every 6 h
    async with pool.connection() as conn:
        await auth.delete_expired_sessions(conn)
    app.state.session_cleanup = asyncio.create_task(auth.clean_sessions_forever(pool))
    app.state.notification_cleanup = asyncio.create_task(notifications.clean_forever(pool))

    yield

    # shutdown, in this order: the workers, then lookups still running, then the pool they write to
    stopping = ([app.state.session_cleanup, app.state.notification_cleanup] + app.state.prefetch_workers
                + list(app.state.url_cache.running.values())
                + list(app.state.lyrics_cache.running.values()) + list(app.state.genius_cache.running.values()))
    for task in stopping:
        task.cancel()
    await asyncio.gather(*stopping, return_exceptions=True)       # wait until they have really stopped
    await asyncio.gather(*(source.http.close() for source in SOURCES.values()))   # the sources' kept connections
    await lyrics.http.close()                                                     # and LRCLIB's
    await genius.http.close()                                                     # and Genius's
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

SOURCES = {"jiosaavn" : jiosaavn, "ytmusic" : ytmusic, "youtube" : youtube}
# fail at startup, not at the first request, if this table and SourceName ever drift apart
assert set(SOURCES) == set(get_args(SourceName)), f"SOURCES {set(SOURCES)} != SourceName {get_args(SourceName)}"


# ---------- signed in, and the playlist errors (AUTH-3) ----------
# `user: Signed` on a route = only for a signed-in request (else 401), and here is the user. Every route needs it but
# /health, /auth/signup and /auth/signin.
Signed = Annotated[User, Depends(auth.current_user)]


def per_account(action: str):
    """`user: Annotated[User, Depends(per_account("search"))]`: signed in, and within that account's limit (429)."""
    async def check(request: Request, user: Signed) -> User:
        request.app.state.limits.check(action, str(user.id))
        return user
    return check

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

@app.exception_handler(library.IsAlbum)
async def _is_album(request: Request, e: library.IsAlbum) -> JSONResponse:
    return JSONResponse(status_code=400, content={"detail": "This is a pinned album; delete it to unpin"})


# the friends errors, answered the same way everywhere
@app.exception_handler(friends.NoSuchUser)
async def _friends_no_such_user(request: Request, e: friends.NoSuchUser) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "No account with that username"})

@app.exception_handler(friends.AlreadyFriends)
async def _already_friends(request: Request, e: friends.AlreadyFriends) -> JSONResponse:
    return JSONResponse(status_code=409, content={"detail": "Already friends"})

@app.exception_handler(friends.RequestPending)
async def _request_pending(request: Request, e: friends.RequestPending) -> JSONResponse:
    return JSONResponse(status_code=409, content={"detail": "Request already pending"})

@app.exception_handler(friends.NoRequest)
async def _no_request(request: Request, e: friends.NoRequest) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "No pending request from that user"})

@app.exception_handler(friends.NotFriends)
async def _not_friends(request: Request, e: friends.NotFriends) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "Not friends with that user"})


@app.get("/health")
async def health():
    return {"status": "ok"}


async def search_one(name: SourceName, source, q: str, *, songs: bool = True, albums: bool = True,
                     artists: bool = True
                     ) -> tuple[list[Listing], list[AlbumRef], list[ArtistRef], SearchSourceInfo]:
    """Run one source's searches (whichever kinds the filter asked for) at once: time them, count the
    results, and never raise.

    Any failure (timeout, a changed reply shape, bad data) becomes an error message in its
    SearchSourceInfo, so one broken source cannot take down the other. A source without albums
    (plain YouTube has none) simply has no search_albums and is never asked for one.
    """
    start = time.perf_counter()
    found: dict[str, list] = {"songs" : [], "albums" : [], "artists" : []}
    errors: list[str] = []

    async def run(kind: str, fn) -> None:
        try:
            found[kind] = await fn(q)
        except Exception as e:
            logger.warning("%s %s search failed for %r: %r", name, kind, q, e)
            errors.append(type(e).__name__)

    jobs = []
    if songs:
        jobs.append(("songs", source.search))
    if albums and (album_search := getattr(source, "search_albums", None)) is not None:
        jobs.append(("albums", album_search))
    if artists and (artist_search := getattr(source, "search_artists", None)) is not None:
        jobs.append(("artists", artist_search))
    await asyncio.gather(*(run(kind, fn) for kind, fn in jobs))
    ms = round((time.perf_counter() - start) * 1000)
    error = errors[0] if errors else None
    info = SearchSourceInfo(source = name, healthy = error is None, num_results = len(found["songs"]),
                            ms = ms, num_albums = len(found["albums"]),
                            num_artists = len(found["artists"]), error = error)
    return found["songs"], found["albums"], found["artists"], info


# ---------- a shared playlist's link (8 Oct) ----------
# What people share is this web address: chat apps make it clickable, and the page hands over to the app's own link
# (nononsense://playlist/<id>, which the app registers). Open (no sign-in): it names no playlist and shows nothing of
# one, so it reveals nothing; the app then opens it only for someone allowed to see it (public, or shared with them).
PLAYLIST_LINK_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Open in NoNonsense</title>
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #f5f5f7; --accent: #0a84ff }
  @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
         font: 16px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif; padding: 0 16px }
  main { text-align: center; max-width: 360px }
  a.open { display: inline-block; margin: 16px 0; padding: 10px 22px; border-radius: 999px; background: var(--accent);
           color: white; text-decoration: none; font-weight: 600 }
  p { color: var(--muted) }
</style></head>
<body><main>
  <h1>A playlist on NoNonsense</h1>
  <a class="open" href="nononsense://playlist/{id}">Open in NoNonsense</a>
  <p>Nothing opened? The app is at <a href="https://github.com/ego004/NoNonsenseMusic">github.com/ego004/NoNonsenseMusic</a>.</p>
</main>
<script>location.href = "nononsense://playlist/{id}"</script>
</body></html>"""

@app.get("/p/{playlist_id}", response_class=HTMLResponse)
async def playlist_link(playlist_id: UUID) -> HTMLResponse:
    # a UUID only (FastAPI checks it): nothing typed into the address reaches the page
    return HTMLResponse(PLAYLIST_LINK_PAGE.replace("{id}", str(playlist_id)))


@app.get("/search")
async def search(q: str, user: Annotated[User, Depends(per_account("search"))],
                 youtube: bool = False,
                 filter: Literal["all", "songs", "albums", "artists"] = "all") -> SearchResponse:
    """Songs, albums and artists from every source at once — or only what `filter` asks for.

    youtube: also search plain YouTube (MUS-13). Off by default, so a normal search never asks it;
    when on, its videos rank below every music-source song (merge_youtube) and its channels join
    the artists. albums come from the music sources only: plain YouTube has no albums.
    """
    logger.debug("Received search query : %s", q)
    active = dict(SOURCES)
    if not youtube:
        active.pop("youtube", None)
    want = {"songs" : filter in ("all", "songs"),
            "albums" : filter in ("all", "albums"),
            "artists" : filter in ("all", "artists")}
    # every source runs at the same time; each one's failures stay inside its own search_one
    results = await asyncio.gather(*(search_one(name, source, q, **want) for name, source in active.items()))
    songs_by_source, videos = [], []
    albums_by_source, artists_by_source = [], []
    sources = []
    for song_listings, album_refs, artist_refs, info in results:
        sources.append(info)
        if info.source == "youtube":
            videos = song_listings
            artists_by_source.append(artist_refs)      # kept last: the channels are the least preferred copy
        else:
            songs_by_source.append(song_listings)
            albums_by_source.append(album_refs)
            artists_by_source.append(artist_refs)
    songs = rank_songs(songs_by_source)
    if videos:
        songs = merge_youtube(songs, videos)
    return SearchResponse(query = q, sources = sources, songs = songs,
                          albums = rank_albums(albums_by_source), artists = rank_artists(artists_by_source))

# ---------- one album, one artist (MUS-20) ----------
# Read-only pages: tracks come back as ordinary songs (score 0, one listing each) in the source's
# own order, so the app plays them exactly like search results. Nothing is written to the database.

@app.get("/album/{source}/{source_id}")
async def album_detail(user: Annotated[User, Depends(per_account("album"))],
                       source: SourceName, source_id: str) -> AlbumDetail:
    """One album's tracks, in track order.

    Plain YouTube has no album entity at all (measured 10 Oct), so its module has no get_album
    and this answers "This source has no albums" (404) rather than asking it.
    """
    get = getattr(SOURCES[source], "get_album", None)
    if get is None:
        raise HTTPException(status_code=404, detail="This source has no albums")
    try:
        album = await get(source_id)
    except SourceUnavailable as e:      # also SourceBlocked: still 502, same as /play
        logger.warning("%s unavailable while opening album %r: %s", source, source_id, e)
        raise HTTPException(status_code=502, detail=f"{source} is unavailable right now")
    if album is None:
        raise HTTPException(status_code=404, detail="Album not found")
    return album


@app.get("/artist/{source}/{source_id}")
async def artist_detail(user: Annotated[User, Depends(per_account("artist"))],
                        source: SourceName, source_id: str) -> ArtistDetail:
    """One artist's info, top songs and albums — every source has artist pages (a channel counts)."""
    try:
        artist = await SOURCES[source].get_artist(source_id)
    except SourceUnavailable as e:
        logger.warning("%s unavailable while opening artist %r: %s", source, source_id, e)
        raise HTTPException(status_code=502, detail=f"{source} is unavailable right now")
    if artist is None:
        raise HTTPException(status_code=404, detail="Artist not found")
    return artist


@app.post("/albums/pin", status_code = 201)
async def pin_album(body: PinAlbumRequest, request: Request,
                    user: Annotated[User, Depends(per_account("album"))]) -> PlaylistMetadata:
    """Copy a source's album into your playlists as a pinned album: its tracks, in order, stored now.

    Same fetch as GET /album (404 no albums / unknown, 502 source down), then one transaction that writes the
    row and every item, so a pin is never half there. Pinning the same album twice is 409.
    """
    get = getattr(SOURCES[body.source], "get_album", None)
    if get is None:
        raise HTTPException(status_code=404, detail="This source has no albums")
    try:
        album = await get(body.source_id)
    except SourceUnavailable as e:
        logger.warning("%s unavailable while pinning album %r: %s", body.source, body.source_id, e)
        raise HTTPException(status_code=502, detail=f"{body.source} is unavailable right now")
    if album is None or not album.songs:
        raise HTTPException(status_code=404, detail="Album not found")
    async with request.app.state.pool.connection() as conn:
        async with conn.transaction():
            try:
                playlist_id = await library.pin_album(conn, user.id, body.source, body.source_id,
                                                      album.title, album.songs)
            except errors.UniqueViolation:      # the (user_id, source, source_id) pin index
                raise HTTPException(status_code=409, detail="You already pinned this album")
        return await library.get_playlist_metadata(conn, user.id, playlist_id)


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
async def prefetch_urls(body: PrefetchRequest, request: Request, user: Annotated[User, Depends(per_account("prefetch"))]) -> Response:
    """The listings coming next, in order: looked up in the background so they start at once when played.
    Answers 202 straight away; a newer list replaces what is still waiting. async def: it runs on the event loop,
    where the queue lives (asyncio.Queue is not thread-safe, and a plain def would run on another thread)."""
    request.app.state.url_cache.prefetch(user.id, body.listings)     # replaces YOUR waiting list only
    return Response(status_code = 202)


# ---------- radio (MUS-3) ----------

@app.post("/radio")
async def radio(body: RadioRequest, request: Request,
                user: Annotated[User, Depends(per_account("radio"))]) -> RadioResponse:
    """More songs to keep playing, seeded from the last song in the queue (MUS-3).

    Only the seed's own source is asked: a JioSaavn id means nothing to YouTube Music, and vice
    versa. The station's reply is ranked with the same machinery as search (group duplicates, keep
    the source's order), then the seed itself, the app's exclude list and the account's last 50
    played songs are dropped. 200 with fewer songs (possibly none: the app stops asking) is a
    normal answer; only the source being unreachable is 502, same as /play.
    """
    try:
        # one extra listing: every station leads with its own seed
        listings = await SOURCES[body.seed.source].radio(body.seed.source_id, body.limit + 1)
    except SourceUnavailable as e:
        logger.warning("%s unavailable while seeding radio from %r: %s", body.seed.source, body.seed.source_id, e)
        raise HTTPException(status_code=502, detail=f"{body.seed.source} is unavailable right now")
    exclude = {(ref.source, ref.source_id) for ref in body.exclude}
    exclude.add((body.seed.source, body.seed.source_id))
    async with request.app.state.pool.connection() as conn:
        exclude |= await library.recent_listing_refs(conn, user.id)
    kept = [listing for listing in listings if (listing.source, listing.id) not in exclude][: body.limit]
    return RadioResponse(songs = rank_songs([kept]))


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
    """The owner invites someone (or changes their role): viewer or editor. A new membership pushes a
    playlist_invite notification to the invitee over their WebSocket."""
    async with request.app.state.pool.connection() as conn:
        notification = await library.share_playlist(conn, user.id, playlist_id, body.username, body.role)
    if notification is not None:
        await request.app.state.hub.push(notification.user_id, {
            "type": "notification",
            "data": notification.model_dump(mode="json"),
        })
    return Response(status_code = 204)

@app.get("/playlists/{playlist_id}/members")
async def playlist_members(playlist_id: UUID, request: Request, user: Signed) -> list[Member]:
    """Its owner first, then who it is shared with: for the owner and the members (403 for a public viewer)."""
    async with request.app.state.pool.connection() as conn:
        return await library.playlist_members(conn, user.id, playlist_id)

@app.delete("/playlists/{playlist_id}/members/{member_id}", status_code = 204)
async def unshare_playlist(playlist_id: UUID, member_id: UUID, request: Request, user: Signed) -> Response:
    """The owner removes someone; anyone may remove themselves (leave)."""
    async with request.app.state.pool.connection() as conn:
        if not await library.unshare_playlist(conn, user.id, playlist_id, member_id):
            raise HTTPException(status_code = 404, detail = "Not a member of this playlist")
    return Response(status_code = 204)

# ---- lyrics -----

@app.post("/lyrics")
async def get_lyrics(body: LyricsRequest, request: Request, user: Annotated[User, Depends(per_account("lyrics"))]) -> LyricsResponse:
    """Always 200: no lyrics is an empty `lines`, not an error. From the lyrics table when it has them."""
    return await request.app.state.lyrics_cache(body)


@app.post("/genius")
async def get_genius(body: GeniusRequest, request: Request, user: Signed) -> GeniusResponse:
    """Genius notes (experimental; the apps ask only when Settings › Lyrics › Genius notes is on). 200 with no notes
    when Genius has no such song; 502 when Genius cannot be asked (nothing is kept then, so the next ask tries again)."""
    try:
        return await request.app.state.genius_cache(body)
    except genius.GeniusUnavailable as e:
        logger.warning("genius: %s", e)
        raise HTTPException(status_code = 502, detail = "Genius is unavailable right now")


# ---- accounts (AUTH-1): sign up, sign in, who am I, sign out ----

@app.post("/auth/signup", status_code=201)
async def signup(body: SignUpRequest, request: Request) -> Session:
    """A new account, signed in at once: the user and their first session on one connection, so both happen or
    neither does. 409 when the name is taken, whatever its capitals."""
    request.app.state.limits.check_address(request, "signup_address")
    async with request.app.state.pool.connection() as conn:
        try:
            user = await auth.create_user(conn, body.username, body.password)
        except auth.UsernameTaken:
            raise HTTPException(status_code=409, detail="That username is taken")
        token = await auth.create_session_token(conn, user.id, body.device_name)
        codes = await auth.replace_recovery_codes(conn, user.id)    # the way back in: shown this once
    return Session(token=token, user=user, recovery_codes=codes)


@app.post("/auth/recover")
async def recover(body: RecoverRequest, request: Request) -> Session:
    """A forgotten password: a recovery code (used up), a new password, every other device signed out, and this one
    signed in. One answer for an unknown name and a wrong code."""
    request.app.state.limits.check_address(request, "recover_address")
    request.app.state.limits.check("recover_username", body.username.lower())
    async with request.app.state.pool.connection() as conn:
        try:
            user = await auth.recover(conn, body.username, body.code, body.new_password)
        except auth.WrongRecovery:
            raise HTTPException(status_code=401, detail="Wrong username or recovery code")
        token = await auth.create_session_token(conn, user.id, body.device_name)
    return Session(token=token, user=user)


@app.get("/auth/recovery-codes")
async def recovery_codes_left(request: Request, user: Signed) -> RecoveryCodesLeft:
    """How many unused codes you have (Settings warns when few are left)."""
    async with request.app.state.pool.connection() as conn:
        return RecoveryCodesLeft(left=await auth.recovery_codes_left(conn, user.id))


@app.post("/auth/recovery-codes")
async def new_recovery_codes(body: PasswordRequest, request: Request, user: Signed) -> RecoveryCodes:
    """A new set of ten, replacing the old: your password again, so a session left open somewhere cannot do it."""
    async with request.app.state.pool.connection() as conn:
        try:
            await auth.check_password(conn, user.username, body.password)
        except auth.WrongCredentials:
            raise HTTPException(status_code=401, detail="Wrong password")
        return RecoveryCodes(codes=await auth.replace_recovery_codes(conn, user.id))


@app.post("/auth/signin")
async def signin(body: SignInRequest, request: Request) -> Session:
    """A new session for this device. One answer for a wrong password and for a name that does not exist."""
    request.app.state.limits.check_address(request, "signin_address")
    request.app.state.limits.check("signin_username", body.username.lower())
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


@app.patch("/auth/me/device", status_code=204)
async def rename_device(body: DeviceNameRequest, request: Request, user: Signed,
                        authorization: str | None = Header(default=None)) -> None:
    """Renames THIS device (the session the token belongs to). current_user has already checked the token."""
    token = (authorization or "").partition(" ")[2]
    async with request.app.state.pool.connection() as conn:
        await auth.rename_session(conn, token, body.device_name.strip() or "Unknown Device")


@app.post("/auth/signout", status_code=204)
async def signout(request: Request, user: Signed, authorization: str | None = Header(default=None)) -> None:
    """Ends this device's session only. current_user has already checked the token is valid (else 401)."""
    token = (authorization or "").partition(" ")[2]
    async with request.app.state.pool.connection() as conn:
        await auth.delete_session(conn, token)


# ---------- friends (FRIENDS-1) ----------

@app.post("/friends/request", status_code=201)
async def send_friend_request(body: FriendRequest, request: Request,
                              user: Annotated[User, Depends(per_account("friend_request"))]) -> None:
    """Send a friend request. 201 on success; 404 no such user; 400 yourself; 409 already friends or request pending."""
    async with request.app.state.pool.connection() as conn:
        try:
            notification = await friends.send_request(conn, user.id, body.username)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
    if notification is not None:
        await request.app.state.hub.push(notification.user_id, {
            "type": "notification",
            "data": notification.model_dump(mode="json"),
        })


@app.get("/friends/requests")
async def get_friend_requests(request: Request,
                             user: Annotated[User, Depends(per_account("friends"))]) -> FriendRequests:
    """Incoming and outgoing friend requests, each oldest first."""
    async with request.app.state.pool.connection() as conn:
        incoming, outgoing = await friends.list_requests(conn, user.id)
    return FriendRequests(incoming=incoming, outgoing=outgoing)


@app.post("/friends/respond", status_code=204)
async def respond_to_request(body: RespondRequest, request: Request,
                            user: Annotated[User, Depends(per_account("friends"))]) -> None:
    """Accept or decline a friend request. 404 if no pending request from that user."""
    async with request.app.state.pool.connection() as conn:
        notification = await friends.respond(conn, user.id, body.username, body.action)
    if notification is not None:
        await request.app.state.hub.push(notification.user_id, {
            "type": "notification",
            "data": notification.model_dump(mode="json"),
        })


@app.get("/friends")
async def get_friends(request: Request,
                      user: Annotated[User, Depends(per_account("friends"))]) -> list[FriendUser]:
    """Your friends, alphabetical by username."""
    async with request.app.state.pool.connection() as conn:
        return await friends.list_friends(conn, user.id)


@app.delete("/friends/{friend_id}", status_code=204)
async def remove_friend(friend_id: UUID, request: Request,
                        user: Annotated[User, Depends(per_account("friends"))]) -> None:
    """Remove a friend. 404 if you are not friends."""
    async with request.app.state.pool.connection() as conn:
        await friends.remove_friend(conn, user.id, friend_id)


# ---------- notifications (FRIENDS-1 Phase 2) ----------

@app.post("/ws-ticket")
async def ws_ticket(request: Request,
                    user: Annotated[User, Depends(per_account("notifications"))]) -> WSTicket:
    """Trade your JWT for a single-use 30-second ticket for the WebSocket handshake.

    The JWT never appears in a URL (access logs, proxies, browser history).
    """
    ticket = request.app.state.hub.issue_ticket(user.id, ttl_seconds=30)
    return WSTicket(ticket=ticket, expires_in=30)


@app.websocket("/ws/notifications")
async def ws_notifications(websocket: WebSocket, ticket: str = Query(...)) -> None:
    """Real-time notification push. Authenticated by a single-use ticket from POST /ws-ticket.

    On connect: sends {"type":"connected","unread":N} so the client knows it is live and can
    fetch its catch-up page. Then stays open until the client disconnects or the 30s heartbeat
    window passes with no message (a dead mobile connection).
    """
    hub = websocket.app.state.hub
    user_id = hub.redeem_ticket(ticket)
    if user_id is None:
        await websocket.close(code=4401, reason="invalid or expired ticket")
        return
    await websocket.accept()
    hub.register(user_id, websocket)
    try:
        async with websocket.app.state.pool.connection() as conn:
            unread = await notifications.unread_count(conn, user_id)
        await websocket.send_json({"type": "connected", "unread": unread})
        while True:
            # heartbeat: a message from the client every ~25s keeps this from timing out;
            # if the socket dies silently (mobile network change), receive_text raises or times out
            msg = await asyncio.wait_for(websocket.receive_text(), timeout=30)
            # the only client message we care about is a ping; anything else is ignored
            if msg == "ping":
                await websocket.send_json({"type": "pong"})
    except (asyncio.TimeoutError, WebSocketDisconnect):
        pass
    except Exception:
        logger.debug("ws/notifications for %s closed with an error", user_id, exc_info=True)
    finally:
        hub.unregister(user_id, websocket)
        try:
            await websocket.close()
        except Exception:
            pass  # already closed by the peer


@app.get("/notifications")
async def get_notifications(request: Request, user: Signed,
                            unread_only: bool = False,
                            after_seq: Annotated[int, Query(ge=0)] = 0,
                            before_seq: Annotated[int | None, Query(ge=0)] = None,
                            limit: Annotated[int, Query(ge=1, le=100)] = 50) -> NotificationsResponse:
    """Your notifications (newest first) plus the unread count.

    after_seq: catch-up cursor — send the last seq you saw (0 = from the start).
    before_seq: older than this seq (scrolling backwards).
    """
    async with request.app.state.pool.connection() as conn:
        return await notifications.list_notifications(
            conn, user.id,
            unread_only=unread_only, after_seq=after_seq,
            before_seq=before_seq, limit=limit,
        )


@app.post("/notifications/{notification_id}/read", status_code=200)
async def mark_notification_read(notification_id: UUID, request: Request, user: Signed) -> MarkReadResponse:
    """Mark one notification read. 404 only if it does not exist or is not yours; marking an
    already-read one again is a harmless 200 (idempotent — retries and double devices)."""
    async with request.app.state.pool.connection() as conn:
        result = await notifications.mark_read(conn, user.id, notification_id)
        if result == "not_found":
            raise HTTPException(status_code=404, detail="Notification not found")
        count = await notifications.unread_count(conn, user.id)
    if result == "read":
        # other devices on the same account need to hear about it too (flaw #5);
        # already_read changed nothing, so there is nothing to sync
        await request.app.state.hub.push(user.id, {
            "type": "notification_read",
            "data": {"id": str(notification_id), "unread": count},
        })
    return MarkReadResponse(unread_count=count)


@app.post("/notifications/read-all", status_code=200)
async def mark_all_notifications_read(request: Request, user: Signed) -> MarkReadResponse:
    """Mark every unread notification read. Returns the (now zero) unread count."""
    async with request.app.state.pool.connection() as conn:
        await notifications.mark_all_read(conn, user.id)
        count = await notifications.unread_count(conn, user.id)
    await request.app.state.hub.push(user.id, {
        "type": "notifications_cleared",
        "data": {"unread": count},
    })
    return MarkReadResponse(unread_count=count)


@app.get("/notifications/unread-count")
async def notification_unread_count(request: Request, user: Signed) -> MarkReadResponse:
    """Just the badge count (cheap: one indexed count)."""
    async with request.app.state.pool.connection() as conn:
        return MarkReadResponse(unread_count=await notifications.unread_count(conn, user.id))


# ---------- jam (JAM-1): one host plays, everyone else holds the remote ----------

@app.post("/jam", status_code=201)
async def create_jam(body: JamCreateRequest, request: Request,
                     user: Annotated[User, Depends(per_account("jam"))]) -> JamState:
    """Open a jam room. You are its host (the speakers) and its first member. The 8-character
    code is what you give to other people; the room lives in this process and is lost on restart."""
    room = request.app.state.jams.create(user.id, user.username, body.name)
    return request.app.state.jams.state(room)


@app.post("/jam/join")
async def join_jam(body: JamJoinRequest, request: Request,
                   user: Annotated[User, Depends(per_account("jam"))]) -> JamState:
    """Join a room by its code. Joining a room you are already in does nothing (same state back)."""
    try:
        room = request.app.state.jams.join(user.id, user.username, body.code)
    except jam.RoomNotFound:
        raise HTTPException(status_code=404, detail="No room with that code")
    return request.app.state.jams.state(room)


@app.get("/jam/{room_id}")
async def get_jam(room_id: UUID, request: Request, user: Signed) -> JamState:
    """The room's current state. 404 for a missing room or when you are not a member."""
    try:
        room = request.app.state.jams.require(room_id, user.id)
    except jam.RoomNotFound:
        raise HTTPException(status_code=404, detail="No such room")
    return request.app.state.jams.state(room)


@app.post("/jam/{room_id}/host", status_code=204)
async def take_jam_host(room_id: UUID, request: Request, user: Signed) -> Response:
    """Take the speakers: you become the host, the old host's app stops playing. Any member may."""
    try:
        room = request.app.state.jams.take_host(user.id, room_id)
    except jam.RoomNotFound:
        raise HTTPException(status_code=404, detail="No such room")
    await request.app.state.jams.broadcast(room, {"type": "state", "data": request.app.state.jams.state(room).model_dump(mode="json")})
    return Response(status_code=204)


@app.post("/jam/{room_id}/leave", status_code=204)
async def leave_jam(room_id: UUID, request: Request, user: Signed) -> Response:
    """Leave the room. If you were the host, the next member by join order inherits the speakers;
    if you were the last member, the room closes."""
    try:
        room = request.app.state.jams.leave(user.id, room_id)
    except jam.RoomNotFound:
        raise HTTPException(status_code=404, detail="No such room")
    except jam.NotAMember:
        raise HTTPException(status_code=404, detail="You are not in this room")
    if room is not None:
        await request.app.state.jams.broadcast(room, {"type": "state", "data": request.app.state.jams.state(room).model_dump(mode="json")})
    return Response(status_code=204)


@app.websocket("/ws/jam")
async def ws_jam(websocket: WebSocket, ticket: str = Query(...), room_id: UUID = Query(...)) -> None:
    """The room's live channel: connect with a single-use ticket from POST /ws-ticket plus the room
    id. On connect you get the full state; after that, send JamCommand JSON ("ping" for the
    heartbeat) and you will receive {"type":"state"} after every mutation, or {"type":"position"}
    pushes while the host plays. A dropped socket is not a leave — reconnect, or POST leave."""
    hub = websocket.app.state.hub
    jams = websocket.app.state.jams
    user_id = hub.redeem_ticket(ticket)
    if user_id is None:
        await websocket.close(code=4401, reason="invalid or expired ticket")
        return
    try:
        room = jams.require(room_id, user_id)
    except jam.RoomNotFound:
        await websocket.close(code=4403, reason="not a member of this room")
        return
    await websocket.accept()
    jams.register(websocket, user_id, room_id)
    try:
        await websocket.send_json({"type": "state", "data": jams.state(room).model_dump(mode="json")})
        while True:
            raw = await asyncio.wait_for(websocket.receive_text(), timeout=30)
            if raw == "ping":
                await websocket.send_json({"type": "pong"})
                continue
            try:
                cmd = JamCommand.model_validate_json(raw)
            except Exception:
                await websocket.send_json({"type": "error", "detail": "Unknown command."})
                continue
            # the room may have closed (last member left) or membership may have changed mid-session
            if jams.get(room_id) is None:
                await websocket.close(code=4404, reason="room closed")
                return
            await jams.handle_command(room, user_id, cmd, websocket)
    except (asyncio.TimeoutError, WebSocketDisconnect):
        pass
    except Exception:
        logger.debug("ws/jam for %s closed with an error", user_id, exc_info=True)
    finally:
        jams.unregister(websocket)
        try:
            await websocket.close()
        except Exception:
            pass
