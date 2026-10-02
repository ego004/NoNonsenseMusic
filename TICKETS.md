# Tickets

How this works:

1. Pick the next ticket. Make a branch: `git switch -c mus-1` (one branch per ticket).
2. Read the docs listed, build it, run the acceptance checks yourself.
3. Tell Claude "MUS-1 ready". Claude runs every acceptance check and reviews the code: what is wrong + a failing case, never the fix.
4. When everything passes: commit, merge into `main`, demo it to yourself, move on.

Stuck for more than 30 minutes? Bring: what you tried, what you expected, what happened.

| Ticket | What you can show at the end | Who | Size |
|---|---|---|---|
| MUS-1 ✅ | Break a source on purpose, search still works and says which source failed | You | S |
| MUS-2 ✅ | Open a link in Chrome and a song plays from **your** API | You + Claude | L |
| MUS-3 ✅ | Search shows each song once, best version picked, ranked with RRF | You + Claude | L |
| MUS-4 ✅ | Like a song, restart the server, it is still liked; plays and skips are recorded | **You** | L |
| MUS-5 | Your Spotify liked songs and playlists appear in your library | **You** (OAuth, API) · Claude (setup) | M |
| MUS-6 ◐ | An app you can actually use daily: search, tap, play, next (Mac v1 built 2 Oct; phone later) | **Pair** (new language) | L |
| MUS-7 | Shuffle that never clumps one artist | **You** | S |
| MUS-8 | When the queue ends, music keeps going, shaped by your skips | **You** (ranking, `/next`) · Claude (radio parser) | M |
| MUS-9 | Search your library: "weekend" finds The Weeknd, "sad arijit" works | **Pair** | L |
| MUS-10 | The second identical search is much faster, with numbers | **You** | M |
| MUS-11 | Your phone on mobile data plays from your Mac | **Pair** | M |
| MUS-12 | Every played song gets a "sounds like" vector | Claude (model setup) · **You** (background job) | M |
| MUS-13 | About 1 in 5 autoplay songs is new to you, and it learns which new ones you skip | **You** | M |
| MUS-14 | Your own "people who played X played Y" model, beating or losing to YouTube radio on your skip rate | **Pair** | L |

---

## MUS-1 · Search survives a broken source

**Why:** today, if YouTube Music errors out, `asyncio.gather` passes the error up and `/search` returns HTTP 500, even though JioSaavn answered fine.

**Change the response of `GET /search?q=...` to:**

```json
{
  "query": "blinding lights",
  "listings": [ ...all listings from the sources that worked... ],
  "sources": {
    "jiosaavn": { "ok": true,  "count": 20, "ms": 223 },
    "ytmusic":  { "ok": false, "count": 0,  "ms": 5003, "error": "ReadTimeout" }
  }
}
```

**Acceptance checks**

- [ ] Every source request has a timeout (pick a number, be ready to justify it).
- [ ] Change the YouTube Music URL to something wrong on purpose: `/search` still returns **HTTP 200** with the 20 JioSaavn listings, and `sources.ytmusic.ok` is `false` with the error's name.
- [ ] The failure shows up in the server log via Python's `logging` module (not `print`).
- [ ] Put the URL back: both sources `ok: true` again.
- [ ] `ms` is each source's own time, not the total.
- [ ] The response shape is a Pydantic model, so Swagger (`/docs`) shows it.

