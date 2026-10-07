# Handoff · NoNonsense Music

As of 7 Oct 2026, late. Written for two readers: **you** (the owner), and **a Claude session on your Mac** that
picks up from the cloud session that wrote this. The cloud session could not compile Swift (Linux, no Xcode), so it
wrote app code blind and you built it; the Mac session can build, run, measure and test it directly. Read this
first, then `TICKETS.md` (the plan), `docs/mac-app.md` and `docs/backend.md` (how every file works).

---

## 1. What this is, and the rules we work by

**NoNonsense Music:** a macOS music player (SwiftUI, macOS 26, Liquid Glass) over your own FastAPI server, which
searches YouTube Music and JioSaavn, groups the copies of one song, caches audio links, and keeps your library
(likes, plays, playlists) in PostgreSQL.

**Roles.** You are learning backend development: **you write the backend fixes and features**; Claude reviews them,
explains, and writes the tests. **Claude owns the Swift app** (and, next, the Windows app). You don't vibecode:
Claude teaches the right way (why, not just what), gives you tasks with "where to look", and you bring back
"BUG-n ready".

**The rules (from you, and they hold everywhere):**
- **Truly no nonsense:** ~0% CPU idle, ~1% while playing, measured in the **Release** build (Debug is unoptimised).
  Anything that costs more is a setting that says what it costs.
- **Apple design language:** Liquid Glass, haptics, Apple Music as the reference. Add to it only **after asking**.
- **Tests are lean:** one test per behaviour or code path, each one must fail on the old code; no duplicates, no
  narration. The suite will grow past 1000; every test earns its place.
- **Comments say why, with a date** ("…was 30–40% of a core, measured 7 Oct"). Docs change in the same commit as code.
- **Commands for you to paste have no `#` comments in them** (zsh treats `#` as text unless
  `setopt interactivecomments`), and use full paths when the folder matters.

---

## 2. The repo

| Path | What |
|---|---|
| `backend/` | FastAPI server (Python 3.13, uv, psycopg 3, PostgreSQL 18). `src/music_backend/`: `main.py` (routes), `cache.py` (audio-link cache, single-flight, back-off, prefetch, lyrics cache), `library.py` (likes, plays, playlists), `sources/` (`ytmusic.py`, `jiosaavn.py`), `matching.py` (grouping copies), `lyrics.py`, `settings.py` (reads `backend/.env`; an unknown key stops the server). `schema.sql`. `tests/` (182 pass). |
| `mac/` | The app. `NoNonsense/` (Views, Services, Models, Debug/SelfTest), `project.yml` (XcodeGen: `cd mac && xcodegen`), `Scripts/selftest.sh`, `Scripts/perf.sh`. |
| `docs/` | `README.md` (setup), `backend.md` and `mac-app.md` (every file, every function, and why). |
| `TICKETS.md` | The plan: tickets MUS-1…20, BUG-1…7, the APP table (every app change, with dates). |
| `handoff.md` | This file. |

**Running things (on the Mac):**
- Backend tests: `cd ~/projects/music/backend && uv run pytest -q` → **182 passed, 1 xfailed**. PostgreSQL must be
  running (`brew services start postgresql@18`); tests use the `music_test` database, never `music`.
- The app (daily use): `cd ~/projects/music/mac && xcodebuild -project NoNonsense.xcodeproj -scheme NoNonsense -configuration Release -derivedDataPath build build 2>&1 | grep -E "error:|BUILD"`, then `open build/Build/Products/Release/NoNonsense.app`.
- **The app starts its own server** (`ServerLauncher`): `fastapi run` from `~/projects/music/backend` on port 8000,
  i.e. **whatever branch is checked out**. A server you started yourself is left alone.
- Self-tests (Debug build): `mac/Scripts/selftest.sh NN_SELFTEST_QUEUE=1` (any `NN_SELFTEST_*`; list in
  `docs/mac-app.md › Debug/SelfTest.swift`). They run against a test server on 8765 with `music_test`, and refuse a
  port already in use.
- CPU per screen: `mac/Scripts/perf.sh` (medians of `top`, per phase).

**Git, as we do it:** one branch per change (`bug-3-…`, `fix-…`), commit, `git push -u origin HEAD`, test, then
`git switch main && git merge --no-edit <branch> && git push`. Your prompt shows the branch (zsh `vcs_info`).

---

## 3. Where things stand (main, 7 Oct late)

Everything below is **on main**. Items marked ⚠ were written in the cloud and **have not been compiled or tried on
a Mac yet**: build main and check them first (section 6 has the checklist).

### The app: what changed, newest first

