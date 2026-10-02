# Tickets

How this works:

1. Pick the next ticket. Make a branch: `git switch -c mus-1` (one branch per ticket).
2. Read the docs listed, build it, run the acceptance checks yourself.
3. Tell Claude "MUS-1 ready". Claude runs every acceptance check and reviews the code: what is wrong + a failing case, never the fix.
4. When everything passes: commit, merge into `main`, demo it to yourself, move on.

Stuck for more than 30 minutes? Bring: what you tried, what you expected, what happened.

| Ticket | What you can show at the end | Size |
|---|---|---|
| MUS-1 | Break a source on purpose, search still works and says which source failed | S (1–2 h) |
| MUS-2 | Open a link in Chrome and a song plays from **your** API | L (4–6 h) |
| MUS-3 | Same song from two sources shows up as one song with two listings | L (4–6 h) |
| MUS-4 | "blinding lights" puts The Weeknd at #1, every time, with a score you can explain | M (3–4 h) |

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

## MUS-3 · Pool listings into songs

**Why:** the same recording shows up from both sources. The app should show one song, with every place it can be played from.

**`/search` returns songs instead of a flat list:**

```json
{
  "query": "blinding lights",
  "songs": [
    {
      "title": "Blinding Lights",
      "artists": ["The Weeknd"],
      "duration": 200,
      "listings": [ {"source": "jiosaavn", "id": "fW-Mxsnu", ...}, {"source": "ytmusic", "id": "J7p4bzqLvCw", ...} ]
    }
  ],
  "sources": { ...same as MUS-1... }
}
```

**Version 1 rule (hand-written, no ML yet):** two listings are the same recording when the titles are similar, the artists overlap (order does not matter: `Mithoon, Arijit Singh` = `Arijit Singh, Mithoon`), and the durations are close. **You choose the thresholds and justify each one.**

**Acceptance checks**

- [ ] "blinding lights": The Weeknd's JioSaavn *After Hours* listing (200 s) and his YouTube Music listing (201–202 s) are in the **same** song.
- [ ] Loi's cover of Blinding Lights is a **different** song.
- [ ] "tum hi ho": JioSaavn's `Tum Hi Ho (From "Aashiqui 2")` (261 s) and YouTube Music's `Tum Hi Ho` (262 s), both Arijit Singh, are the **same** song, even though the titles differ.
- [ ] Tests with `pytest` that load `samples/*.json` and check the cases above, with no network calls. `uv run pytest` passes.

**Docs:** [RapidFuzz](https://rapidfuzz.github.io/RapidFuzz/Usage/fuzz.html) (compare `ratio`, `partial_ratio`, `token_set_ratio` on the tum hi ho titles before choosing) · [pytest Get Started](https://docs.pytest.org/en/stable/getting-started.html) · reference answer key, read *after* yours works: spotDL [`matching.py`](https://spotdl.github.io/spotify-downloader/reference/utils/matching/)

---

## MUS-4 · Rank the songs

**Why:** both sources return junk mixed in (Starboy for "blinding lights", 20 random songs for nonsense). Your order has to be better than either source's.

**Each song gets a score built from parts you can see:**

```json
{ "title": "Blinding Lights", "score": 0.91,
  "score_parts": { "relevance": 0.98, "popularity": 0.88, "on_both_sources": 1.0 },
  "best": {"source": "jiosaavn", "id": "fW-Mxsnu"} }
```

**Things to know before designing it:**

- Popularity is on different scales per source (Blinding Lights: 38 million on JioSaavn, 3.6 **billion** on YouTube Music). Compare a listing only against its own source.
- `best` is the listing `/play` should use. Prefer higher audio quality.

**Acceptance checks**

- [ ] "blinding lights" → #1 is The Weeknd.
- [ ] "blinding lights" → *Starboy* is not in the top 5.
- [ ] "tum hi ho" → #1 is Arijit Singh's.
- [ ] "zzqxjvw nonsense 123" → every score is below your "no good match" threshold, and the response says no good match was found.
- [ ] Each song has `best`, and `/play/{best.source}/{best.id}` plays it.
- [ ] pytest cases for the first four checks.

**Docs:** [`math.log10`](https://docs.python.org/3/library/math.html#math.log10) (why do raw view counts make a bad score?) · Python [`sorted` with `key`](https://docs.python.org/3/howto/sorting.html)

---

## Later (not yet)

- MUS-5: minimal web player, split ticket. Claude builds one page served by FastAPI (search box, ranked results, a player, next/previous). You build the backend it needs: `POST /events` that records every play, skip (and at what second) and finish, stored in PostgreSQL. This is when daily use starts producing the data that MUS-7 and learned ranking train on.
- MUS-6: likes and playlists in PostgreSQL
- MUS-7: recommendations v1 (ListenBrainz similar songs + your play history)
- MUS-8: import your Spotify playlists
- MUS-9: Jam
- Later: Flutter app for the phone (background playback, lock screen controls)