**Docs:** httpx [Timeouts](https://www.python-httpx.org/advanced/timeouts/) · [`asyncio.gather`](https://docs.python.org/3/library/asyncio-task.html#asyncio.gather) (read `return_exceptions`) · [Logging HOWTO](https://docs.python.org/3/howto/logging.html) (Basic Logging Tutorial) · FastAPI [Response Model](https://fastapi.tiangolo.com/tutorial/response-model/)

---

## MUS-2 · Play a song

**Why:** the moment the app becomes real.

**New endpoint:** `GET /play/{source}/{id}`. Opening it in Chrome plays the song.

**Research already done (verified 2 Oct 2026, you don't need to rediscover it):**

- **JioSaavn:** each song has `more_info.encrypted_media_url`. It is base64 text, encrypted with **DES in ECB mode, key `38346591`**. Decrypted, it is a URL ending `_96.mp4` (96 kbps). Swapping that for `_320.mp4` gives 320 kbps. To look a song up by id: `__call=song.getDetails&pids=<id>` on the same `api.php` endpoint. Library for DES: `pydes` (`uv add pydes`).
- **YouTube Music:** use `yt-dlp` as a library (`uv add yt-dlp`), ask it for the info of `https://music.youtube.com/watch?v=<id>` **without downloading**, and take the best audio-only format (format `251`, Opus, ~133 kbps).

**One design decision is yours. Write your choice and reason in the code as a comment:**

| Option | Consequence |
|---|---|
| **Redirect** (send the browser to the audio file's real URL) | Simplest; the audio never passes through your server. YouTube's URLs are tied to the IP address that asked for them, which is fine while server and browser are the same machine |
| **Proxy** (your server fetches the bytes and passes them on) | Works from any device; you control caching later; costs your bandwidth and needs HTTP Range requests for seeking |

Start with redirect. Proxy is the stretch goal.

**Acceptance checks**

- [ ] `/play/jiosaavn/fW-Mxsnu` plays *Blinding Lights* in Chrome, and DevTools → Network shows a file of about **8 MB** (proves it is the 320 kbps one).
- [ ] `/play/ytmusic/J7p4bzqLvCw` plays.
- [ ] An id that does not exist returns **404 with a message**, not 500.
- [ ] `yt-dlp` is slow (1–3 s) and *blocking*. While a YouTube `/play` is resolving, `/health` must still answer instantly. Test it with two terminal tabs. This proves you did not freeze the whole server.
- [ ] Dragging the progress bar (seeking) works.
- [ ] Stretch: proxy mode, with seeking still working.

**Docs:** FastAPI [Path Parameters](https://fastapi.tiangolo.com/tutorial/path-params/) · FastAPI [Custom Response — RedirectResponse](https://fastapi.tiangolo.com/advanced/custom-response/#redirectresponse) · FastAPI [Handling Errors](https://fastapi.tiangolo.com/tutorial/handling-errors/) · [`asyncio.to_thread`](https://docs.python.org/3/library/asyncio-task.html#asyncio.to_thread) · yt-dlp [embedding it in Python](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp) · Python [`base64`](https://docs.python.org/3/library/base64.html)

---

## MUS-3 · Merge and dedupe listings into songs

**Why:** the same recording comes back several times (both sources, and several releases inside JioSaavn). The app should show each song once and play its best version.

**`/search` returns songs instead of a flat list:**

```json
{
  "query": "blinding lights",
  "songs": [
    {
      "title": "Blinding Lights",
      "artists": ["The Weeknd"],
      "duration": 200,
      "best": {"source": "jiosaavn", "id": "fW-Mxsnu", "...": "..."},
      "listings": [ {"source": "jiosaavn", "id": "fW-Mxsnu", "...": "..."}, {"source": "ytmusic", "id": "J7p4bzqLvCw", "...": "..."} ]
    }
  ],
  "sources": [ "...same as MUS-1..." ]
}
```

**The logic (agreed 2 Oct 2026):**

1. **`normalise(text)`**: lowercase, remove accents (`ROSALÍA` → `rosalia`), punctuation → space, collapse spaces. Keep the words inside brackets.
2. **`same_recording(a, b)`** is true when all three hold:
   - **Titles equal after normalising**, brackets included. Not fuzzy: `token_set_ratio("blinding lights", "blinding lights (major lazer remix)")` is **100**, which would merge a remix into the original (they are 198 s vs 200 s with the same artist, so duration and artist cannot catch it). A missed merge shows a duplicate row; a wrong merge plays the wrong song. Version 1 accepts duplicates.
   - **At least one artist matches**, each pair compared fuzzily after normalising (`Mithoon, Arijit Singh` vs `Arijit Singh`; `Pritam` vs `Pritam Chakraborty`). You pick the score and justify it.
   - **Durations within 5 s** (changed from 3 s on 2 Oct after a live search split Blinding Lights into a 204 s group and a 200 s group). Different edits seen so far are further apart (Rosalía remix 206 vs 217).
   - (ISRC rule, for when a source provides one: equal ISRC → same, different ISRC → different. Neither current source has ISRC.)
3. **Grouping:** walk the listings **alternating between sources** (JioSaavn #1, YouTube Music #1, JioSaavn #2, ...). Each listing joins the first group whose **first listing** it matches, otherwise it starts a new group. Comparing only against each group's first listing stops chains (200 ↔ 202 ↔ 204). Groups come out roughly in rank order, because the first listing of each group is its best-ranked one.
4. **Order the songs by Reciprocal Rank Fusion** (added 2 Oct): each listing is a vote worth `1 / (60 + its position in its source)`. Interleaving alone let one source's junk take positions 2, 4, 6 while the other source's copies of the top song used up its turns.
5. **`best` listing in each group**, in this order: source audio quality (jiosaavn 320 kbps before ytmusic ~133 kbps; JioSaavn URLs also do not expire) → higher popularity **within the same source only** (38 million on JioSaavn and 3.6 billion on YouTube Music are not comparable) → duration closest to the group's median. The song's `title`, `artists`, `duration` come from `best`. All listings stay as fallbacks.

**Acceptance checks**

- [ ] `normalise("ROSALÍA")` == `"rosalia"`.
- [ ] "blinding lights": The Weeknd's JioSaavn 200 s listing and YouTube Music 201–202 s listing are **one** song, and `best` is the JioSaavn one.
- [ ] *Blinding Lights (Major Lazer Remix)* (198 s, The Weeknd) is **not** merged into the original (200 s, The Weeknd).
- [ ] Loi's cover is a **separate** song.
- [ ] "tum hi ho": JioSaavn's *Tum Hi Ho* (Mithoon, Arijit Singh, 262 s) and YouTube Music's *Tum Hi Ho* (Arijit Singh, 262 s) are **one** song (the artist-subset rule).
- [ ] Known and accepted for now: *Tum Hi Ho (From "Aashiqui 2")* stays a separate song (title differs in brackets).
- [ ] `/play/{best.source}/{best.id}` plays every song's `best`.
- [ ] `uv run pytest` passes: tests for each check above using `samples/*.json` and hand-made `Listing` pairs, no network.

**Docs:** Python [`unicodedata.normalize`](https://docs.python.org/3/library/unicodedata.html#unicodedata.normalize) (NFKD splits `í` into `i` + accent mark; [`unicodedata.combining`](https://docs.python.org/3/library/unicodedata.html#unicodedata.combining) tells you which characters are marks) · [RapidFuzz `fuzz`](https://rapidfuzz.github.io/RapidFuzz/Usage/fuzz.html) (for the artist comparison) · [`statistics.median`](https://docs.python.org/3/library/statistics.html#statistics.median) · [pytest Get Started](https://docs.pytest.org/en/stable/getting-started.html)

---

## MUS-4 · Your library

**Why:** search results vanish when you close the tab. A library is the first thing that is *yours* and persists.

**First design question (answer it in the PR description before writing code):** MUS-3 builds songs fresh on every search, so a song has **no ID**. To like a song today and find it tomorrow it needs one that does not change. Candidates: the `best` listing's `source:id`; an ID of your own with all known listings attached; a hash of normalised title + artists + duration. What happens to each when a song is later found on a new source?

**Build**
- PostgreSQL on this Mac (Claude sets up the install; you write the tables).
- Tables for songs, their listings, likes, and play events (play, skip with the second it happened, finish).
- `POST /library/{song_id}` (like), `DELETE /library/{song_id}` (unlike), `GET /library`, `POST /events`.

**Acceptance checks**
- [ ] Like *Blinding Lights*, stop and restart the server, `GET /library` still has it.
- [ ] Liking the same song from a second search (different listing order) does not create a duplicate.
- [ ] A skip at 12 s and a finish are both stored and can be counted per song.
- [ ] pytest against a separate test database.

**Docs:** [PostgreSQL tutorial](https://www.postgresql.org/docs/current/tutorial.html) (chapters 2–3) · [psycopg 3](https://www.psycopg.org/psycopg3/docs/basic/usage.html) (async: [AsyncConnection](https://www.psycopg.org/psycopg3/docs/advanced/async.html))

---

## MUS-5 · Spotify import (moved up: solves cold start)

Log in with Spotify (OAuth, the standard "allow this app to access your account" flow), page through your liked songs and playlists, and add each track to your library: Spotify gives **ISRCs**, so resolve each track to a playable listing by searching your sources and matching with MUS-3's `same_recording`. Your taste exists on day one instead of an empty library.

---

## MUS-6 · The app v1

Search, results (MUS-3 songs), tap to play, next/previous, like. Platform decided at the start of the ticket. You have never written Swift, Kotlin or Flutter: Claude sets up the project and explains every piece; you write the screens.

---

## MUS-7 · Shuffle

Fisher–Yates first (true random), then Spotify's 2014 approach: spread each artist's songs across the playlist with some jitter, because true random clumps and feels broken.

---

## MUS-8 · Autoplay v1

`GET /next?after=<song_id>`. Candidates: YouTube Music radio (verified 2 Oct: `youtubei/v1/next` with `playlistId=RDAMVM<videoId>` returns 50 songs) plus your library. **Your own re-ranking:** push down songs you skipped in the first 30 s, push up artists you finish or like, no repeats within the last hour, no artist three times in a row. Pre-resolve the next song's audio URL so there is no gap. Metric from now on: **skip rate in the first 30 s**.

---

## MUS-9 · Search your library

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

## MUS-10 · Caching

Server cache for search results (minutes), resolved `/play` URLs (until their `expire=`), and anything slow to compute. Measure first: time the same search twice before and after. Caching also protects you from being rate-limited by YouTube and JioSaavn.

---

## MUS-11 · Reach it from your phone

YouTube audio URLs only work from the IP that requested them, so redirect mode fails once the phone is on mobile data. Build **proxy mode** for `/play` (with HTTP Range requests so seeking still works), and put your Mac and phone on one private network with Tailscale.

---

## MUS-12 · Audio embeddings

A background job computes a "sounds like" vector for every song you play (a CLAP-style model, run locally) and stores it in pgvector. Works for any song, no crowd needed.

---

## MUS-13 · Discovery (explore / exploit)

A bandit (start with Thompson sampling) decides when to slip in a song that is new to you, chosen from songs that sound like ones you finish, and learns from whether you skip it. Reference: Spotify's BaRT (2018).

---

## MUS-14 · Your own collaborative filtering

Train ALS (`implicit`) on ListenBrainz's open listening data (~1 billion listens, CC0), map its MusicBrainz IDs to your songs, and A/B it against YouTube radio in autoplay using your skip rate. Expect thin coverage of Indian music in ListenBrainz (unverified): measure it first.

---

## Later, only if needed

- Titles that differ only in brackets (`Tum Hi Ho` vs `Tum Hi Ho (From "Aashiqui 2")`): send just those pairs to an LLM (local `gemma4:12b` parsed 43/45 real titles correctly, 2 Oct 2026, ~2.7 s per title, so background + cache only). Phonetic, semantic and their harmonic mean all failed to separate these from remixes on the same day.
- Search eval set (30 queries + expected top song) before changing catalog ranking: on 2 Oct, JioSaavn's own #1 was right for 7/7 song queries.
- Query intent (song / artist / lyrics): artist searches are where both sources are weak. Never score query-vs-title without an `intent = lyrics` exception.
- Audio fingerprinting (AcoustID) in the background after first play: certain same-recording answers.
- The app, offline downloads, recommendations (ListenBrainz + history), Spotify import (brings ISRCs), Jam, Blend.