| Change | Why | Status |
|---|---|---|
| Pinch anywhere on the player bar opens Now Playing (`.contentShape(shape)` on the bar) | With Liquid Glass and Fill 0, the bar's empty parts had no hit area: the pinch only worked over the progress line, and clicks between controls fell through to the song row under the bar | ⚠ |
| **Up Next reorder = `ReorderableStack`** (Components): the row lifts and follows the pointer, the others slide aside, it settles where you let go, a light haptic tick per place passed | SwiftUI `List` + `onMove` never worked there (section 4.1) | ⚠ not yet confirmed working |
| ← → seek 5 s (`Player.seek(by:)`, in the key monitor; not while typing or on a focused slider) | You asked for it | built |
| The bar's click-to-seek lands where you click | The `DragGesture` sat after `.position`, so x counted from the bar's left edge (elapsed time label included): ~44 pt off | built |
| Home's page never rubber-bands; shelves move sideways only (`ScrollElasticity`, Components: reaches the AppKit `NSScrollView` under a SwiftUI ScrollView) | A swipe on a shelf moved the whole page "like a website"; `.scrollBounceBehavior(.basedOnSize)` only helped while the page fitted the window | built; you said the remaining clunkiness is elsewhere (4.3) |
| Robustness audit fixes (every claim in the docs traced to code): hidden Lyrics no longer sits on top of Up Next; Play Next songs survive their playlist syncing (`Entry.queued`); "From “Gym”" survives a drag (`PlayQueue.origin`); messages and the connection banner show over Now Playing; ⌘F from any screen; ⌘-arrows go to a text field while typing; Controls greyed out with nothing playing; no swipe-skips under Now Playing | Audit, 7 Oct | built |
| A song ends at its listed length + 1 s (`forwardPlaybackEndTime`); the bar uses the playing copy's real length | Some YouTube audio runs on in silence (Redbone 1:42 → silence past 1:48; No Role Modelz) and the queue never moved on | built; confirm on No Role Modelz |
| Earlier on 7 Oct, the CPU work: the progress line, lyrics, artwork crossfade and backdrop moved to Core Animation (render server, no app CPU per frame); Now Playing in its own host, faded by CA, kept alive; hover redraws only the row under the pointer; Observation assigns only on change; frame-rate caps removed (they made scrolling feel worse) | Lyrics were 30–40% of a core; Home 0–0.9%, Now Playing 0.6–0.9%, Lyrics ~1% after (Release, your measurements) | built |

### The backend: what changed

| Ticket | What | By |
|---|---|---|
| BUG-1 | `is_expired` reads `?expire=`; no expiry = fresh (your decision) | you; tests Claude |
| BUG-2 | Back-off counts blocking *episodes*: a block during a pause adds no strike; a success during a pause doesn't reset | you; tests Claude |
| BUG-3 | JioSaavn's bad replies are clean errors (429 → `SourceBlocked` → back-off; non-200 / HTML / garbled → `SourceUnavailable` 502; no songs / no URL → `SongNotFound` 404) | you; tests Claude |
| BUG-4 | One odd JioSaavn search row is skipped with a warning, not the whole search; `to_listing` stays strict | you; tests Claude |
| BUG-6 | Playlist writes take turns in the database (`FOR UPDATE` per playlist; `pg_advisory_xact_lock` for the playlist list); two moves into one slot no longer tie; a stored tie is repaired at the first move between it | your design, Claude's code |
| STRIP | One `single_flight` for both caches; a table hit is one `UPDATE … RETURNING`; prefetch's check marks nothing; FastAPI without its cloud CLI; shared `conftest.py` | Claude |
| warm-up | The unused `jiosaavn_cache_expiry_threshold` setting removed | you |

