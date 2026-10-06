# Tickets

How this works:

1. Pick the next ticket. Make a branch named number + name: `git switch -c 1-fast-playback`. (Old branches `mus-1` to `mus-4` exist, so the old naming would collide.)
2. Bring a short **design note** (endpoints, tables, your decisions and why), get it reviewed, then build. Run the done-when checks yourself.
3. Tell Claude "MUS-1 ready". Claude runs every check, reviews the code (what is wrong + a failing case, never the fix), and **writes the tests after you are done**.
4. When everything passes: commit, merge into `main`, demo it to yourself, move on.

> **How these tickets are written:** each one gives the problem, the facts already checked, the deliverables, and the **decisions that are yours**. It does not say which tables, files or functions to use.

Stuck for more than 30 minutes? Bring: what you tried, what you expected, what happened.

> **Renumbered 5 Oct 2026.** Done and removed: resilient search, play, merge + rank, library, shuffle, and the Mac app v1. Git history and old commit messages use the old numbers. Old → new: 16 → 1 (and 4), 15 → 2, 8 → 3, 5 → 5, 9 → 6, 10 → 7, 6 + 11 → 8, 12 → 9, 13 → 10, 14 → 11.

> **Order (decided 5 Oct 2026):** MUS-2 playlists → MUS-1 steps 2, 2b, 3 (single-flight, back-off, prefetch) → MUS-3 autoplay → MUS-13 YouTube. Then lyrics and the rest.

| Ticket | What you can show at the end | Who | Size |
|---|---|---|---|
| MUS-1 | A YouTube song starts instantly the second time, and the next song is ready before you get there | **You** (backend) · Claude (app, tests after) | M |
| MUS-2 | Playlists: make, fill, reorder, cover image | **You** (backend) · Claude (app) | L |
| MUS-3 | When the queue ends, music keeps going, shaped by your skips | **You** (ranking, endpoint) · Claude (radio parser, app) | M |
| MUS-4 | Choose JioSaavn or YouTube Music as the default copy | **You** | S |
| MUS-5 | Your Spotify liked songs and playlists appear in your library | **You** (OAuth, API) · Claude (setup) | M |
| MUS-6 | Search your library: "weekend" finds The Weeknd, "sad arijit" works | **Pair** | L |
| MUS-7 | The second identical search is much faster, with numbers | **You** | M |
| MUS-8 | Your phone: an app, playing from your Mac over mobile data | **Pair** | L |
| MUS-9 | Every played song gets a "sounds like" vector | Claude (model setup) · **You** (background job) | M |
| MUS-10 | About 1 in 5 autoplay songs is new to you, and it learns which new ones you skip | **You** | M |
| MUS-11 | Your own "people who played X played Y" model, beating or losing to YouTube radio on your skip rate | **Pair** | L |
| MUS-12 | Lyrics in Now Playing, lit line by line in time with the song | **You** (backend) · Claude (app) | M |
| MUS-13 | Songs that exist only on plain YouTube, found with a "Search YouTube" switch | **You** (backend) · Claude (app) | M |

---

## MUS-1 · Fast playback: cache and prefetch

**Problem:** a YouTube song takes 2.8 s to start, every time. Most of what you play is YouTube-only (6 of your 9 plays, 5 Oct). Do the 2.8 s **once** per listing (cache), and **before** the click (prefetch).

**Facts already checked (5 Oct 2026)**
- `/play` takes 0.30 s for JioSaavn and 2.8 s for YouTube (yt-dlp). Every faster yt-dlp setting failed (bot checks, DRM, missing formats). Adding a JavaScript runtime (node) changed nothing: same speed, same formats.
- A YouTube audio URL carries `expire=` (a Unix time) and lives 6 hours. It works only from the IP address that asked for it.
- JioSaavn URLs showed no expiry.
- A search returns 25–38 songs. For 18–19 of them the best listing is YouTube.
- yt-dlp runs through `asyncio.to_thread`: Python's default thread pool, **14 threads** on your Mac, shared by every `/play` and every prefetch.
- 5 of your 6 stored songs have exactly one listing.
- `fastapi dev` restarts the server every time you save a backend file. Anything kept only in memory is lost.
- `listings` rows exist only for songs you liked or played. Search results have none.
- The app already tries a song's other listings when one fails (AVPlayer reports the failure), and asks for the next song early with `API.warm` (step 3 replaces it).

