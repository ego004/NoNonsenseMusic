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

### Logging
- INFO for libraries, DEBUG for our own logger. **httpx at WARNING**: it logged a line for every request it sent. **`/health` left out of the access log** (`_NoHealthChecks`): the app asks it while waiting for the server to start; it was 1,141 of 2,178 log lines (7 Oct, mostly self-tests, which now log to their own file).

### `lifespan(app)`
- **Does:** startup and shutdown work.
- **Returns:** nothing. It is a context manager: code before `yield` runs at startup; code after `yield` runs at shutdown.
- **How:** makes the pool (`db.make_pool`), opens it, creates missing tables (`db.apply_schema`), stores the pool in `app.state.pool`, makes the URL cache and starts the prefetch workers. At shutdown, in this order: cancels the workers and the lookups still running, closes the sources' kept connections (`source.http.close()`) and LRCLIB's (`lyrics.http`), closes the pool.
- **Called by:** FastAPI, once.

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

### `play(source, source_id)` — `GET /play/{source}/{source_id}`
- **`source_id`:** the source's own id for the listing (`fW-Mxsnu`, a YouTube video id), not our song UUID. Renamed from `song_id` on 6 Oct; the URL is unchanged.
- **Does:** finds the audio file for one listing.
- **Returns:** a 307 redirect to the audio URL. 404 if the song does not exist. 502 if the source is down. 422 if `source` is unknown.
- **How:** `SOURCES[source].get_song_url(source_id)`. Translates `SongNotFound` → 404 and `SourceUnavailable` → 502.
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

### `prefetch_urls(body, request)` — `POST /prefetch`
- **Body:** `{"listings": [{"source": "ytmusic", "source_id": "J7p4bzqLvCw"}, …]}`, 1 to 50 (`PrefetchRequest`).
- **Returns:** 202 at once. The listings are looked up in the background by the prefetch workers; a newer list replaces whatever still waits (lookups already running finish).
- **Called by:** the app's `Prefetcher`: the next 5 of the playing queue, then the top 5 of the search on screen.

### `get_lyrics(body)` — `POST /lyrics`
- **Body:** `{"song_name": "Les", "artist_name": "Childish Gambino", "song_duration": 317, "youtube_id": "…"}` (`LyricsRequest`). `youtube_id`: the song's `ytmusic` listing, if it has one, even when JioSaavn's copy plays; may be left out.
- **Returns:** always 200, `LyricsResponse`: `{"lyrics_source": "lrclib" | "ytmusic" | null, "synced": bool, "lines": [{"start_ms": 19120 | null, "text": "…"}]}`. Nothing found, or an instrumental: `lines: []`. A line ends where the next begins.
- **How:** `app.state.lyrics_cache` (`LyricsCache`, in cache.py), which asks `lyrics.find_lyrics` only when the `lyrics` table has no good answer. Measured 6 Oct: not stored yet, 0.7 s (LRCLIB) to 2.0 s (YouTube); stored, 3–4 ms.

### Playlists (MUS-2) — `/playlists`

Every id is a UUID: a malformed one is 422 (FastAPI), an unknown one is 404 (ours).

| Endpoint | Body | Reply | Errors |
|---|---|---|---|
| `POST /playlists` | `PlaylistRequest` `{name}` | 201 · `PlaylistMetadata`, at the bottom of your list | 409 name taken, 422 empty |
| `GET /playlists` | — | `PlaylistsResponse`, in your order | — |
| `GET /playlists/{playlist_id}` | — | `PlaylistItems`: the metadata + `items`, in order | 404 |
| `PATCH /playlists/{playlist_id}` | `PlaylistRequest` | `PlaylistMetadata` (renamed) | 404, 409, 422 |
| `DELETE /playlists/{playlist_id}` | — | 204. Its items go (`ON DELETE CASCADE`), the songs stay | 404 |
| `POST /playlists/{playlist_id}/items` | `ListingsRequest` | 201 · `PlaylistItemRef` `{item_id, song_id}`, at the bottom | 404, 422 |
| `DELETE /playlists/{playlist_id}/items/{item_id}` | — | 204 | 404 (also for an item of another playlist) |
| `POST /playlists/{playlist_id}/items/{item_id}/move` | `MoveRequest` | 204. Exactly one row changes | 404 item/neighbour not in this playlist, 422 wrong order or own neighbour |
| `POST /playlists/{playlist_id}/move` | `MoveRequest` (neighbours are playlist ids) | 204. Exactly one row changes | 404, 422 |

