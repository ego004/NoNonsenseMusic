# Backend (Python)

All files are in `backend/src/music_backend/`. Each function has four lines:

- **Does:** what it is for.
- **Returns:** what comes back.
- **How:** the steps.
- **Called by:** who uses it.

Files, in the order a request touches them:

| File | Job |
|---|---|
| [`main.py`](../backend/src/music_backend/main.py) | The server. Every endpoint. |
| [`models.py`](../backend/src/music_backend/models.py) | The shapes of data (Pydantic models). |
| [`sources/jiosaavn.py`](../backend/src/music_backend/sources/jiosaavn.py) | Talks to JioSaavn. |
| [`sources/ytmusic.py`](../backend/src/music_backend/sources/ytmusic.py) | Talks to YouTube Music. |
| [`sources/__init__.py`](../backend/src/music_backend/sources/__init__.py) | The two errors every source uses. |
| [`matching.py`](../backend/src/music_backend/matching.py) | Groups listings into songs. Ranks songs. |
| [`library.py`](../backend/src/music_backend/library.py) | Likes, events, stored songs. |
| [`cache.py`](../backend/src/music_backend/cache.py) | Remembers audio URLs (memory + the `listing_urls` table), so a replay is instant. |
| [`db.py`](../backend/src/music_backend/db.py) | The connection pool. |
| [`settings.py`](../backend/src/music_backend/settings.py) | Every setting, read once from `backend/.env`. |

---

## main.py

### Constants

| Name | Value | Meaning |
|---|---|---|
| `SOURCES` | `{"jiosaavn": jiosaavn, "ytmusic": ytmusic}` | Every source module, by its ID. |
| (assert) | `set(SOURCES) == SourceName` | The server refuses to start if this table and `SourceName` disagree. |

### `lifespan(app)`
- **Does:** startup and shutdown work.
- **Returns:** nothing. It is a context manager: code before `yield` runs at startup; code after `yield` runs at shutdown.
- **How:** makes the pool (`db.make_pool`), opens it, creates missing tables (`db.apply_schema`), stores the pool in `app.state.pool`. At shutdown: closes the pool.
- **Called by:** FastAPI, once.

### `root()` — `GET /`
- **Does:** says hello. **Returns:** `{"app_name": "NoNonsenseMusic", "api_version": "1.0"}`.

### `health()` — `GET /health`
- **Does:** shows the server is alive. **Returns:** `{"status": "ok"}`. **Called by:** the app's Settings window.

### `search_one(name, source, q)`
- **Does:** runs one source's search safely.
- **Returns:** `(listings, SearchSourceInfo)`. It never raises.
- **How:** times the call. If the source fails, logs a warning, returns an empty list and puts the error's name in `SearchSourceInfo.error`.
- **Called by:** `search`.

### `search(q)` — `GET /search?q=`
- **Does:** the search endpoint.
- **Returns:** `SearchResponse` (query, one `SearchSourceInfo` per source, ranked songs).
- **How:** runs `search_one` for every source at the same time (`asyncio.gather`), then `rank_songs`.
- **Called by:** the app (`API.search`).

### `play(source, song_id)` — `GET /play/{source}/{song_id}`
- **Does:** finds the audio file for one listing.
- **Returns:** a 307 redirect to the audio URL. 404 if the song does not exist. 502 if the source is down. 422 if `source` is unknown.
- **How:** `SOURCES[source].get_song_url(song_id)`. Translates `SongNotFound` → 404 and `SourceUnavailable` → 502.
- **Called by:** the app's player (AVPlayer follows the redirect).