**Design (5 Oct 2026)**
- Cache per listing `(source, id)`.
- The rule: no cached URL, or `serve_fresh=true`, or the URL expires within the margin → fetch, refresh the cache, send. Otherwise send the cached URL. Failures are never cached. A failed fresh fetch returns the error, never the old URL.
- YouTube expiry comes from `expire=`. JioSaavn URLs never expire (if one ever dies, the app's `serve_fresh` refreshes it).
- The app picks listings. 2+ listings: switch to the next at once, and send `serve_fresh` for the failed one in the background. 1 listing: retry it with `serve_fresh` and show the spinner.
- One prefetch mechanism for everything. The app sends the **window**: the listings coming next, in order (a queue: the next 5; a search: the top 5; both at once: queue first). The newest window replaces queued work. Running lookups finish. Cached and running listings are skipped. At most 4 lookups at once, so a click always finds a free thread.
- One fetch per listing at a time: a second request for a listing being fetched waits for that fetch (single-flight).

**Steps** (each one runs and shows something on its own)

| Step | Build | Done when |
|---|---|---|
| 1 ✅ | The cache in memory: the rule, the margin, `serve_fresh` | Done 5 Oct: YouTube 1,786 ms → **3.7 ms**, JioSaavn 497.6 ms → **0.9 ms** on the second play; expired URLs refetched (tests) |
| 2 | Single-flight | Two requests at once for one listing make one source call |
| 2b | **Back off from a blocked source.** After YouTube's bot check (5 Oct: it came back the same evening), stop asking YouTube for a while and answer 502 at once. Today every blocked song costs 2 more YouTube requests (play + `serve_fresh`), which can lengthen the block, and step 3 will add prefetches | During the pause, a YouTube `/play` answers 502 without calling the source (fake source, fake clock); after it, the source is tried again |
| 3 | The prefetch endpoint: take the window, answer at once, fetch in the background with the rules above | Search, wait 10 s, click the top result: a cache hit |
| 4 ✅ | The cache survives a restart (a table) | Done 5 Oct: after a restart, 5 songs from the table, 0 source calls, 0.37 ms per table hit; both levels LRU (`hit_at`); a hit costs 0.83 ms with 6,000 rows |
| App | Claude: send the window; the failure handling above; show "Couldn't play …" (today it is silent); delete `warm` | Claude starts after your step 1 (failures) and step 3 (window) |

**Decisions that are yours**
- The margin: anything from 10 minutes to 5 hours (a long song plus seeks; 30 minutes suggested).
- Where the cache and the "running" dict live.
- Step 2b: how long to back off, and whether it grows when blocks repeat.
- The prefetch endpoint's path, method and body.
- The table in step 4: its columns. It must also hold search-result listings, which have no `listings` row.
- What the prefetch worker does when a lookup fails.

**Done when**
- [x] Measured: first `/play` of a YouTube song 1,786 ms; second 3.7 ms (5 Oct, *Blinding Lights*).
- [ ] Search, wait 10 s, click the top result: the log shows no yt-dlp call.
- [x] Every `serve_fresh` is logged: that log is your failure count.
- [ ] Tests: Claude writes them after you are done (`tests/test_cache.py` already covers step 1).

**Docs**
- Step 1: [`urllib.parse.urlparse`](https://docs.python.org/3/library/urllib.parse.html#urllib.parse.urlparse) and [`parse_qs`](https://docs.python.org/3/library/urllib.parse.html#urllib.parse.parse_qs) (read `expire=`) · [`time.time`](https://docs.python.org/3/library/time.html#time.time) · FastAPI [Query Parameters](https://fastapi.tiangolo.com/tutorial/query-params/) (see "Query parameter type conversion" for a `bool`)
- Step 2: asyncio [Creating Tasks](https://docs.python.org/3/library/asyncio-task.html#creating-tasks) (read the "Important" note about keeping a reference) · [Shielding From Cancellation](https://docs.python.org/3/library/asyncio-task.html#shielding-from-cancellation) · the idea, named: Go's [`singleflight`](https://pkg.go.dev/golang.org/x/sync/singleflight) (one paragraph; the problem it prevents is a "cache stampede")
- Step 3: FastAPI [Request Body](https://fastapi.tiangolo.com/tutorial/body/) · [`asyncio.Semaphore`](https://docs.python.org/3/library/asyncio-sync.html#asyncio.Semaphore) · [`asyncio.Queue`](https://docs.python.org/3/library/asyncio-queue.html) · [`Task.cancel`](https://docs.python.org/3/library/asyncio-task.html#asyncio.Task.cancel) · HTTP [202 Accepted](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/202) ("I took it, the work happens later")
- Step 4: PostgreSQL [`INSERT … ON CONFLICT DO UPDATE`](https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT) ("upsert")

---

## MUS-2 · Playlists

**Goal:** playlists you can create, fill, order, rename and delete. A cover image comes last.

**Decided (5 Oct 2026)**
- A playlist holds **songs**. The app sends a song's listings. The server finds or creates the song with `library.resolve_song`, the same as `/liked`.
- The same song can be in a playlist twice. Each row in `playlist_items` has its own id: the **item id**.
- You choose the order of your playlists, and the order of the songs in each one. Both use a `position` key from `fractional-indexing`.
- A move sends the new neighbours: the item above and the item below. One row changes.
- The server computes song count and duration.
- No play counts yet. (Later: `events` gets a `playlist_id`.)
- New file `playlists.py`, the same pattern as `library.py`: `main.py` opens the connection, `playlists.py` runs the SQL.

### Step 0 · Set up

1. Run `uv add fractional-indexing`. Use: `from fractional_indexing import generate_key_between`.

   | Call | Gives |
   |---|---|
   | `generate_key_between(None, None)` | `a0` (the first key) |
   | `generate_key_between("a0", None)` | `a1` (after `a0`) |
   | `generate_key_between("a0", "a1")` | `a0V` (between them) |
   | `generate_key_between(None, "a0")` | `Zz` (before `a0`) |
   | `generate_key_between("a1", "a0")` | raises `FIError` (wrong order) |

2. `schema.sql`: playlists get a position. Add the column in **two** places:
   - Inside `CREATE TABLE playlists`: `position text COLLATE "C" NOT NULL,`
   - After it: `ALTER TABLE playlists ADD COLUMN IF NOT EXISTS position text COLLATE "C" NOT NULL;`
   The table already exists, so `CREATE TABLE IF NOT EXISTS` skips it. The `ALTER` line adds the column. `NOT NULL` works because both databases have 0 playlists. The server runs `schema.sql` on every start.

3. `models.py`: the playlist models must be these.

   | Model | Fields | Change from now |
   |---|---|---|
   | `PlaylistRequest` | `name: str = Field(min_length=1)` | Rename `PlaylistCreationRequest`. Rename uses it too. |
   | `PlaylistMetadata` | `id: UUID`, `name: str`, `song_count: int`, `duration: int`, `thumbnail: str \| None = None` | Add `song_count`. Delete `num_plays`. |
   | `PlaylistsResponse` | `playlists: list[PlaylistMetadata]` | No change. |
   | `PlaylistItem` | `item_id: UUID`, `song: LibrarySong` | New. |
   | `PlaylistItems(PlaylistMetadata)` | `items: list[PlaylistItem]` | New: the open reply. |
   | `PlaylistItemRef` | `item_id: UUID`, `song_id: UUID` | New: the add reply (decided 6 Oct: the app already has the song it sent; the item id is the handle on the new row). |
   | `MoveRequest` | `top_neighbour_id: UUID \| None = None`, `bottom_neighbour_id: UUID \| None = None` | Was `PlaylistSongReorderRequest`. Delete `song_id`: it goes in the URL. Both are optional: the top has nothing above it. |

   Delete `PlaylistSongAdditionRequest` (use `ListingsRequest`) and `PlaylistSongRemovalRequest` (the item id goes in the URL).

**Done when:** the server starts.

### The endpoints

| Endpoint | Body | Reply | Step |
|---|---|---|---|
| `POST /playlists` | `PlaylistRequest` | 201 · `PlaylistMetadata` | 1 |
| `GET /playlists` | — | `PlaylistsResponse`, in your order | 1 |
| `POST /playlists/{playlist_id}/items` | `ListingsRequest` | 201 · `PlaylistItemRef` | 2 |
| `GET /playlists/{playlist_id}` | — | `PlaylistItems` | 2 |
| `PATCH /playlists/{playlist_id}` | `PlaylistRequest` | `PlaylistMetadata` | 3 |
| `DELETE /playlists/{playlist_id}` | — | 204 | 3 |
| `DELETE /playlists/{playlist_id}/items/{item_id}` | — | 204 | 3 |
| `POST /playlists/{playlist_id}/items/{item_id}/move` | `MoveRequest` | 204 | 4 |
| `POST /playlists/{playlist_id}/move` | `MoveRequest` | 204 | 4 |

- `{playlist_id}` in the path plus `playlist_id: UUID` in the function: FastAPI checks it is a UUID (422 if not).
- An id that does not exist: `raise HTTPException(status_code=404, detail="Playlist not found")`.
- 201: `@app.post("/playlists", status_code=201)`.

### Step 1 ✅ · Create and list

- A new playlist goes at the bottom: its position comes after the largest one so far. With no playlists yet, "the largest" is `None`.
- One query for all playlists with their song count and duration. The same query, limited to one id, gives the reply for create, rename and open.
- Traps (each one has a test):
  - A playlist with no songs must still be in the list. Some joins drop rows that have no match.
  - For that empty playlist, `count(*)` gives **1**. Counting a column from the joined table gives 0.
  - A `sum` over no rows is `NULL`, not 0. The model wants an `int`.

**Done when:**
```bash
curl -s -X POST localhost:8000/playlists -H 'content-type: application/json' -d '{"name":"Gym"}'
curl -s localhost:8000/playlists
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8000/playlists -H 'content-type: application/json' -d '{"name":""}'
```
Gym appears with `song_count` 0. The empty name gives 422.

### Step 2 ✅ · Add a song, open a playlist

- Add: the playlist must exist (404). The listings become a song the same way `/liked` does it. The item goes at the bottom of this playlist.
- Open: `library` already has a function that turns song rows into `LibrarySong`s. Read what columns it expects.
- Traps (each one has a test):
  - The same song added twice: open must show **two** items.
  - Two adds at the same moment can get the same position. The order must still be stable. (What else sorts by time?)

**Done when:**
```bash
P=<the Gym id>
curl -s 'localhost:8000/search?q=tum%20hi%20ho' > /tmp/search.json
for n in 0 1 2; do jq "{listings: .songs[$n].listings}" /tmp/search.json | curl -s -X POST localhost:8000/playlists/$P/items -H 'content-type: application/json' -d @-; done
curl -s localhost:8000/playlists/$P | jq '.items[].song.title'
```
One search, then 3 songs added from it (searching 3 times risks YouTube's bot check). Open shows them in that order. An unknown id gives 404.

### Step 3 ✅ · Rename, delete, remove

- Each one is a single statement. You already know how to tell "changed 1 row" from "changed nothing" (the cache used it): nothing changed → 404.
- Deleting a playlist must delete its items, and must **not** delete the songs. Read what `schema.sql` already does for you.
- Trap: removing an item must check it belongs to the playlist in the URL. Otherwise `DELETE /playlists/A/items/<an item of B>` removes from B.

**Done when:** you delete a playlist with 3 songs. Its items are gone from `playlist_items`, and the 3 songs are still in `songs`.

### Step 4 ✅ · Move

The same logic twice: songs in a playlist, and playlists in the list. Write it for songs first.
- The new position goes between the two neighbours' positions. A missing neighbour is `None`.
- Exactly one row changes.
- Traps (each one has a test):
  - A neighbour from a different playlist.
  - Neighbours in the wrong order (what does `generate_key_between` do then?).
  - Both neighbours missing.

**Done when:** songs A B C. Move C with `bottom_neighbour_id` = A and no top: the order is C A B, and one row changed.

### Step 5 · Cover image (after the app work)

- `GET` / `POST` / `DELETE /playlists/{playlist_id}/thumbnail`. `thumbnail` in `PlaylistMetadata` becomes that URL. `null` means no cover: the app draws a 2×2 grid of the first four songs.
- Safety: open the upload with Pillow and save it again as JPEG (this rejects non-images and removes EXIF/GPS). Reject files over 5 MB. Never use the uploaded filename.
- The app caches images by URL. Change the URL when the cover changes: `…/thumbnail?v=<upload time>`.

**Done when:** a text file renamed `.jpg` is rejected; a phone photo comes back without EXIF; a new cover has a new URL.

### After each step

Claude writes the pytest tests (against `music_test`). The app work (sidebar, playlist screen, "Add to playlist", drag to reorder) starts after step 2, when you say.

**Docs:** [fractional-indexing](https://github.com/httpie/fractional-indexing-python) · FastAPI [path parameters](https://fastapi.tiangolo.com/tutorial/path-params/) · FastAPI [Request Files](https://fastapi.tiangolo.com/tutorial/request-files/) · [Pillow](https://pillow.readthedocs.io/en/stable/reference/Image.html)

---

## APP · The Mac app (Claude), from your 6 Oct list

| # | What | Status |
|---|---|---|
| 1 | Shuffle as a mode (on/off, back to your order when off); repeat off / all / one | ✅ 6 Oct: 21 queue rules pass (`NN_SELFTEST_QUEUE`); ⌘S, ⌘R |
| 2 | Playlists: sidebar section, New Playlist, rename, delete, the playlist screen (2×2 cover, Play, Shuffle), "Add to Playlist" in every song's menu, remove, drag to reorder songs and playlists; a playing playlist's queue follows your edits | ✅ 6 Oct: the whole flow passes (`NN_SELFTEST_PLAYLISTS`); ⌘N. Not tested by a test: the drag gesture itself |
| 3 | Home: playlists, recently played and liked songs as a mix of horizontal shelves and grids | ✅ 6 Oct: the first screen; 4 covers, 4 cards, 4 rows appear for 4/4/4 test items (`NN_SELFTEST_HOME`) |
| 4 | Now Playing focus: a button that makes it the centre of the window, laid out with room for lyrics (MUS-12) | ✅ 6 Oct: 💬 ☰ ⤢ on the bar; Lyrics / Up Next panel or the song alone; full screen (`NN_SELFTEST_NOWPLAYING`) |
| 5 | Your sizes: text size and card size in Settings › Appearance | ✅ 6 Oct: 0.85…1.4 × the Mac's text (1.0 = exactly as before, measured), cards 116…210 pt |
| 6 | Motion: messages, dragging, lists changing; all of it off with Reduce Motion | ✅ 6 Oct: see Motion in docs/mac-app.md. Not checked by a test: how the shakes look |
| — | Extra: recent searches on the idle Search screen (only searches that led to a song you played; the duplicate Recently Played shelf left Search, Home has it). CPU checked: 0% idle, ~2.5% playing | ✅ 6 Oct |
| — | From the MUS-2 list: the playlist's name in the Discord status (Settings › Discord › Share, off by default) and "From “Gym”" in Now Playing; Settings in collapsible sections (Colours on its own, so the page fits a MacBook screen) | ✅ 6 Oct |
| — | Fixed 6 Oct: a test server could outlive its app and keep the port (now: one launcher, one start at a time, the whole process family stopped); the server log overwrote itself (now append mode) | ✅ |
| — | Fixed 6 Oct: "That JioSaavn copy is gone. Playing another JioSaavn copy." (was a contradiction); self-test windows say "Self-test · test library" | ✅ |

---

## MUS-3 · Autoplay

**Problem:** when the queue ends, the music stops. It should continue with songs you will probably like, and keep going.

**Facts already checked**
- YouTube Music radio: `POST youtubei/v1/next` with `videoId` and `playlistId = "RDAMVM" + videoId` returns about 50 related songs (verified 2 Oct 2026).
- Your `events` table records every play, skip (with the second) and finish.
- A song only has a YouTube Music listing if one was found; some stored songs are JioSaavn-only.
- Neither source gives an ISRC (checked 29 Sep 2026). To find a JioSaavn copy of a radio song: search title + artist, then `same_recording`.
- Autoplay songs are just more queue: MUS-1's prefetch window covers them, no extra prefetch work.

**Deliverables**
1. An endpoint the app calls to get the next songs after a given song.
2. Ranking that uses **your** history: songs you skipped in the first 30 seconds are pushed down or removed; artists you finish or like are pushed up.
3. No repeats: nothing played in the last hour, nothing already in the queue.
4. Endless: the app asks again before the queue runs out, starting from the last song in the queue.
5. A number: your skip rate on autoplay songs (skips in the first 30 s ÷ autoplay plays), visible somewhere (an endpoint is enough).

**Decisions that are yours**
- The endpoint's shape: `GET` with a song ID, or `POST` with listings? How many songs per call?
- What to do when the seed song has no YouTube Music listing.
- How strong each ranking signal is, and how you will know your ranking is better than the radio's own order.
- When the app should ask for more (how many songs left?).

**Done when**
- [ ] Play one song, let the queue run out: music continues, 3 batches in a row, no repeats.
- [ ] A song you skipped early yesterday does not come back today.
- [ ] pytest covers the ranking rules with fake candidates (no network).
- [ ] The skip-rate number is shown.

**Docs:** [Spotify BaRT (explore/exploit, for later)](https://research.atspotify.com/publications/explore-exploit-explain-personalizing-explainable-recommendations-with-bandits) · your own `samples/` folder for a saved radio reply

---

## MUS-4 · A preferred source

**Problem:** when a song has both copies, JioSaavn always plays. You want to choose the default.

**Facts already checked**
- `pick_best` decides the copy: JioSaavn first, then popularity, then closest to the median duration. It runs inside `/search`, `/liked` and `/recent`, so `best` arrives in the app already chosen.
- The app plays `best` and falls back to the other listings in order.

**Deliverable:** a setting (JioSaavn or YouTube Music) that changes which copy plays first, everywhere: search, Liked, Recent, playlists, autoplay.

**Decisions that are yours**
- Where the preference is stored (the app or the server), and how `pick_best` learns it.
- What happens to songs already in the queue when the setting changes.

**Done when**
- [ ] Switching to YouTube Music makes *Blinding Lights* play the YouTube copy.
- [ ] pytest: `pick_best` with each preference.

---

## MUS-5 · Spotify import (solves cold start)

**Why:** an empty library teaches autoplay and recommendations nothing. Your Spotify history is years of taste.

**Step 0, a decision (checked 5 Oct 2026, second-hand):** since February 2026, registering a Spotify developer app reportedly **requires Spotify Premium**, and development-mode apps allow at most 5 users. Redirect URIs must use `http://127.0.0.1:<port>`; `localhost` is rejected (enforced since 27 Nov 2025). So pick a path:

| Path | Needs | You learn |
|---|---|---|
| **A. Web API** | Premium on the account that creates the app | OAuth 2.0 (Authorization Code flow), tokens and refresh, pagination, rate limits |
| **B. Data export** | Nothing: Spotify account → Privacy → *Download your data* (arrives in days) | Parsing a large export, the same matching problem without OAuth |

Both end in the same place: **for each Spotify track, find the song in your sources and like it.**

**Build (path A)**

| # | Piece | Who | Done when |
|---|---|---|---|
| A1 | Create the app at developer.spotify.com, redirect URI `http://127.0.0.1:8000/spotify/callback`. Client ID and secret go in `backend/.env`, which is **gitignored** (the repo is public) | You (your login) | `.env` exists, `git status` does not show it |
| A2 | `GET /spotify/login`: redirect to Spotify's authorize page with scopes `user-library-read playlist-read-private` and a random `state` | You | The browser shows Spotify's "Allow access?" page |
| A3 | `GET /spotify/callback`: check `state`, exchange the `code` for tokens, store them (a small table) | You | Tokens in the database |
| A4 | Refresh: access tokens last one hour; use the refresh token when one expires | You | A call after an hour still works |
| A5 | Page through `GET /me/tracks` (50 per page, follow `next`) | You | Count equals your liked-songs count |
| A6 | **Match each track** (the real problem): search your sources with "title artist", run `group_listings`, keep the song whose best listing passes `same_recording` against the Spotify track, then `resolve_song` + `like` | **You**, the core | Most of your likes land in the library |
| A7 | Throttle: at most 4 searches at a time (`asyncio.Semaphore`), so 500 tracks do not get you rate-limited by JioSaavn or YouTube | You | No 429 errors in the log |
| A8 | `GET /spotify/import/status`: done, matched, unmatched (with the list) | Claude | The app can show progress |

**Acceptance checks**
- [ ] Login → callback → tokens stored; a wrong `state` is refused.
- [ ] At least 90% of your liked songs end up in your library; the misses are listed, not silently dropped.
- [ ] Running the import twice does not duplicate anything (`resolve_song` should make this free).
- [ ] `git log -p | grep -i secret` finds nothing: the secret never entered the repo.

**Docs:** [Spotify: Authorization Code flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow) · [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) · [Get User's Saved Tracks](https://developer.spotify.com/documentation/web-api/reference/get-users-saved-tracks) · [Get Playlist Items](https://developer.spotify.com/documentation/web-api/reference/get-playlists-tracks) · [OAuth 2.0 in plain words (oauth.com)](https://www.oauth.com/oauth2-servers/server-side-apps/authorization-code/) · [`asyncio.Semaphore`](https://docs.python.org/3/library/asyncio-sync.html#asyncio.Semaphore) · [pydantic-settings for `.env`](https://docs.pydantic.dev/latest/concepts/pydantic_settings/)

**Path B instead:** B1 request the export (you); B2 `POST /spotify/import` that accepts the export's library JSON; then A6–A8 unchanged.

---

## MUS-6 · Search your library

**Why:** in your own library, *your* typos and fuzzy memory are the problem ("weekend", "kesaria", "that sad arijit one"). This is where phonetic and semantic matching earn their place (JioSaavn built Indi-Editex for exactly this).

**Build:** two searches over your library, merged:
- **Spelling-tolerant:** PostgreSQL trigrams (`pg_trgm`) plus phonetic codes for artist names.
- **By meaning:** embeddings stored with `pgvector`. Pick a **multilingual** model: `nomic-embed-text` scored the same song in Devanagari at 0.66, below a different song (0.69), on 2 Oct 2026.
- Merge the two ranked lists with **Reciprocal Rank Fusion** (hybrid search).

**Acceptance checks**
- [ ] "weekend" finds The Weeknd's songs in your library.
- [ ] "kesaria" finds *Kesariya*.
- [ ] A description ("sad arijit") finds a sad Arijit song you liked, with no title words in the query.
- [ ] A Devanagari query finds the Roman-script song (or you document why your model cannot).

**Docs:** [`pg_trgm`](https://www.postgresql.org/docs/current/pgtrgm.html) · [pgvector](https://github.com/pgvector/pgvector) · [pgvector-python hybrid search with RRF](https://github.com/pgvector/pgvector-python/blob/master/examples/hybrid_search/rrf.py)

---

## MUS-7 · Search caching

A server cache for search results (minutes, not hours). Measure first: time the same search twice, before and after. Caching also protects you from being rate-limited by YouTube and JioSaavn. (Audio-URL caching is MUS-1.)

---

## MUS-8 · Your phone

Two parts. **The app:** a phone version of the Mac app (new platform: Pair). **The reach:** YouTube audio URLs only work from the IP that requested them, so redirect mode fails once the phone is on mobile data. Build **proxy mode** for `/play` (with HTTP Range requests so seeking still works), put your Mac and phone on one private network with Tailscale, and keep the server running when the Mac app is closed (a launchd service instead of the app starting it).

---

## MUS-9 · Audio embeddings

A background job computes a "sounds like" vector for every song you play (a CLAP-style model, run locally) and stores it in pgvector. Works for any song, no crowd needed.

---

## MUS-10 · Discovery (explore / exploit)

A bandit (start with Thompson sampling) decides when to slip in a song that is new to you, chosen from songs that sound like ones you finish, and learns from whether you skip it. Reference: Spotify's BaRT (2018).

---

## MUS-11 · Your own collaborative filtering

Train ALS (`implicit`) on ListenBrainz's open listening data (~1 billion listens, CC0), map its MusicBrainz IDs to your songs, and A/B it against YouTube radio in autoplay using your skip rate. Expect thin coverage of Indian music in ListenBrainz (unverified): measure it first.

---

## MUS-12 · Lyrics, synced when possible

**Problem:** Now Playing shows no words. You want the lyrics, and when timings exist, the current line lit up as it is sung.

**Facts already checked (5 Oct 2026)**
- **LRCLIB** (`lrclib.net`), an open lyrics database used by music players: no key, no sign-up. `GET /api/get?track_name=…&artist_name=…&duration=…` answered in 198–529 ms. *Blinding Lights*: 40 synced lines; *Tum Hi Ho*: 46 synced lines; *Fake_0pps* (KANKAN): found, plain text only. Its durations matched yours within 1 s.
- Synced lyrics are **LRC**: one line per lyric, each starting with its time, `[mm:ss.xx] text`. Plain lyrics are just text.
- *Tum Hi Ho* is found under **Arijit Singh**; your library stores **Mithoon** first. Asking with the first artist only would miss it.
- **JioSaavn** has lyrics for some songs: `more_info.has_lyrics` in song details, then `__call=lyrics.getLyrics&lyrics_id=<the song id>` (its own `lyrics_id` field was empty). Plain text with `<br>` line breaks, no timings, plus a `lyrics_copyright` field.
- Musixmatch (synced only on paid plans; the free API returns about 30% of a song's lyrics) and Genius (its API gives metadata and a page link, not the text): second-hand, from their published plans. Not used.
- The repo is public: never save real lyrics into `samples/` or tests (they are copyrighted). Tests use short made-up LRC.

**Deliverables**
1. An endpoint the app calls for a song's lyrics: synced lines (each with its time), or plain text, or "none".
2. The order: LRCLIB synced → LRCLIB plain → JioSaavn plain → none.
3. Matching that survives your data: try each of the song's artists, use the duration, fall back to LRCLIB's `/api/search`.
4. Lyrics do not change: cache them, so a song's lyrics are fetched once.
5. The app (Claude): Now Playing shows the lyrics, the current line bright and larger, the rest dimmed, scrolling smoothly with the song; click a line to jump there. Plain lyrics just scroll.

**Decisions that are yours**
- Where LRC becomes lines (server or app), and the reply's shape.
- How close a duration must be to count as the same song.
- Where the cache lives (memory, a table, both), and whether "no lyrics" is cached too.
- Whether lyrics join the prefetch window (MUS-1 step 3).

**Done when**
- [ ] *Blinding Lights*: synced lines, lit in time.
- [ ] *Tum Hi Ho*: found, although Mithoon is the first artist.
- [ ] *Fake_0pps*: plain lyrics shown.
- [ ] The second request for a song's lyrics never leaves the server.
- [ ] pytest: LRC parsing (times, blank lines, a line with two timestamps), the source order, matching (fake HTTP; no network, no real lyrics).

**Docs:** LRCLIB's API (the two endpoints above, checked live) · [LRC format](https://en.wikipedia.org/wiki/LRC_(file_format)) · your own `jiosaavn.py` for the request pattern · [`re` for the `[mm:ss.xx]` tag](https://docs.python.org/3/library/re.html) (mechanics, not judgement)

---

## MUS-13 · Plain YouTube as a source

**Problem:** some songs are on YouTube but not on YouTube Music: uploads, leaks, edits, underground releases. Search never shows them.

**Facts already checked (5 Oct 2026)**
- `ytmusic.py` searches with `SONGS_ONLY` (line 19) through the `WEB_REMIX` client: YouTube Music's catalogue of official songs only. That filter is why these songs never appear; it is working as designed.
- A YouTube video plays through the same yt-dlp path as a YouTube Music song (format 140, AAC 128 kbps): only the watch URL differs (`www.youtube.com/watch?v=` instead of `music.youtube.com`).
- Plain YouTube titles are noisy ("Artist - Song (Official Video) [HD]", "slowed + reverb"), and video durations differ from the song's (29 Sep: an official video 263 s, the song 200 s). `same_recording` will rarely merge a video with a song, so they show as separate results. For songs that are missing elsewhere, that is what you want.
- It is the same IP as YouTube Music: every YouTube search adds to the bot-check risk (blocked twice on 5 Oct). **Needs MUS-1 step 2b (back-off) first.**
- Your rule: no keyword lists for judgement. Cleaning video titles ("(Official Video)") is judgement: show the raw title, or parse it with an LLM later.

**Deliverables**
1. A third source, `youtube`: search and play, through the same interface as the other two (`search`, `get_song_url`, `is_expired`) and in `SourceName`.
2. **Off unless asked:** a switch next to the search bar ("Search YouTube"), and its default in Settings (Claude builds both).
3. With the switch off, no request goes to YouTube's search (the log shows it).
4. YouTube results rank below the music sources, or by your rule: they are noisier.

**Decisions that are yours**
- How the app asks for it: `GET /search?q=…&youtube=true`, or a list of sources.
- Plain YouTube search (the `WEB` client, a different reply shape) or YouTube Music's own *videos* filter (the same reply shape, maybe less coverage): measure which finds your missing songs.
- How YouTube results rank against the others, and whether a video may ever join a song's listings.

**Done when**
- [ ] A song that is only on YouTube is found with the switch on, and plays.
- [ ] Switch off: zero YouTube search requests in the log.
- [ ] pytest for the reply parser with a saved reply (titles only; no URLs, no IP).

**Docs:** your own `ytmusic.py` (the same InnerTube pattern) · yt-dlp's `ytsearchN:` with `extract_flat`, if you want a slower fallback

---

## Later, only if needed

- Titles that differ only in brackets (`Tum Hi Ho` vs `Tum Hi Ho (From "Aashiqui 2")`): send just those pairs to an LLM (local `gemma4:12b` parsed 43/45 real titles correctly, 2 Oct 2026, ~2.7 s per title, so background + cache only). Phonetic, semantic and their harmonic mean all failed to separate these from remixes on the same day.
- Search eval set (30 queries + expected top song) before changing catalog ranking: on 2 Oct, JioSaavn's own #1 was right for 7/7 song queries.
- Query intent (song / artist / lyrics): artist searches are where both sources are weak. Never score query-vs-title without an `intent = lyrics` exception.
- Audio fingerprinting (AcoustID) in the background after first play: certain same-recording answers.
- Offline downloads, Jam, Blend.
- Give the app to someone: freeze the server with PyInstaller inside the app; bundle PostgreSQL or move to SQLite (the big decision); Apple signing ($99/year) or "Open Anyway"; a way to update yt-dlp.
- yt-dlp JavaScript runtime (node + `yt-dlp-ejs`): same speed and formats as without, measured 5 Oct 2026. Turn it on if formats go missing. Stop hiding yt-dlp's warnings (`no_warnings: True`) so you see that day coming.