- **Add** runs `resolve_song` and the insert in one transaction: a 404 also undoes the song it stored, and it is the fastest of the three ways measured (0.49 ms vs 0.52 ms per add, 6 Oct).
- **Errors from the database are the judge:** a taken name is a `UniqueViolation` (409), an unknown playlist on add is a `ForeignKeyViolation` (404). No check-then-insert, so two requests at once cannot both pass a check.
- **Move:** `MoveRequest` names the new neighbours, `top_neighbour_id` (above) and `bottom_neighbour_id` (below); either may be `null` (the top or the bottom of the list). Both `null` changes nothing (204).

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

## lyrics.py (MUS-12)

`LYRICS_SOURCES = {"lrclib": …, "ytmusic": …}`: the lyrics sources, in the order they are asked. Each takes the whole `LyricsRequest`, returns a `LyricsResponse`, and raises `LyricsNotFound` when it has nothing. A new source is one more entry.

### `find_lyrics(song)` → `(reply, every_source_answered)`
- **Does:** asks each source in turn. Timed lyrics end the search at once. Plain lyrics are kept (the first), in case a later source has timed ones. An answer with no lines (LRCLIB's "instrumental") does not stop the search: another source may have words (an instrumental now takes ~1.8 s instead of ~0.7 s, measured 6 Oct). A source that raises is skipped (logged); nobody having lyrics is an empty reply. Never raises for a source's sake; a cancelled request still stops (`except Exception` does not catch `CancelledError`). `every_source_answered` is False when a source raised something other than `LyricsNotFound`: it might have had better, so the cache keeps a reply that is not timed only when this is True.

### `get_lyrics_lrclib(song)`
- `GET https://lrclib.net/api/get` through its own `SharedClient` (`http`, 3 s, a User-Agent naming the app; the lifespan closes it). 404 and 503 both mean "not here": the same kind of miss answered 503 one time and 404 the next (measured 6 Oct). Any other non-200 raises (`raise_for_status`). `syncedLyrics` → timed lines (`parse_lrc`); else `plainLyrics` → plain lines; both `None` → an instrumental.

### `get_lyrics_ytmusic(song)` and `youtube_lyrics(video_id)`
- Needs `youtube_id`. ytmusicapi blocks (it uses `requests`), so `youtube_lyrics` runs in a thread (`asyncio.to_thread`): `get_watch_playlist(videoId)["lyrics"]` (a browseId, or `None`: no lyrics), then `get_lyrics(browseId, timestamps=True)`; on `KeyError: 'cueRange'` (ytmusicapi issue #1002) it asks again untimed. Timed: `LyricLine` objects (ms); untimed: one string, split into lines.
- `yt = YTMusic()` at import makes no web request (measured). Its own request timeout is 30 s.

### `parse_lrc(text)` and `plain_lines(text)`
- LRC to timed lines in time order: a line with two stamps becomes two lines, tag lines (`[ar: …]`) are skipped, a stamp with no words is kept as `""` (a gap). Plain text to lines with `start_ms: None`; blank lines stay (verse gaps).

## http_client.py

### `SharedClient(**options)`
- **Does:** one `httpx.AsyncClient` per outside service, kept for the server's life. `options` go to the client as they are (`timeout`, `headers`, …).
- **Use:** `http = SharedClient(timeout=2)` once at module level, then `await http.client.get(url)`. `await http.close()` at shutdown.
- **Why:** a new client per request opens a new connection each time (a TCP handshake, then a TLS handshake) and throws it away. A kept client reuses its open connection. Measured 6 Oct, medians of 5 searches: YouTube Music 599 ms → 463 ms, JioSaavn 283 ms → 193 ms. Tested offline: 5 requests through one `SharedClient` open 1 connection; 5 through new clients open 5.
- **How:** the client is made on first use, not at import (an `AsyncClient` belongs to the event loop it first runs in, and there is none at import); a closed one is replaced, so tests can start and stop the server many times.

## Explicit versions (MUS-19, 7 Oct)
- `Listing.explicit`: `True` explicit, `False` clean, `None` not known. JioSaavn: `explicit_content == "1"`; YouTube Music: `is_explicit(item)`, the row's E badge.
- `listings.explicit` (boolean, nullable; `schema.sql` adds it). `resolve_song` fills in an unknown flag when a listing is seen again (`ON CONFLICT … DO UPDATE … WHERE listings.explicit IS NULL`) and never overwrites a known one.
- The server's `pick_best` does not look at it: the app picks your version (Settings › Playback).
- `scripts/backfill_explicit.py`: fills unknown flags from the sources (JioSaavn details, 20 per call; YouTube searches, 2 s apart). Run once on 7 Oct: 111 of 111 filled.

## sources/__init__.py

Every source module offers the same two functions, and reports failures with the same two errors:

| Name | Meaning | Becomes |
|---|---|---|
| `search(query) -> list[Listing]` | Search this source. | — |
| `get_song_url(song_id) -> str` | The audio URL for one listing. | — |
| `SongNotFound` | No playable song with this ID. | HTTP 404 |
| `SourceUnavailable` | The source could not be reached or was too slow. | HTTP 502 |

Each source module also has `http`, its `SharedClient` (above); the lifespan closes it at shutdown.

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
- **Does:** finds the stored song these listings are copies of, or creates it. The listings that are the same recording are stored in one round trip (`executemany`, 7 Oct), not one per listing.
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

### Playlists (MUS-2)
- **Positions:** `fractional-indexing` keys in `position text COLLATE "C"` (`a0`, `a1`, `a0V` between them, `Zz` before `a0`). A new playlist or song goes after the largest key so far. A move computes one key between the new neighbours, so one row changes.
- `create_playlist(conn, name)` → the new id. A taken name raises `UniqueViolation`.
- `get_playlists(conn)` → every `PlaylistMetadata`, in your order, with counts and durations: **one query** (`LEFT JOIN` + `GROUP BY`; an empty playlist gets 0 and 0). It was one query plus `_totals` per playlist (1 + N), 7 Oct.
- `_totals(conn, playlist_id)` → `{"song_count", "duration"}`. `COALESCE`: an empty playlist's `SUM` is `NULL`.
- `get_playlist_metadata(conn, playlist_id)` → one `PlaylistMetadata`, or `None` (the 404).
- `get_playlist_items(conn, playlist_id)` → the `PlaylistItem`s in order: one row per item (a song added twice is two items), `ORDER BY position, id` (the UUIDv7 id breaks ties), songs built by `_with_listings`.
- `add_to_playlist(conn, playlist_id, song_id)` → the new item id. An unknown playlist raises `ForeignKeyViolation`.
- `rename_playlist`, `delete_playlist`, `remove_from_playlist` → `True` if a row changed (`rowcount`). Remove matches the item **and** the playlist.
- `move_item(conn, playlist_id, item_id, top_id, bottom_id)`, `move_playlist(conn, playlist_id, top_id, bottom_id)` → read the positions of the row and its neighbours, then `_move`: raises `NotInList` (404) if one is missing, `BadMove` (422) for a row named as its own neighbour or neighbours in the wrong order (`FIError`), else updates one row.

## db.py

| Name | Meaning |
|---|---|
| `DATABASE_URL` | `settings.database_url`: `postgresql:///music` unless `.env` or the environment says otherwise. No host or password: the local socket, as your macOS user. Tests replace this name with `music_test`. |
| `SCHEMA` | The path of `backend/schema.sql`. |

### `make_pool(url)`
- **Returns:** a connection pool (not opened yet).
- **How:** every connection it opens returns rows as dicts (`row_factory = dict_row`), so code reads `row["title"]`, not `row[0]`. Sizes (7 Oct): 1 connection kept open, up to 8 under load (4 prefetch workers and requests), extras closed after 60 s idle. psycopg's default kept 4 open all the time: 4 Postgres processes, 7–11 MB each.

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
| `lyrics_recheck_days` | `float` | `7` | **Days.** Plain or empty lyrics are asked for again after this long; timed lyrics are kept for good |

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
| `get` | Memory, then the table. Returns `None` if missing or expired (`is_expired` of that source). Any hit marks its row used, so the trim drops the least recently used: a memory hit with `_db_hit`, a table hit with `_take_db` (reads and marks in one statement), and a table hit also copies the URL into memory (`_remember`). No trim on a hit: a hit adds no row. This is the way in for a play; the prefetch worker uses `_has_fresh` |
| `set` | After a real fetch: `_remember`, then `_set_db` (the upsert and the trim: the table grows only here) |
| `_remember` | Memory: store as the most recently used, drop the least recently used past the limit |
| `_db_hit` | Table: `hit_at = now()` for one row |
| `_cache_hit` | Memory: `move_to_end`, and drop the oldest if over the limit |
| `_get_db` | Table: the URL for `(source, source_id)`, or `None`; only reads |
| `_take_db` | Table: the URL, and `hit_at = now()`, in one `UPDATE … RETURNING` (it was a `SELECT`, then an `UPDATE`: two round trips) |
| `_has_fresh` | Whether a good URL is cached, marking nothing (memory read without reordering, else `_get_db`): the prefetch worker's check. It used `get`, so "least recently used" meant "least recently prefetched" |
| `_set_db` | Table: one upsert (`fetched_at` changes only if the URL changed; `hit_at = now()`), then a trim to the newest `cache_max_size_in_db` by `hit_at`. One block, one commit |

**Changed 7 Oct:** every hit, even from memory, went through `set`, so each wrote the table twice (an upsert and the trim's `DELETE … ORDER BY hit_at OFFSET`): 300 hits sent 600 statements (median 0.345 ms each), on every `/play` and every prefetch check of a cached listing. Now a hit sends one statement, the `hit_at` update (300 hits: 300 statements, median 0.124 ms), and the trim runs only when a new URL is stored, the only time the table can grow. Your rule is kept: `hit_at` is the last use, memory hits included. As before, a memory hit waits for Postgres (for that one update). Two tests guard it: a memory hit only marks its row; a table hit fills memory and marks its row without storing it again.

**Checked 5 Oct 2026 (before that change):** a memory hit keeps `fetched_at` and moves `hit_at`; a fresh fetch with a new URL moves `fetched_at`, with the same URL (JioSaavn) it does not; with a limit of 3, storing P Q R, replaying P, then adding S leaves R P S (Q, the least recently used, goes). With every hit going through `set`: memory stays at its limit after a restart (5 table hits, limit 3 → 3), and a memory hit costs 0.83 ms with 6,000 rows in the table (the upsert + trim). `DELETE` + `INSERT` instead of the upsert crashed with `UniqueViolation` when two requests wrote one listing at once.

### Single-flight (MUS-1 step 2)
- `single_flight(running, key, work)` (a module function, used by both caches): the lookup already running for `key` (in `running`), or a new one started as a task and registered at once; when it ends, worked or failed, the key leaves `running`, so failures are never kept. It was written out twice.
- `_start_lookup(source, id)`: `single_flight` per listing. `__call__` and the prefetch workers both use it, so one listing is never looked up twice at the same moment. Requests wait behind `asyncio.shield`: a cancelled request (a skipped song) ends only its own wait.
- `_lookup(source, id)`: the lookup itself.

### Backoff (MUS-1 step 2b)
- `blocked_until[source]`, `strikes[source]`: per source, because a bot check blocks the IP, not one song.
- `_refuse_if_paused(source)`: during a pause, raise `SourceBlocked(until=…)` before asking the source (not a strike).
- `_strike(source)`: a bot check from the source: pause `backoff_start_minutes × 2^(strikes − 1)`, at most `backoff_max_minutes`; a lookup that works resets the strikes.

### Prefetch (MUS-1 step 3)
- `prefetch(listings)`: empties `prefetch_queue` and puts the new list in (no waiting).
- `prefetch_worker()`: `num_prefetch_workers` of them, started in `lifespan` and cancelled at shutdown (before the pool closes, with any lookups still running). Forever: take a listing; skip it if running or cached (`_has_fresh`: a prefetch does not count as a use); else look it up. Expected failures (a gone song, a blip, a pause) log one line; anything else logs a traceback; the worker always carries on.

### `LyricsCache(pool)`
- **Does:** keeps lyrics replies in the `lyrics` table, one row per song as the app asks for it: `(song_name, artist_name, song_duration, youtube_id or '')`. With and without a YouTube copy are two rows (the answers can differ).
- **Use:** `reply = await lyrics_cache(song)`. The lifespan builds one: `app.state.lyrics_cache`; its running lookups are cancelled at shutdown with the URL cache's.
- **Called by:** `POST /lyrics`.
- **Why not `ListingURLCache` renamed:** lyrics are per song, not per listing; timed lyrics never go stale; one table read is 3–4 ms, so no memory level; no backoff, no workers. Only single-flight is shared (`single_flight`).

| Rule | Why |
|---|---|
| Timed: kept for good | lyrics do not change |
| Plain or empty: kept for `lyrics_recheck_days` (7), then asked again | a source may add them, or add timings |
| A source failed and the reply is not timed: not kept | that source might have had timed lyrics; the next request asks again |
| Two requests for one song at once: one lookup (`running`, `shield`) | the app may fetch when a song starts and when Lyrics opens; a request that gives up does not cancel the other's |