**Left for you (backend):** BUG-5 (an overloaded LRCLIB's 503 is stored as "no lyrics" for 7 days) and BUG-7
(`/recent?limit=-1` → 500). Each is written up in the bug guide with where to look and a snippet that shows it:
**[NoNonsense Backend Bug Guide](https://claude.ai/code/artifact/01850f75-3614-48c9-8835-6b43b08d6f8c)**. Then MUS-15
onwards (TICKETS order).

**In progress (cloud):** a pass over the 182 backend tests to cut redundant ones without losing coverage
(measured line + branch coverage before/after, mutation checks). It lands as its own commit.

---

## 4. Open problems, with what we know

### 4.1 Up Next reorder (the long one)
What happened, in order:
1. **Hidden Lyrics on top.** Up Next and Lyrics share one glass (both kept alive, faded); Lyrics sat above, and its
   AppKit `LyricLinesView` caught drags and scrolls. Fixed: the shown panel has the higher `zIndex`; hidden lines
   answer no hit test.
2. **A gesture on each row.** `.onTapGesture(count: 2)` on a `List` row takes the mouse-down the list needs to start
   a drag (known SwiftUI issue). Moved double-click to the list's own `contextMenu(forSelectionType:primaryAction:)`:
   **the drag then started, but the drop never called `onMove`** (the row went back). Apple's forums report the same
   for a List in a popover; ours lives in Now Playing's separate `NSHostingView` (`NowPlayingContainer`, RootView).
3. **`ReorderableStack`** (now): no `List`, no AppKit drag and drop; a `LazyVStack` and one `DragGesture` per row
   (`coordinateSpace: .global`). Double-click and the right-click menu are back on the rows (`UpNextRow`).

**You said "still not fixed".** First check which build ran: with the new code a click on a row does **not**
highlight it (the `primaryAction` version did), and dragging lifts the row. `git log --oneline -1` in the repo
should be at or past "Up Next: drag a row and the others make room". If it really is the new build and fails:
- Does the drag start at all? Add a `print` in `ReorderableStack.drag … onChanged`.
- The row's own `.onTapGesture(count: 2)` (child) may win over the stack's `.gesture(drag)` (parent): try
  `.highPriorityGesture(drag(...))` in `ReorderableStack`, or move the double-click to
  `.simultaneousGesture(TapGesture(count: 2))`.
- Then add a self-test that sends real mouse-down / dragged / up events at a row (SelfTest already synthesises
  swipes), so this never regresses silently again.
- Not done yet: auto-scroll when dragging to the panel's top or bottom edge.

### 4.2 Playlist reorder (probably broken the same way)
Playlist rows are `SongRow`, which has `.onTapGesture(count: 2)`, inside a `List` with `.onMove`
(`Playlists.swift:63`). Same pattern as Up Next's step 2. Ask the owner whether dragging inside a playlist works; if
not, use `ReorderableStack` there too (rows of one height) or the list's `primaryAction` (it's in the main window,
not a separate host, so `onMove` may work there once the row gesture is gone).

### 4.3 Scrolling feels "clunky / slow"
Your latest observation: **scrolling Liked Songs with the trackpad or wheel feels slow; dragging the scroll bar
(the thumb on the right) feels fast.** Ask first whether "slow" means stuttery (dropped frames) or that it moves
less far. Then, in order of suspicion:
1. **`Player.installSwipeMonitor`**: a local `NSEvent` monitor for **every** `scrollWheel` event in the app (it
   detects a sideways swipe over the player bar). It runs on the main thread for each event and may stop AppKit's
   *responsive scrolling* (scrolling handled off the main thread). Dragging the scroll bar doesn't go through it,
   which fits your observation. **Experiment:** comment out the `installSwipeMonitor()` call, build Release, compare.
   If it's the cause, the swipe must move to a view scoped to the bar (an `NSView` over the bar overriding
   `scrollWheel(with:)`, forwarding vertical scrolls), not a global monitor.
2. Main-thread work per scrolled row (`SongRow`: hover tracking, menus, artwork). Instruments › Time Profiler and
   Animation Hitches while scrolling Liked Songs.
3. `.scrollEdgeEffectStyle(.soft, for: .top)` and the glass toolbar redrawing per frame (compare with it off).

Measure before and after each change, in Release.

### 4.4 Smaller, known
- Rare: like then unlike at once can stay liked; a slow playlist load can undo a drag made just before it lands;
  Settings › Server › Restart can freeze the window up to 2 s.
- From the audit, **not built (ask first):** Add to Queue (end of Up Next; starting a list drops queued songs);
  Download in Home's Liked Songs menu; Now Playing's volume ticks; refreshing the library when the server address
  changes; a server down at launch says so instead of "No liked songs yet".
