# Tickets

How this works:

1. Pick the next ticket. Make a branch named number + name: `git switch -c 1-fast-playback`. (Old branches `mus-1` to `mus-4` exist, so the old naming would collide.)
2. Bring a short **design note** (endpoints, tables, your decisions and why), get it reviewed, then build. Run the done-when checks yourself.
3. Tell Claude "MUS-1 ready". Claude runs every check, reviews the code (what is wrong + a failing case, never the fix), and **writes the tests after you are done**.
4. When everything passes: commit, merge into `main`, demo it to yourself, move on.

> **How these tickets are written:** each one gives the problem, the facts already checked, the deliverables, and the **decisions that are yours**. It does not say which tables, files or functions to use.

Stuck for more than 30 minutes? Bring: what you tried, what you expected, what happened.

> **Renumbered 5 Oct 2026.** Done and removed: resilient search, play, merge + rank, library, shuffle, and the Mac app v1. Git history and old commit messages use the old numbers. Old → new: 16 → 1 (and 4), 15 → 2, 8 → 3, 5 → 5, 9 → 6, 10 → 7, 6 + 11 → 8, 12 → 9, 13 → 10, 14 → 11.

> **Order (decided 5 Oct, updated 7 Oct 2026, evening):** ~~MUS-2~~ ✅ → ~~MUS-1~~ ✅ → ~~MUS-12 lyrics~~ ✅ → **BUG-1 → BUG-7** (the 7 Oct audit's bugs; BUG-1 first: MUS-15 changes the same check) → **MUS-15** links that survive an IP change (small; you feel it daily) → **MUS-16** log searches and measure ranking → **MUS-17** a ranking foundation (features, weights, explanations) → **MUS-18** your taste → MUS-3 autoplay (ranked by MUS-17 + 18) → MUS-13 YouTube → MUS-20 albums in search (future scope, added 7 Oct). MUS-14 covers whenever you want a contained evening.

| Ticket | What you can show at the end | Who | Size |
|---|---|---|---|
| MUS-1 ✅ | A YouTube song starts instantly the second time, and the next song is ready before you get there | **You** (backend) · Claude (app, tests after) | M |
| MUS-2 ✅ | Playlists: make, fill, reorder (done 6 Oct; covers moved to MUS-14) | **You** (backend) · Claude (app) | L |
| MUS-3 | When the queue ends, music keeps going, shaped by your skips | **You** (ranking, endpoint) · Claude (radio parser, app) | M |
| MUS-4 | Choose JioSaavn or YouTube Music as the default copy | **You** | S |
| MUS-5 | Your Spotify liked songs and playlists appear in your library | **You** (OAuth, API) · Claude (setup) | M |
| MUS-6 | Search your library: "weekend" finds The Weeknd, "sad arijit" works | **Pair** | L |
| MUS-7 | The second identical search is much faster, with numbers | **You** | M |
| MUS-8 | Your phone: an app, playing from your Mac over mobile data | **Pair** | L |
| MUS-9 | Every played song gets a "sounds like" vector | Claude (model setup) · **You** (background job) | M |
| MUS-10 | About 1 in 5 autoplay songs is new to you, and it learns which new ones you skip | **You** | M |
| MUS-11 | Your own "people who played X played Y" model, beating or losing to YouTube radio on your skip rate | **Pair** | L |
| MUS-12 ✅ | Lyrics in Now Playing, lit line by line in time with the song | **You** (backend) · Claude (app) | M |
| MUS-13 | Songs that exist only on plain YouTube, found with a "Search YouTube" switch | **You** (backend) · Claude (app) | M |
| MUS-14 | Playlist covers: upload an image, checked and cleaned, served with a URL that changes when it does | **You** (backend) · Claude (app, tests) | S |
| MUS-15 | After your IP changes, songs still start at once: one failed play, not one per song | **You** (backend) · Claude (tests) | S |
| MUS-16 | Every search is logged with what you played from it, and one command says how good the ranking is | **You** (backend) · Claude (app sends the search id, eval script) | M |
| MUS-17 | Search ranked by named, weighted signals; each result can say why it ranks where it does; a change is judged by MUS-16's number | **You** (scorer) · Claude (app "why", tests) | L |
| MUS-18 | Your taste as numbers (songs and artists you play, finish, skip, like), used by search and autoplay | **You** · Claude (tests) | M |
| MUS-20 | Albums in search: an album opens its songs in order, and plays as one (future scope) | **You** (backend) · Claude (app) | M |
| MUS-19 ✅ | Explicit and clean versions: an 🅴 on explicit ones, and your choice of which plays (done 7 Oct) | Claude (wired in, on your go-ahead) | S |
| BUG-1…7 | The 7 Oct audit's backend bugs, each gone and each with a test (BUG-1 before MUS-15) | **You** · Claude (review, tests) | S each |

---

## MUS-1 · Fast playback: cache and prefetch ✅ (6 Oct 2026)

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
| 2 ✅ | Single-flight | Done 6 Oct: two requests at once make 1 lookup (was 2); a cancelled request leaves the lookup running for others |
| 2b ✅ | **Back off from a blocked source.** | Done 6 Oct: a bot check pauses YouTube (2 min, doubling to 60, reset by a success); during the pause /play answers 502 without asking it (3 requests → 1 call) |
| 3 ✅ | The prefetch endpoint: take the window, answer at once, fetch in the background with the rules above | Done 6 Oct: 202 in 1 ms; 4 cached in 0.5 s; a prefetched play 3.8 ms vs 1,904 ms not prefetched (YouTube) |
| 4 ✅ | The cache survives a restart (a table) | Done 5 Oct: after a restart, 5 songs from the table, 0 source calls, 0.37 ms per table hit; both levels LRU (`hit_at`); a hit costs 0.83 ms with 6,000 rows |
| App ✅ | Claude: send the window; the failure handling above; show "Couldn't play …"; delete `warm` | Done 6 Oct: the next 5 + the top 5 of a search; from the app, queue songs 2.5–5.8 ms (a YouTube one 2.6 ms) and the search's top result 5.2 ms |

**Decisions that are yours**
- The margin: anything from 10 minutes to 5 hours (a long song plus seeks; 30 minutes suggested).
- Where the cache and the "running" dict live.
- Step 2b: how long to back off, and whether it grows when blocks repeat.
- The prefetch endpoint's path, method and body.
- The table in step 4: its columns. It must also hold search-result listings, which have no `listings` row.
- What the prefetch worker does when a lookup fails.

**Done when**
- [x] Measured: first `/play` of a YouTube song 1,786 ms; second 3.7 ms (5 Oct, *Blinding Lights*).
- [x] Search, wait, click the top result: a cache hit (6 Oct: 5.2 ms from the app; 3.8 ms vs 1,904 ms through the API).
- [x] Every `serve_fresh` is logged: that log is your failure count.
- [x] Tests: `tests/test_cache.py` (steps 1, 2, 2b) and `tests/test_prefetch.py` (step 3): 107 pass.

**Docs**
- Step 1: [`urllib.parse.urlparse`](https://docs.python.org/3/library/urllib.parse.html#urllib.parse.urlparse) and [`parse_qs`](https://docs.python.org/3/library/urllib.parse.html#urllib.parse.parse_qs) (read `expire=`) · [`time.time`](https://docs.python.org/3/library/time.html#time.time) · FastAPI [Query Parameters](https://fastapi.tiangolo.com/tutorial/query-params/) (see "Query parameter type conversion" for a `bool`)
- Step 2: asyncio [Creating Tasks](https://docs.python.org/3/library/asyncio-task.html#creating-tasks) (read the "Important" note about keeping a reference) · [Shielding From Cancellation](https://docs.python.org/3/library/asyncio-task.html#shielding-from-cancellation) · the idea, named: Go's [`singleflight`](https://pkg.go.dev/golang.org/x/sync/singleflight) (one paragraph; the problem it prevents is a "cache stampede")
- Step 3: FastAPI [Request Body](https://fastapi.tiangolo.com/tutorial/body/) · [`asyncio.Semaphore`](https://docs.python.org/3/library/asyncio-sync.html#asyncio.Semaphore) · [`asyncio.Queue`](https://docs.python.org/3/library/asyncio-queue.html) · [`Task.cancel`](https://docs.python.org/3/library/asyncio-task.html#asyncio.Task.cancel) · HTTP [202 Accepted](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/202) ("I took it, the work happens later")
- Step 4: PostgreSQL [`INSERT … ON CONFLICT DO UPDATE`](https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT) ("upsert")

---

## MUS-2 · Playlists ✅ (steps 1–4, 6 Oct 2026; step 5 is now MUS-14)

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

### Step 5 · Cover image → moved to MUS-14 (below)

- `GET` / `POST` / `DELETE /playlists/{playlist_id}/thumbnail`. `thumbnail` in `PlaylistMetadata` becomes that URL. `null` means no cover: the app draws a 2×2 grid of the first four songs.
- Safety: open the upload with Pillow and save it again as JPEG (this rejects non-images and removes EXIF/GPS). Reject files over 5 MB. Never use the uploaded filename.
- The app caches images by URL. Change the URL when the cover changes: `…/thumbnail?v=<upload time>`.

**Done when:** a text file renamed `.jpg` is rejected; a phone photo comes back without EXIF; a new cover has a new URL.

### After each step

Claude writes the pytest tests (against `music_test`). The app work (sidebar, playlist screen, "Add to playlist", drag to reorder) starts after step 2, when you say.

**Docs:** [fractional-indexing](https://github.com/httpie/fractional-indexing-python) · FastAPI [path parameters](https://fastapi.tiangolo.com/tutorial/path-params/) · FastAPI [Request Files](https://fastapi.tiangolo.com/tutorial/request-files/) · [Pillow](https://pillow.readthedocs.io/en/stable/reference/Image.html)

---

## MUS-14 · Playlist covers

**Problem:** a playlist's cover is its first four songs' covers in a 2×2 grid (or a coloured gradient when empty). You want to choose your own image.

**Deliverables**
- `POST /playlists/{playlist_id}/thumbnail` (upload), `GET` (serve), `DELETE` (back to the grid).
- `thumbnail` in `PlaylistMetadata`: the cover's URL, or `null` for no cover.
- The app (Claude): "Choose Image…" in the playlist's ⋯ menu and dropping an image on the cover.

**Facts already decided**
- Open the upload with Pillow and save it again as JPEG: this rejects files that are not images and removes EXIF/GPS. Reject files over 5 MB. Never use the uploaded filename.
- The app caches images by URL: the URL must change when the cover changes (`…/thumbnail?v=<upload time>`).
- New packages: `python-multipart` (FastAPI cannot read uploads without it) and `Pillow`.

**Decisions that are yours**
- Where the images live: a folder on disk (path in `playlists.image`, the column exists; the folder must be git-ignored, the repo is public) or the bytes in the database.
- How big the stored image is (the app shows covers at up to ~640 pt).

**Done when:** a text file renamed `.jpg` is rejected; a phone photo comes back without EXIF; a new cover has a new URL; deleting it brings the grid back. Claude writes the tests.

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
| 7 | Up Next by hand: drag to reorder, remove, clear | ✅ 6 Oct: 27 queue rules pass; the real list shows one row per queued song |
| 8 | Offline: Download / Remove Download, Download Playlist, a Downloads screen; downloads play with the server off | ✅ 6 Oct (`NN_SELFTEST_DOWNLOADS`). Limit: YouTube downloads are throttled (159 s for one song) |
| — | Extra: recent searches on the idle Search screen (only searches that led to a song you played; the duplicate Recently Played shelf left Search, Home has it). CPU checked: 0% idle, ~2.5% playing | ✅ 6 Oct |
| — | From the MUS-2 list: the playlist's name in the Discord status (Settings › Discord › Share, off by default) and "From “Gym”" in Now Playing; Settings in collapsible sections (Colours on its own, so the page fits a MacBook screen) | ✅ 6 Oct |
| — | Fixed 6 Oct: a test server could outlive its app and keep the port (now: one launcher, one start at a time, the whole process family stopped); the server log overwrote itself (now append mode) | ✅ |
| — | Fixed 6 Oct: "That JioSaavn copy is gone. Playing another JioSaavn copy." (was a contradiction); self-test windows say "Self-test · test library" | ✅ |
| — | 7 Oct, from your notes: "No internet" and "Server not connected" banners (Try Again); the player stops after 3 songs in a row fail instead of cycling | ✅ `NN_SELFTEST_CONNECTION` (offline itself cannot be faked in a test) |
| — | 7 Oct: CPU. The playing song's animated speaker took 22.7% of a core in lists (your 25–31%): now Core Animation bars, 2.6% (the same as none); covers decoded once and at the size shown (list covers 4.3× fewer pixels); Now Playing 27% → 3% | ✅ `NN_SELFTEST_PERF`, `NN_SELFTEST_COVERS` |
| — | 7 Oct: every plain button clicks anywhere on it and 6 pt around (it was only the drawn strokes); Button feedback (hover highlight, press) in Settings › Appearance | ✅ built; a real click cannot be tested while you use another app |
| — | 7 Oct: Up Next: double-click plays, drag moves (a single-click tap took the mouse-down, so drags never started); lyrics fade instead of snapping | ✅ built; the drag itself needs your hands |
| — | 7 Oct: search prepares only its top result, 1 s after you stop typing (Settings › Footprint: none / top / top 5) | ✅ `NN_SELFTEST_PREFETCH`: top result 5.3 ms |
| — | 7 Oct: safety. Your saved server address had become the test one (8765): a test could use your app's server. Tests now run only on a server they started; the scripts refuse a busy port; the address field saves on Return only | ✅ |
| — | 7 Oct evening, audit: CPU. Release build, a song playing: Home 0.0–0.9%, Now Playing 0.6–0.9%, **Lyrics 1.0% (was 30–40%)**. The lyrics, the progress line, the equaliser bars, a new song's cover and background crossfades are Core Animation (frame-rate caps tried and removed: the likely reason scrolling lost its smoothness); nothing moves under Now Playing; Now Playing is built once and kept; a song start refreshes only Recent; unchanged data redraws nothing; Footprint no longer measures itself (it said 1.8% for 0.9%) | ✅ measured by you with `top` |
| — | 7 Oct evening, audit: bugs. The clean copy played the explicit one; play after "Stopped" did nothing; ⏭⏭ left song 2's cover and colours on song 3; lyrics followed the previous song's times; a broken download fell back to itself; a playlist spun forever with the server down; `/health` accepted any answer; the Release build did not compile (SelfTest); four files were never committed | ✅ built; not covered by a self-test yet |
| — | 7 Oct evening: Now Playing hides the toolbar (the sidebar button showed over it); Home's shelves neither snap nor bounce and are made once; a hover redraws only the row or tile under the pointer | ✅ |
| — | 7 Oct: Now Playing's Up Next and Lyrics are both kept, behind one glass; switching fades between them (the new panel was built during the animation, and two glass panels crossfaded: the switch dropped frames) | ✅ built |
| — | 7 Oct night, the robustness audit (every claim traced to its code): a song ends at its listed length (some YouTube audio ran on in silence and the queue never moved on); Up Next can be dragged again (hidden Lyrics sat on top of it); Play Next songs survive their playlist being opened or edited; "From “Gym”" survives a drag; messages and the connection banner show over Now Playing; ⌘F works from any screen; ⌘-arrows move the cursor while typing; Controls greyed out with nothing playing; no swipe-skips under Now Playing | ✅ built; `NN_SELFTEST_QUEUE` +4 rules |
| — | **Next, from the audit (not built):** Add to Queue (the end of Up Next; today only Play Next exists, and starting a list drops queued songs); Download in Home's Liked Songs menu; Up Next reorder haptic; Now Playing's volume ticks; a server address change refreshes the library; a server down at launch says so instead of "No liked songs yet" | ask first |
| — | **Open:** scrolling felt less fluid after the frame-rate caps (the app nearly idle, not transparency): caps removed, to confirm. Rare: like then unlike at once on a search result can stay liked; a slow playlist load can undo a drag made just before it lands; Settings › Server › Restart can freeze the window up to 2 s | later |

---

## MUS-19 · Explicit and clean versions ✅ (7 Oct 2026)

**Problem:** for *Les*, the clean version was listed and played: a song's explicit and clean copies are grouped as one song (rightly), and `pick_best` chose by source and popularity, blind to which was explicit.

**Facts (checked 7 Oct):** JioSaavn gives `explicit_content` "1"/"0" on every search result and in `song.getDetails` (many ids per call); YouTube Music marks explicit rows with a `MUSIC_EXPLICIT_BADGE` badge (`badges[…].musicInlineBadgeRenderer.icon.iconType`), and no badge means clean. *Les*: 2 explicit and 2 clean copies; the server's pick was clean.

**Done:** `Listing.explicit` (None = unknown) parsed by both sources; the `listings.explicit` column (added by `schema.sql`; an unknown flag is filled in when the listing is seen again, a known one never overwritten); the app plays your version (Settings › Playback: explicit by default, or clean), shows 🅴 beside explicit titles and in a song's versions. Your library's 111 listings were filled in by `scripts/backfill_explicit.py` (nothing deleted): JioSaavn 27 explicit / 37 clean, YouTube 24 / 23, none unknown. Tests: 3 backend, `NN_SELFTEST_EXPLICIT`.

---

## BUG · The 7 Oct audit's bugs (yours: the backend)

Found by reading the code and, where it says *reproduced*, by running it with fake replies (no network). Each one: what goes wrong, how to see it, what done looks like. Where the fix goes is yours to find: reproduce it first, then follow it through the code. Bring "BUG-n ready" and Claude reviews it and writes the test.

### BUG-1 · A YouTube link without `?expire=` breaks `/play` for that song, for good ✅ (7 Oct)
**Done (your decision):** `is_expired` no longer crashes; a link whose expiry it cannot read counts as fresh (its docstring says so): YouTube links carry `?expire=`, and if one ever does not, the app's `serve_fresh` recovers after one failed try. Tests: 5 in `tests/test_sources.py` (two of them fail on the old code with the original `AttributeError`). Considered and left: reading `/expire/…/` in the path too, a warning log line.

**What goes wrong:** the cache reads a YouTube link's expiry from its `expire=` query parameter. yt-dlp can also return links that carry it in the path (`…/expire/1759999999/…`). Such a link is stored; every later `/play` of that song then answers **500**, even after a restart (the link is in the table). `serve_fresh` works once, and stores the same kind of link again.
**Reproduced (7 Oct):** play → 200; play again → 500 (`AttributeError`); `serve_fresh` → 200; play again → 500.
**Done when:** a link whose expiry cannot be read is never a crash and never served as fresh; a test with a path-style link shows it; nothing logs a URL or an IP.
**Yours to decide:** read the expiry from the path too, or treat "can't tell" as stale (and what that costs).
**Docs:** [`re.search`](https://docs.python.org/3/library/re.html#re.search) (what it returns when nothing matches) · [`urllib.parse`](https://docs.python.org/3/library/urllib.parse.html)

### BUG-2 · One bot check can pause YouTube for 16 minutes instead of 2 ✅ (7 Oct)
**Done (your fix and decision):** one strike per blocking *episode*: a bot check that arrives while a pause is already running is the same episode (no strike, the pause does not grow), and a success that arrives during a pause no longer resets the strikes (it began before the block). One `_is_paused(source)` check, shared by `_refuse_if_paused` and `_strike`. Tests: 2 in `tests/test_cache.py` (`InFlightSource` answers lookups in the order the test picks); each fails on the old code, one per half. 171 passed. Left as is: `time.time`, not `time.monotonic` (the refusal shows the clock time the pause ends; a clock change can only shorten or lengthen one pause). A lookup that began before the block and is blocked after its pause ends counts as a new episode: rare (a lookup takes seconds, a pause minutes).

**What goes wrong:** the back-off adds a strike per failed answer, not per blocking episode. Four prefetch lookups in flight when YouTube starts blocking all fail: four strikes, so the first pause is 2 × 2³ = **16 min**. The other way round: a lookup that began before the block and succeeds after it resets the strikes to 0 in the middle of a pause.
**Reproduced (7 Oct):** four lookups at once, all blocked → paused 16 min.
**Done when:** tests: four lookups blocked at once → the first pause (2 min); a success that began before the block leaves the pause alone.
**Yours to decide:** what counts as one episode.
**Docs:** [`time.monotonic`](https://docs.python.org/3/library/time.html#time.monotonic) (and why it suits pauses better than `time.time`)

### BUG-3 · JioSaavn's bad days answer 500
**What goes wrong:** when JioSaavn answers with an HTML error page, with `{"songs": []}`, with a song that has no media URL, or with a JSON error on a 429/5xx, `/play` answers **500** (or 404 "Song not found" during an outage). The app then says "didn't load" instead of "JioSaavn is unavailable right now".
**Reproduced (7 Oct):** an HTML body → `JSONDecodeError` → 500; `{"songs": []}` → `IndexError` → 500.
**Done when:** every way JioSaavn can fail ends in one of the sources' own errors, so `/play` answers 404 or 502, never 500; a test per case, with fake replies.
**Yours to decide:** which failures mean "this song is gone" and which "JioSaavn is unavailable".

### BUG-4 · One odd JioSaavn row loses the whole JioSaavn half of a search
**What goes wrong:** one result with, say, `"duration": ""` fails validation, and the whole JioSaavn search reports unhealthy with 0 results. YouTube Music already skips one bad row and keeps the other 19. *(Read in the code, not run.)*
**Done when:** a saved reply with one broken row gives all the others, and JioSaavn stays healthy; the skipped row is one log line.

### BUG-5 · An overloaded LRCLIB is remembered as "no lyrics" for 7 days
**What goes wrong:** LRCLIB answers 503 when it is overloaded, even for songs it has (MUS-12's own trap). For a song with no YouTube copy, that 503 counts as "every source answered, nothing found", and the empty reply is stored for 7 days. *(Read in the code, not run.)*
**Done when:** a test: LRCLIB 503 and no YouTube id → an empty reply, nothing stored, and the next request asks again.

### BUG-6 · Two songs at the same position cannot be moved between
**What goes wrong:** two adds at the same moment can get the same position (the code knows: it sorts ties by time). Dragging a song between those two asks for a key between two equal keys, which raises, so the move answers **422**, for good. Playlists can tie the same way, and the list of playlists has no tie-break, so two tied playlists can swap places between loads. *(Read in the code, not run.)*
**Done when:** a test: two items at one position, a third moved between them → 204, and the order is what you asked for; the playlist list always comes back in the same order.
**Yours to decide:** make ties impossible, or repair them when you meet one.

### BUG-7 · `/recent?limit=-1` answers 500
**What goes wrong:** a negative limit reaches PostgreSQL ("LIMIT must not be negative"). *(Read in the code.)*
**Done when:** a negative (or absurd) limit is a 422 before any SQL runs.
**Docs:** FastAPI [Query parameters and validation](https://fastapi.tiangolo.com/tutorial/query-params-str-validations/) (numbers: `ge`, `le`)

### STRIP · A lighter server ✅ (7 Oct, Claude, on your request; your review)
**Done:** FastAPI without its Cloud tools (six packages gone from `uv.lock`, 96 → 89 MB measured); `GET /` removed; one `single_flight` for both caches; a table hit is one `UPDATE … RETURNING`; the prefetch worker's check marks nothing (`_has_fresh`, with a test that fails on the old check); `tests/conftest.py` holds `anyio_backend` and the plain `pool` (two files keep their own `pool` on purpose: they clean differently). 164 passed. **Left for you:** the unused `jiosaavn_cache_expiry_threshold` setting (`settings.py` refuses any `.env` key it does not know, so the field, `.env.example` and your own `backend/.env` must lose it in the same step, or the server will not start).

From the same audit. The server idles at ~0.2% of a core (uvicorn's own 10-a-second tick; only another server would remove it), so this is about memory and less code:
- `fastapi[standard]` loads FastAPI Cloud's tools (Sentry among them) on every start: `fastapi[standard-no-fastapi-cloud-cli]` measured 96 → 89 MB, with no change to how the app starts the server.
- Unused: the `jiosaavn_cache_expiry_threshold` setting (and its line in `.env.example`), `GET /`.
- Written twice: single-flight in the URL cache and in the lyrics cache.
- A cache hit in the table is two statements; one `UPDATE … RETURNING` does both.
- The prefetch worker asks "is it cached?" in a way that also marks the row as used, so "least recently used" means "least recently prefetched".
- The tests define the same database fixtures in 4–7 files: one `tests/conftest.py`.

---

## MUS-15 · Links that survive an IP change

**Problem:** songs often take seconds to start, even cached ones. Measured 7 Oct in your library: 24 cached YouTube links were made for **5 different IP addresses**; 14 were valid by time, but only 7 for your current IP. YouTube ties each link to the IP that fetched it, and the cache checks only `expire=`, so it hands out links for an old IP: they fail, the app asks `serve_fresh`, and the song starts after a failed try plus a fresh lookup (~2 s). Your log has 65 such retries.

**Facts:** every fresh YouTube link carries the IP it was made for (its `ip=` parameter). Never print or log it (the repo is public; it is your address).

**Deliverables:** the cache knows the IP of the newest fresh link; a YouTube link made for another IP counts as stale (the same path as expired). After an IP change, the first play fails once, its fresh lookup reveals the new IP, and every other link for the old one is refetched by the next lookup or prefetch instead of failing on play.

**Done when:** a test with fake links for two IPs: after one fresh link with the new IP, a cached link for the old one is not served; nothing logs an IP.

**Yours to decide:** where the "current IP" lives (memory only, or the table, so a restart knows it); whether a server start should make one fresh lookup to learn the IP before the first play.

---

## MUS-16 · Log searches; measure the ranking

**Problem:** search ranking cannot be improved by eye. Checked 7 Oct on 6 real queries: today's RRF puts *The Kill (Bury Me)* (13 duplicate copies) above "The kill", the #1 of both sources; "one vote per source" fixes that query and breaks *Blinding Lights* (an unrelated *Starboy* climbs to #3). Every change helps some queries and hurts others: you need a number.

**Deliverables:**
- A log of each search: the query, both sources' raw result lists (so the ranking can be recomputed offline with any formula), what was shown, and **which result you played** and at which position. The app already knows which search led to a play (it keeps "recent searches" that way): it sends the search's id with the play event.
- An offline evaluation: replay every logged search through a ranking function and report **hit@1** (the song you played was ranked first) and **MRR** (mean reciprocal rank of the played song). Today's RRF is the baseline.

**Done when:** after a week of normal use, one command prints the baseline's hit@1 and MRR over your real searches.

**Yours to decide:** the tables; how long to keep logs; whether a search with no play counts (a failed search) and how.

---

## MUS-17 · A ranking foundation

**Problem:** the ranking uses only positions and copy counts (RRF). It never looks at how well a result matches what you typed, or at you. You want a foundation you can adjust and build recommendations on.

**Deliverables:**
- **Features** per result, each a named number: best position in each source; sources that found it; copies; title and artist match against the query (rapidfuzz: mechanics, allowed); popularity as a percentile within its source; and, from MUS-18, your plays, finishes, skips and likes of this song and artist.
- A **scorer**: a weighted sum, weights in one config, so a change is one number edited and re-measured with MUS-16.
- **Explanations**: the API can return each result's feature values and contributions; the app can show "why" (Claude).
- Grouping fixed where MUS-16's data shows it splits one recording into several songs (the *The Kill* case).

**Rule (yours, 5 Oct):** no keyword lists for judgement ("remix", "lofi", "slowed" as a classifier). If variants need detecting, use measured signals (duration far from the group's median, the query's own words) or a model call with a schema.

**Done when:** MUS-16's hit@1 and MRR beat the RRF baseline on your logged searches, and every top result can say why.

**Yours to decide:** the first features and weights; whether RRF stays as one feature; when (if ever) to learn the weights from the logs (logistic regression on played/not played is the usual first step).

---

## MUS-18 · Your taste, as numbers

**Problem:** search and (soon) autoplay know nothing about you. The events table already records every play, skip (with the second it happened) and finish, and likes are stored.

**Deliverables:** per song and per artist: plays, finishes, early skips (yours to define), likes, last played, combined into an affinity that fades with time; exposed to MUS-17 as features. Recomputed cheaply (on each event, or in a small batch).

**Done when:** a song you finish often outranks an otherwise equal one in search, and a song you always skip early falls; tests with made-up events show both.

**Yours to decide:** the decay (a half-life in days); how much a like weighs against plays; whether skips in the first seconds mean "wrong song" or "not now".

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

## MUS-12 · Lyrics, lit line by line

**Status (6 Oct):** steps 1 and 2 done (`POST /lyrics`, `lyrics.py`: a `LYRICS_SOURCES` loop, your design: timed from any source wins, else the first plain, else empty). 34 tests, offline, plus 11 for the cache on music_test. Measured: *Les* from LRCLIB, timed, 115 lines, 0.6 s; LRCLIB missing, YouTube timed, 2.0 s. *Corrlinks and JPay* turned out to be on LRCLIB after all (the earlier "not found" was most likely a 503), so it no longer tests step 2. Step 3 done too: `LyricsCache` and the `lyrics` table (timed kept for good; plain or empty asked again after 7 days; nothing kept when a source failed). Measured: 704 ms not stored, 3–4 ms stored. **App done too (7 Oct):** the Lyrics panel (lit line kept in the middle, click to seek, "Couldn't find lyrics"), Settings › Lyrics (when a song starts, and the next song's; or only when Lyrics opens), downloads keep their lyrics for offline. 15 self-test checks pass. With a still background, Now Playing with Lyrics takes ~4% of one core.

**Problem:** Now Playing shows no words. You want the lyrics, and when they are timed, the line being sung lit up.

**Decided (6 Oct 2026)**
- **LRCLIB first, then YouTube Music.** Measured on your 12 liked songs: LRCLIB timed 8, YouTube Music timed 8, both together **10 of the 11 that have words** (the 12th is instrumental, and LRCLIB says so).
- **The server answers parsed lines**, the same shape whichever source found them; the app only highlights. An app never parses LRC.
- **Lyrics are copyrighted:** fine to show in your player, **never committed** (not in tests, not in fixtures, not in docs).

**The reply** (your decisions, 6 Oct: no `instrumental`, always 200, its own endpoint, fetched on demand; not part of `/play`, not prefetched by the server). The field names are yours; the app needs these four things:
```json
{"source": "lrclib", "synced": true,
 "lines": [{"start_ms": 19120, "text": "…"}, {"start_ms": 20760, "text": "…"}]}
```
- Which source found them (`"lrclib"`, `"ytmusic"`), or nothing when none did.
- `synced: false`: plain lyrics, every `start_ms` is `null`.
- Nothing found, or an instrumental: `lines` is `[]`, still a 200 (the app says "Couldn't find lyrics").
- No `end_ms`: a line ends where the next begins.

**The request** (method and names yours; you have `POST /lyrics` with a JSON body now). Whatever its shape, it must carry:
- the title, **the artist** (LRCLIB answers 400 without one) and the duration in seconds;
- a **YouTube video id** whenever the song has a `ytmusic` listing, even when the copy playing is JioSaavn's (YouTube Music lyrics need it).
- If it becomes a GET: a GET carries no body, so the fields come in the URL (`Annotated[Model, Query()]`, checked on a toy endpoint: 200; the same model as a body: 422).

**HTTP:** use a `SharedClient` for LRCLIB (`http_client.py`; headers go in its options), like the sources. The lifespan closes the sources' clients at shutdown; yours needs closing there too.

**Source 1: LRCLIB** (`https://lrclib.net`, open source, MIT, no key)
- `GET /api/get?track_name=…&artist_name=…&duration=…` (seconds). Send a `User-Agent` naming the app.
- Reply fields (6 Oct): `id`, `trackName`, `artistName`, `albumName`, `duration` (float), `instrumental`, `hasWordSync`, `plainLyrics` (text), `syncedLyrics` (LRC text), `lyricsfile` (YAML, already split into lines with `start_ms`/`end_ms`; newer and not in the docs: prefer `syncedLyrics`).
- Duration: the docs say ±2 s. Measured: asked 317, stored 319.0, and 318–322 all matched.
- **Trap:** a miss comes back as **404** `{"name": "TrackNotFound"}` one time and **503** `{"name": "ServerOverloaded"}` the next, for the same kind of request (measured twice, 6 Oct). Treat both as "LRCLIB has nothing", try YouTube, and never remember a 503 as "no lyrics".
- `artist_name` is required: without it, **400 in plain text** (not JSON). `duration` is optional; 19 s off already misses.
- An instrumental: 200, `instrumental: true`, `plainLyrics` and `syncedLyrics` both `None`.
- Answers in about 0.6–0.8 s.

**Source 2: YouTube Music** (package `ytmusicapi`, not installed yet: `uv add ytmusicapi`)
- `YTMusic().get_watch_playlist(videoId=…)["lyrics"]` → a browseId (`"MPLY…"`, 19 characters), or `None`: no lyrics. 1.3 s.
- `get_lyrics(browseId, timestamps=True)` → `{"hasTimestamps": bool, "lyrics": …, "source": "Source: LyricFind"}`. Timed: `lyrics` is a list of `LyricLine`, a dataclass (`.text`, `.start_time` and `.end_time` in **ms**, `.id`). Not timed: one string. 0.25 s. (ytmusicapi 1.12.3, measured 6 Oct.)
- **Both are blocking** (`requests`, not async): call them through `asyncio.to_thread`, or the whole server stops for ~1.6 s.
- **Trap:** line 0 can be an intro marker: one character, no letters, from 0 ms to the first sung line (seen on *Les*). LRCLIB has no such line.
- **Trap:** some songs raise `KeyError: 'cueRange'` on gap lines (ytmusicapi issue #1002): catch it and fall back to `timestamps=False`.
- Needs a YouTube listing's video id: a JioSaavn-only song can only use LRCLIB.

**LRC, the timed format** (`syncedLyrics`)
- A line: `[mm:ss.xx] text`. Stamps: `re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", line)`; text: the line with the stamps removed.
- `start_ms = round((minutes * 60 + seconds) * 1000)`: `[01:02.345]` → 62345.
- Traps: one line can carry **two stamps** (a chorus sung twice: two lines); tag lines like `[ar: …]` have no stamp (skip); a stamp with no text is a gap (keep it, as `""`, so the previous line stops lighting up); sort by `start_ms` at the end.

**Steps**

| Step | Build | Done when |
|---|---|---|
| 1 | LRCLIB: look up, parse `syncedLyrics` into lines (or plain), the endpoint answers | *Les*: `synced: true`, 115 lines, in order; an instrumental (*Clair de Lune*): `lines: []`, 200; LRCLIB down or overloaded: still a 200 |
| 2 | YouTube Music when LRCLIB has nothing timed | *Corrlinks and JPay* (LRCLIB: not found) answers timed lines from YouTube; a JioSaavn-only song skips YouTube; the server keeps answering other requests while YouTube is asked (`to_thread`) |
| 3 | Cache: lyrics do not change, so a second request costs nothing | The second request for a song makes no outside call; a 503 from LRCLIB is not cached as "no lyrics" |
| Tests | Claude, after each step | Offline: fake LRCLIB and YouTube answers, no real lyrics in any file |
| App | Claude, after step 1: the Lyrics panel lights the line being sung, keeps it in the middle, click a line to seek, "Couldn't find lyrics"; a setting for when to fetch (when a song starts, plus the next song's; or only when Lyrics is open); downloads keep their lyrics | After step 1 |

**Decisions that are yours**
- The endpoint's method and names (see The request).
- Cleaning titles before LRCLIB: *Tum Hi Ho (From "Aashiqui 2")*, "feat. …". `normalise` in `matching.py` already does some of this.
- What "found" means when LRCLIB has only plain lyrics: stop there, or still ask YouTube Music for timed ones (YouTube timed beats LRCLIB plain).
- The cache: where, and keyed by what.

**Docs:** [LRCLIB API](https://lrclib.net/docs) · [ytmusicapi get_lyrics](https://ytmusicapi.readthedocs.io/en/latest/reference/browsing.html) · [ytmusicapi issue #1002](https://github.com/sigma67/ytmusicapi/issues/1002) · [LRC format](https://en.wikipedia.org/wiki/LRC_(file_format)) · Python [`re.findall`](https://docs.python.org/3/library/re.html#re.findall)

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

## MUS-20 · Albums in search (future scope: after the order above)

**Problem:** search finds songs only. Typing an album's name gives its songs mixed in with everything else; there is no way to open an album, see its songs in order, and play it as one.

**Facts to check first (not checked yet):**
- Whether each source can search albums, and what the reply looks like: save one reply per source in `samples/`, as for songs. YouTube Music's search takes a filter (`ytmusic.py` asks for songs only with one): there may be one for albums. JioSaavn's web API answers several kinds of search.
- How to get one album's songs, in order, from each source.
- Whether one album on both sources can be recognised as the same (title, artist, number of songs?), the way `same_recording` does it for songs.

**Deliverables:**
1. Search answers albums too, as their own list (not mixed into songs): cover, artist, year, number of songs.
2. One album's songs, in order, as songs the app can play (with their listings, like search results).
3. The app (Claude): an Albums row in search results; an album screen (cover, songs, Play, Shuffle, Add to Playlist).

**Yours to decide:** albums in the `/search` reply or a request of their own; how many per search; stored (like playlists) or only looked up; what to do when the two sources list different songs for one album.

**Done when:** searching "Camp Childish Gambino" shows the album; opening it lists its songs in order; Play plays them in that order.

---

## Later, only if needed

- Titles that differ only in brackets (`Tum Hi Ho` vs `Tum Hi Ho (From "Aashiqui 2")`): send just those pairs to an LLM (local `gemma4:12b` parsed 43/45 real titles correctly, 2 Oct 2026, ~2.7 s per title, so background + cache only). Phonetic, semantic and their harmonic mean all failed to separate these from remixes on the same day.
- Search eval set (30 queries + expected top song) before changing catalog ranking: on 2 Oct, JioSaavn's own #1 was right for 7/7 song queries.
- Query intent (song / artist / lyrics): artist searches are where both sources are weak. Never score query-vs-title without an `intent = lyrics` exception.
- Audio fingerprinting (AcoustID) in the background after first play: certain same-recording answers.
- Offline downloads, Jam, Blend.
- Give the app to someone: freeze the server with PyInstaller inside the app; bundle PostgreSQL or move to SQLite (the big decision); Apple signing ($99/year) or "Open Anyway"; a way to update yt-dlp.
- yt-dlp JavaScript runtime (node + `yt-dlp-ejs`): same speed and formats as without, measured 5 Oct 2026. Turn it on if formats go missing. Stop hiding yt-dlp's warnings (`no_warnings: True`) so you see that day coming.