### `like_song(body, request)` — `POST /liked`
- **Does:** likes a song.
- **Returns:** `SongRef` (the stored song's ID).
- **How:** borrows a connection, `library.resolve_song`, then `library.like`.
- **Called by:** the app (`API.like`).

### `unlike_song(song_id, request)` — `DELETE /liked/{song_id}`
- **Does:** unlikes a song.
- **Returns:** 204. 404 if it was not liked.
- **How:** `library.unlike`.

### `get_liked(request)` — `GET /liked`
- **Does / Returns:** liked songs, newest first (`list[LibrarySong]`).
- **How:** `library.liked_songs`.

### `get_recent(request, limit=50)` — `GET /recent`
- **Does / Returns:** recently played songs, newest first (`list[LibrarySong]`).
- **How:** `library.recent_songs`.

### `add_event(body, request)` — `POST /events`
- **Does:** records a play, skip or finish.
- **Returns:** `SongRef`.
- **How:** `library.resolve_song`, then `library.record_event`.
- **Called by:** the app's player on every start, skip and finish.

---

## models.py

| Model / type | Fields | Used for |
|---|---|---|
| `SourceName` | `"jiosaavn"` or `"ytmusic"` | The one list of source IDs. Used everywhere a source is named. |
| `Listing` | `source, id, title, artists, album, duration, popularity, image` | One copy of a song. `artists` is a list; "no artist" is `[]`. |
| `BaseSong` | `title, artists, duration, best, listings` | The five fields every song has. `Song` and `LibrarySong` inherit from it. |
| `Song` | `BaseSong` + `score` | One search result. No ID (not stored). `score` = RRF score. |
| `SearchSourceInfo` | `source, healthy, num_results, ms, error` | Each source's health for one search. `error` is left out of the JSON when it is empty. |
| `SearchResponse` | `query, sources, songs` | What `/search` returns. |
| `EventType` | `"play"`, `"skip"`, `"finish"` | Allowed event types. |
| `ListingsRequest` | `listings` (at least 1) | Body of `POST /liked`. `EventRequest` extends it. |
| `EventRequest` | `listings, type, position` | Body of `POST /events`. `position` ≥ 0 seconds. |
| `SongRef` | `song_id` | Reply to `POST /liked` and `POST /events`. |
| `LibrarySong` | `BaseSong` + `id, liked, at` | One stored song, as shown in Liked and Recent. |

---

## sources/__init__.py

Every source module offers the same two functions, and reports failures with the same two errors:

| Name | Meaning | Becomes |
|---|---|---|
| `search(query) -> list[Listing]` | Search this source. | — |
| `get_song_url(song_id) -> str` | The audio URL for one listing. | — |
| `SongNotFound` | No playable song with this ID. | HTTP 404 |
| `SourceUnavailable` | The source could not be reached or was too slow. | HTTP 502 |

---

## sources/jiosaavn.py

| Constant | Meaning |
|---|---|
| `SEARCH_URL` | `https://www.jiosaavn.com/api.php` (every JioSaavn call uses this URL) |
| `SEARCH_PARAMS` | Fixed search parameters (`__call`, page, count). |
| `PREAMBLE_PARAMS` | Parameters every call needs (`_format`, `api_version`, …). |
| `REQUEST_TIMEOUT` | 2 seconds. |
| `URL_DECRYPTION_SECRET` | The DES key, `38346591`. |

### `search(query)`
- **Returns:** `list[Listing]`.
- **How:** GET `SEARCH_URL` with `SEARCH_PARAMS | PREAMBLE_PARAMS | {"q": query}`, then `to_listing` on each result.

### `to_listing(result)`
- **Does:** turns one raw JioSaavn result into a `Listing`.
- **How:** unescapes HTML in text (`&quot;` → `"`); takes only `primary_artists` (not featured or composers); turns the 150×150 image URL into 500×500; duration and play count arrive as text and Pydantic converts them to numbers.

### `get_song_url(song_id, kbps="320")`
- **Returns:** the 320 kbps audio URL.
- **How:** `song.getDetails` with `pids=song_id`. If the reply has no `songs` key → `SongNotFound`. If the request fails → `SourceUnavailable`. Otherwise decrypts `encrypted_media_url` and swaps `_96.mp4` for `_320.mp4`.

### `decrypt_media_url(encrypted)`
- **Returns:** the plain URL.
- **How:** base64-decode → DES-decrypt (ECB mode, the key above) → bytes to text.

---

## sources/ytmusic.py

| Constant | Meaning |
|---|---|
| `SEARCH_URL` | YouTube Music's private search API (InnerTube). |
| `WATCH_URL` | Prefix for a video's page; yt-dlp reads it. |
| `YTDLP_OPTIONS` | `bestaudio[ext=m4a]/bestaudio`: m4a first, because Apple's player cannot play WebM. |
| `CLIENT` | Tells YouTube we are the YouTube Music website (`WEB_REMIX`). |
| `SONGS_ONLY` | The "Songs" filter chip's code. |
| `VIDEO_ID_PATHS` | The three places a row can keep its video ID (YouTube serves two row layouts). |

### `search(query)`
- **Returns:** `list[Listing]`.
- **How:** POST to `SEARCH_URL` with `CLIENT`, the query and `SONGS_ONLY`. `song_rows` finds the rows; `to_listing` reads each. A row that fails to read is skipped and logged, so one odd row does not lose the other 19.

### `song_rows(response)`
- **Returns:** the song rows (`list[dict]`).
- **How:** walks down the nested reply (`contents → tabs → … → musicShelfRenderer`). Ignores sections that are not song lists.

### `to_listing(item)`
- **How:** column 0 = title; column 1 = artists • album • duration (split by `split_on_separator`); column 2 = play count. ID from `video_id`, image from `artwork`.

### `artwork(item)` — the cover URL, rewritten from 60/120 px to 544 px. `None` if missing.
### `video_id(item)` — tries each path in `VIDEO_ID_PATHS`. Raises `KeyError` if none has an ID.
### `column(item, index)` — the text pieces ("runs") of one column. `[]` if the column is missing.
### `split_on_separator(runs)` — splits runs into groups at each `" • "`.
### `to_seconds(duration)` — `"3:22"` → 202; `"1:02:03"` → 3723.
### `to_count(plays)` — `"2.6K plays"` → 2600; `"9.5B plays"` → 9,500,000,000.

### `get_song_url(song_id)`
- **Returns:** the audio URL (m4a, about 130 kbps).
- **How:** runs `extract_audio_url` on a separate thread (`asyncio.to_thread`), because yt-dlp blocks for about 2 seconds and would otherwise freeze the server.

### `extract_audio_url(song_id)`
- **How:** yt-dlp `extract_info(…, download=False)`, then `info["url"]`. yt-dlp wraps every error in `DownloadError`; the error inside decides: "video unavailable" (`ExtractorError`, `expected=True`) → `SongNotFound`; anything else → `SourceUnavailable`.

---

## matching.py

| Constant | Value | Meaning |
|---|---|---|
| `DURATION_TOLERANCE` | 5 | Seconds two listings may differ and still be the same recording. |
| `RRF_K` | 60 | The constant in Reciprocal Rank Fusion. |
| `FUZZ_THRESHOLD` | 90 | Minimum spelling similarity (0–100) for two artist names to match. |
| `SOURCE_PREFERENCE` | jiosaavn 0, ytmusic 1 | Lower plays first (better audio). |

### `normalise(title)` — yours
- **Returns:** lowercase text, accents removed, punctuation turned into spaces, spaces collapsed. `"ROSALÍA"` → `"rosalia"`.

### `artists_match(a, b)` — yours
- **Returns:** `True` if at least one artist in `a` is the same person as one in `b`.
- **How:** normalise every name. Skip empty names. A pair matches if the words of one name are all in the other, or the spelling similarity is above `FUZZ_THRESHOLD`.

### `same_recording(a, b)` — yours
- **Returns:** `True` if the normalised titles are equal, the artists match, and the durations are within `DURATION_TOLERANCE`.
- **Called by:** `group_listings`, `library.resolve_song`.

### `interleave(by_source)` — yours
- **Returns:** one list: source 1's #1, source 2's #1, source 1's #2, …

### `group_listings(listings)` — yours
- **Returns:** groups (`list[list[Listing]]`), one group per recording.
- **How:** each listing joins the first group whose **first** listing it matches; otherwise it starts a new group. Comparing only with the first listing stops chains (200 ≈ 204 ≈ 208).

### `pick_best(group)`
- **Returns:** the one listing to play.
- **How:** the smallest of (source preference, minus popularity, distance from the group's median length). Python compares the parts left to right, so popularity only matters between listings of the same source.

### `rrf_score(group, positions)`
- **Returns:** the song's score: the sum, over its listings, of `1 / (RRF_K + position + 1)`.

### `rank_songs(by_source)`
- **Returns:** `list[Song]`, best first.
- **How:** remember each listing's position in its own source → `interleave` → `group_listings` → `to_song` with `rrf_score` → sort by score.
- **Called by:** `main.search`.

### `to_song(group, score)`
- **Returns:** a `Song`. Title, artists, duration come from `pick_best(group)`. All listings are kept.

---

## library.py

### `resolve_song(conn, listings)`
- **Does:** finds the stored song these listings are copies of, or creates it.
- **Returns:** the song's ID (UUID).
- **How** (all inside one transaction):
  1. Is any of these listings already in `listings`? Then that song. (Exact identity. Safe to check all of them.)
  2. Otherwise: songs with the same `normalised_title`, checked with `same_recording`.
  3. Otherwise: a new song, frozen from the first listing.
  4. Then: each listing that passes `same_recording` against the song's frozen identity is linked. Already-linked listings are skipped (`ON CONFLICT DO NOTHING`).
- **Called by:** `like_song`, `add_event`.

### `like(conn, song_id)` — inserts into `likes`. A second like does nothing.
### `unlike(conn, song_id)` — deletes from `likes`. **Returns:** `True` if a like was deleted.
### `record_event(conn, song_id, event_type, position)` — inserts one row into `events`.

### `liked_songs(conn)`
- **Returns:** liked songs, newest like first.
- **How:** reads only the `likes` table (`song_id AS id, liked_at AS at, true AS liked`), then `_with_listings`.

### `recent_songs(conn, limit=50)`
- **Returns:** recently played songs, each once, newest first.
- **How:** play events grouped by song, the latest time per song, a `LEFT JOIN` to `likes` to fill `liked`, then `_with_listings`.

### `_with_listings(conn, rows)`
- **Does:** turns song rows into `LibrarySong`s.
- **How:** **one** query loads the listings of all the songs (`song_id = ANY(...)`), groups them by `song_id` in a dict, and shows each song through `pick_best`. One query for all songs, not one per song (this avoids the "N+1 query" problem).

---

## db.py

| Name | Meaning |
|---|---|
| `DATABASE_URL` | `settings.database_url`: `postgresql:///music` unless `.env` or the environment says otherwise. No host or password: the local socket, as your macOS user. Tests replace this name with `music_test`. |
| `SCHEMA` | The path of `backend/schema.sql`. |

### `make_pool(url)`
- **Returns:** a connection pool (not opened yet).
- **How:** every connection it opens returns rows as dicts (`row_factory = dict_row`), so code reads `row["title"]`, not `row[0]`.

### `apply_schema(pool)`
- **How:** borrows one connection and runs `schema.sql`. Every statement is `IF NOT EXISTS`, so this is safe on every start.

## settings.py

### `settings` (one `Settings` object, built on import)
- **Does:** reads `backend/.env` once, checks every value's type, and gives the rest of the code typed values.
- **Use:** `from music_backend.settings import settings`, then `settings.cache_max_size`.
- **How:** Pydantic Settings (`pydantic-settings`). A field `cache_max_size` reads the key `CACHE_MAX_SIZE` (case does not matter).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `database_url` | `str` | `postgresql:///music` | Where the database is |
| `youtube_cache_expiry_threshold` | `int` | `30` | **Minutes.** A cached YouTube URL this close to its `expire=` time is fetched again |
| `jiosaavn_cache_expiry_threshold` | `int \| None` | `None` | `None`: JioSaavn URLs carry no expiry |
| `cache_max_size_in_memory` | `int` | `3000` | Entries in the audio-URL cache before the least recently used is dropped |
| `cache_max_size_in_db` | `int` | `6000` | Rows in `listing_urls`. After each write, the oldest-fetched rows beyond this are deleted (~1 ms, measured 5 Oct 2026) |
| `jiosaavn_des_key` | `str \| None` | `None` | Not used yet: `jiosaavn.py` still has its own copy |

**Rules (each checked 5 Oct 2026):**
- A variable set in the real environment **wins** over `.env` (`DATABASE_URL=… uv run …`).
- `.env` is found by an absolute path, so the server can start from any folder.
- `KEY="None"` means `None`. `KEY=` (empty) means "not set": the default is used.
- A wrong type stops the server at startup (`CACHE_MAX_SIZE=lots` → `Input should be a valid integer`).
- A key in `.env` with no field stops the server at startup (`CACHE_MAX_SIZ` → `Extra inputs are not permitted`). That catches typos.
- **Add a setting:** a field in `Settings`, plus the key in `.env` and in `.env.example` (committed; never put a real secret in it).

## cache.py

### `ListingURLCache(sources, pool)`
- **Does:** remembers each listing's audio URL in two levels: memory (an `OrderedDict`, emptied on restart) and the `listing_urls` table (survives restarts). Both drop the **least recently used** entry when full (`cache_max_size_in_memory`, `cache_max_size_in_db`).
- **Use:** `url = await cache(source, song_id, serve_fresh)`. The lifespan builds one: `app.state.url_cache`.
- **Called by:** `/play`.

| Method | Does |
|---|---|
| `__call__` | The rule: unless `serve_fresh`, `get`. Nothing good? Fetch from the source, then `set`. Returns the URL. A source error passes through, so failures are never stored |
| `get` | Memory, then the table. Returns `None` if missing or expired (`is_expired` of that source). A good URL goes through `set` (memory hit or table hit alike), which marks it used in both levels and keeps both limits |
| `set` | Memory (store, `move_to_end`, trim), then `_set_db`. Used after a fetch and on every hit |
| `_cache_hit` | Memory: `move_to_end`, and drop the oldest if over the limit |
| `_get_db` | Table: the URL for `(source, source_id)`, or `None` |
| `_set_db` | Table: one upsert (`fetched_at` changes only if the URL changed; `hit_at = now()`), then a trim to the newest `cache_max_size_in_db` by `hit_at`. One block, one commit |

**Checked 5 Oct 2026:** a memory hit keeps `fetched_at` and moves `hit_at`; a fresh fetch with a new URL moves `fetched_at`, with the same URL (JioSaavn) it does not; with a limit of 3, storing P Q R, replaying P, then adding S leaves R P S (Q, the least recently used, goes). With every hit going through `set`: memory stays at its limit after a restart (5 table hits, limit 3 → 3), and a memory hit costs 0.83 ms with 6,000 rows in the table (the upsert + trim). `DELETE` + `INSERT` instead of the upsert crashed with `UniqueViolation` when two requests wrote one listing at once.