- Check your own library once for ties left from before BUG-6 (they're repaired at the first move anyway):
  `psql music -c "SELECT playlist_id, position, count(*) FROM playlist_items GROUP BY 1, 2 HAVING count(*) > 1;"`

---

## 5. The vision: friends on Windows (then Android)

### What a friend needs, all three
| Piece | Today | Who |
|---|---|---|
| A Windows app | not started | Claude |
| A server their PC can reach | yours runs on your Mac, for you | you (backend) |
| Accounts (their own library; strangers kept out) | none | you (backend) |

### The app: Flutter (decided)
- **Why:** one codebase for Windows now and Android later; compiles to native code; draws nothing while idle.
  Considered: WinUI 3 (most Windows-native, but Windows only), Tauri (web view: memory, costly blur), Electron
  (heavy), Compose Multiplatform (JVM on desktop), .NET MAUI / React Native / Avalonia (rougher desktop or audio).
- **Performance on both, measured like the Mac:** ~0% idle, ~1% playing, a `perf.sh`-like script per platform; a
  screen that misses it doesn't ship. Flutter draws every animation frame itself (no Core Animation), so: the
  progress bar repaints once a second (not animated per frame), lyrics animate only on a line change, the backdrop
  is a still picture, nothing loops while idle.
- **Look (decided: b):** the Mac app's layout, behaviour, spacing and motion, 1:1, with **Windows' own materials**
  (Mica, Acrylic: drawn by Windows itself, free for the app; imitating Liquid Glass with Flutter's blur would re-blur
  every frame something moves behind it). **SF Symbols and SF Pro may only be used on Apple platforms:** Fluent icons
  and Segoe UI Variable on Windows. Haptics wait for Android (most PCs have none).
- **Pieces:** `media_kit` (audio, mpv), `flutter_acrylic` (materials), a Windows media-controls plugin (media keys,
  the volume overlay). The queue rules (PlayQueue: shuffle, repeat, Play Next, sync) are ported **with their
  self-test rules as Dart unit tests**, so both apps provably behave the same.
- **First milestone:** search, play, queue, Now Playing against the local server; a Windows build on every push.

### Building and shipping
- A Windows app is a **folder** (`nononsense.exe` + `flutter_windows.dll` + audio DLLs + `data/`); the exe alone won't
  run. Windows apps can only be built **on Windows**: GitHub Actions' Windows runners (free for a public repo) build,
  test and attach the zip on every push; a tag (`v0.1.0`) makes a GitHub Release.
- Shipping, in steps: a **zip** (unzip, run) → an **installer** (Inno Setup: Start menu, uninstaller) → later
  **signing** (unsigned apps get "Windows protected your PC": More info → Run anyway) via a certificate or the
  **Microsoft Store**, which signs for you and updates.
- Trying it: a friend, or Windows 11 in UTM on the Mac.

### The server for friends
Hosted FastAPI (your plan) is right, with two YouTube catches: **a YouTube link plays only from the IP that fetched
it** (measured, MUS-15), and **YouTube often bot-checks cloud servers**. Likely shape: the hosted server does search,
library, lyrics, accounts and JioSaavn; **each app resolves YouTube links itself**, from its own IP (in Flutter, e.g.
`youtube_explode_dart`, which breaks more often than yt-dlp and needs watching). **First, a one-evening test (you):**
today's server on a free host, 20 searches and plays. That decides it. (Bundling the server into each app was
weighed: no hosting and no YouTube IP problem, but Python + PostgreSQL in every install and a separate library per
friend.)

### Accounts
Only the tables that hold *your* things get a `user_id`: `likes`, `events`, `playlists` (items follow their
playlist); rules become per user (a like unique per user and song, a playlist name unique per user). Songs,
listings and both caches stay shared. Steps: a `users` table; a first **migration** (numbered SQL: add the column,
fill it with your new user id, make it required); one FastAPI dependency `current_user` that checks the sign-in
token (an identity provider: Google, or an email link; no passwords stored), passed to every library route, every
library query gets `WHERE user_id = %s`. One real design change: the prefetch queue ("a new list replaces what
waits") must become per user. BUG-6's list lock becomes the user's row lock. Later, PostgreSQL row-level security as
a safety net.

### Order
1. Now: the Mac session verifies and finishes the app items (section 6). You: BUG-5, BUG-7.
2. In parallel: you, the hosting test; Claude, the Flutter app's first milestone.
3. Then accounts (you), and YouTube resolution in the app if the test says so.
4. Then the first zip for friends.

---

## 6. For the Claude session on the Mac: start here

1. `cd ~/projects/music && git switch main && git pull`; `cd backend && uv sync && uv run pytest -q` (182 passed).
2. Build Release (section 2). Fix any compile error in the ⚠ commits first: they were written without a compiler.
3. Check, with the owner, in this order, and fix what fails:
   - Up Next: drag a row (it lifts, others make room, it stays); double-click plays; right-click menu (4.1).
   - Drag inside a playlist (4.2).
   - Pinch out anywhere on the player bar opens Now Playing; a click between the bar's controls does nothing.
   - Click the progress bar: it seeks to the click; ← → seek 5 s.
   - Home: the page doesn't move when swiping a shelf.
   - A song with a silent tail (No Role Modelz, Redbone) moves on at its listed length.
4. The scrolling investigation (4.3), measured in Release.
5. `mac/Scripts/selftest.sh NN_SELFTEST_QUEUE=1` (the queue rules, 4 new on 7 Oct).
6. Keep `docs/mac-app.md` and the APP table in `TICKETS.md` current in the same commits, and keep the owner learning:
   explain the why, give them the backend work, write lean tests.
