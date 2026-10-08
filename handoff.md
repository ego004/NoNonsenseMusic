# Handoff · NoNonsenseMusic

As of 8 Oct 2026, evening. For a Claude session that continues building while the owner is away from the Mac session
that wrote this. Read this, then `TICKETS.md` › **NOW** (the open list, in build order), then `docs/` where you need the
detail of a file.

**If your checkout is older than 8 Oct, reset it first.** History on `main` was rewritten on 8 Oct (a personal detail
removed from an old commit); old clones hold commits that no longer exist:

```bash
git fetch origin && git reset --hard origin/main
```

---

## 1. The map

| Part | Where | State, 8 Oct |
|---|---|---|
| Server (FastAPI, PostgreSQL 18, Python 3.13, uv) | `backend/` | Accounts, per-user library, shared playlists, members, device names, link page. **217 tests pass** |
| Mac app (SwiftUI, macOS 26, Liquid Glass) | `mac/` | Signs in; looks YouTube links up itself; opens playlist links. Self-tests pass |
| Flutter app (Windows, Android; also builds for macOS) | `app/` | Signs in; looks YouTube links up itself; Settings partly matched to the Mac. **21 tests + the integration test pass** |
| CI | `.github/workflows/` | Builds the Mac app, the Windows app, and Flutter for macOS and Android on every push to `main` |
| The plan | `TICKETS.md` › NOW | Every open ask, in order. **Work from it** and tick items there as they land |

Everything is on `main`. The owner's own database is migrated to accounts; their Mac runs the app from `main`.

---

## 2. Rules (from the owner; they hold everywhere)

- **The repo is public.** Before every push (docs and tickets too), scan the diff and the commit messages:
  `git diff origin/main..HEAD | grep -i -E "<the owner's names, school, employer, email domain, home IP prefix>|/Users/|googlevideo"`.
  You do not know the owner's personal details, and must not learn them from the repo's history: scan for `/Users/`,
  `@gmail`, `googlevideo` (stream URLs), and anything that looks like a real name, email or IP. Example names in code
  and tests: **Alex, Sam, Kai**. Never commit stream URLs, yt-dlp dumps, `.env` contents, real lyrics, or IP addresses.
- **Lightest is the default:** ~0% CPU idle, ~1% playing, measured in Release. A costly feature is a setting, off by
  default, that shows its measured cost.
- **Apple design language** on the Mac (Fluent-like on Windows): no narrating captions under controls ("Sharing again
  changes…" was removed on 8 Oct); short, plain text; Apple's patterns (large titles, sheets, popovers).
- **Tests are lean:** one per behaviour, each must fail on the old code. **Show evidence** in your reply (what you ran,
  what came back); say plainly what you could not run.
- **Comments say why, with a date.** No `dart format` over whole files: the project's lines run to ~120 characters and
  the formatter rewrites everything (it did on 8 Oct; reverted).
- **Backend:** name every backend file you change in your reply. **Recovery codes, rate limiting and the deploy are built
  together with the owner: do not build them alone.**
- **Tests never touch the owner's library:** database `music_test`, test server on port 8765 (or 8766), never 8000.
  Never edit `backend/.env`. Never type or ask for the owner's password.
- Git: a branch per change, tests pass, merge into `main`, push (the owner allows that for this work).

---

## 3. Running and checking things

| What | Command | Needs |
|---|---|---|
| Backend tests | `cd backend && uv run pytest -q` → 217 passed, 1 xfailed | PostgreSQL with a `music_test` database |
| A test server | `cd backend && DATABASE_URL=postgresql:///music_test uv run fastapi run src/music_backend/main.py --port 8765 --host 127.0.0.1` | the same |
| Flutter tests | `cd app && flutter test --dart-define=SERVER=http://127.0.0.1:8765` → 21 passed, 1 skipped | the test server; without it the server tests skip themselves |
| Flutter, real YouTube | `flutter test test/youtube_test.dart --dart-define=YOUTUBE=1` | the internet |
| Flutter, the whole app in a window | `flutter test integration_test/app_test.dart -d macos --dart-define=SERVER=http://127.0.0.1:8765` | macOS; it signs up, plays (a YouTube song too), opens lyrics, a playlist, every Settings section |
| Mac self-tests | `mac/Scripts/selftest.sh NN_SELFTEST_AUTH=1` (accounts, sharing, links, titles), `NN_SELFTEST_YOUTUBE=1` (a YouTube song looked up and played by the app) | macOS; `NN_TEST_PORT=8766` if 8765 is busy |
| Mac Release build | `cd mac && xcodegen && xcodebuild -project NoNonsense.xcodeproj -scheme NoNonsense -configuration Release -derivedDataPath build build` | macOS, Xcode |

If your machine lacks PostgreSQL or macOS, run what you can, let CI build the rest, and **say which checks you could
not run**. Never claim a check you did not run.

---

## 4. How the 8 Oct changes work (what you build on)

**Accounts.** Opaque session tokens (SHA-256 stored), Argon2id passwords, 30-day sliding sessions, expired ones cleaned
every 6 h. Every route needs `Authorization: Bearer <token>` except `/health`, `/auth/signup`, `/auth/signin` and the
link page `/p/{id}`. 401 → the apps show sign-in again. Device names: chosen at sign-in (the computer's name as the
starting value, shown before it is sent), renamed with `PATCH /auth/me/device`.

**Playlists and sharing.** Owner / editor / viewer, plus a `public` flag; one access check (`library._require`). A
private playlist you cannot see is 404; a role too low is 403. `GET /playlists/{id}/members`: the owner first, then
members (for the owner and members only). Shared links: `<server>/p/<id>` is an open page that hands over to
`nononsense://playlist/<id>`; the Mac app registers that scheme (its Debug build answers `nononsense-debug` instead, so
self-tests never catch the owner's links).

**YouTube.** A YouTube link carries the IP that asked for it, signed (`ip` is in its `sparams`): a link the server
fetches plays only on the server's network. So **the apps look YouTube links up themselves** (`mac/…/YouTubeLookup.swift`,
`app/lib/core/youtube.dart`): an anonymous visitor id from youtube.com (memory only), then one POST to
`youtubei/v1/player` as the **visionOS** client, the one yt-dlp uses (no JavaScript, no PO token); AAC, itag 140. The
Android client gave only the first 1 MB of music tracks (403 after). The server's `/play` (yt-dlp) is the fallback. When
YouTube breaks the visionOS client, copy the new values from yt-dlp's `yt_dlp/extractor/youtube/_base.py` ('visionos').
Apple's player misreads these files' length (about twice): both apps cap the length at the listed one + 1 s, and end
the song there.

**The apps never hand the session token to an audio player**: they ask `/play` themselves without following the
redirect and give the player the `Location`.

---

## 5. What to build, in order (TICKETS.md › NOW has the list; here are the hints)

1. **The name "NoNonsenseMusic"** wherever the app's name shows. Mac: `mac/project.yml` (`CFBundleDisplayName`, and
   `CFBundleName`/`PRODUCT_NAME` if the menu bar should say it; the Keychain item and the preferences domain
   `app.nononsense.music` stay). Flutter: `app/windows/runner/main.cpp` (window title), `app/windows/runner/Runner.rc`
   (product name), `app/android/app/src/main/AndroidManifest.xml` (`android:label`), `app/macos/Runner/Configs/AppInfo.xcconfig`
   (`PRODUCT_NAME`), and `MaterialApp(title:)` in `app/lib/main.dart`.
2. **Mac, full screen: the top bar turns black.** The main window is made see-through (`ClearWindow`, `WindowSurface`
   in `Views/Components.swift`); in full screen macOS draws the toolbar area itself and shows black there. Look at how
   the toolbar background is hidden (`RootView.swift`, `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`) and
   what a full-screen window needs (it cannot be see-through to the desktop: give the full-screen case the window
   colour, or the same blur as the content). Check it in a real full-screen window.
3. **The session token in a file, not the Keychain** (the owner's choice). Why: the app is ad-hoc signed, every build is
   a "new app" to the Keychain, so it asks for the login password after each build. The professional fix is the
   Keychain plus a stable signature (an Apple Developer ID); without one, a file only the user's account can read is
   what most open-source apps do. Mac: `~/Library/Application Support/<bundle id>/session` with permissions 0600, written
   atomically; move an existing Keychain token into it once, then delete the Keychain item (`Services/Account.swift`).
   Flutter on macOS: the same, replacing `flutter_secure_storage` there; keep it on Windows (DPAPI) and Android
   (Keystore), which never prompt.
4. **Genius notes, experimental** (off by default; notes only, never Genius's lyrics text). Server: a new source next to
   `services/lyrics.py`, cached in the database for everyone like lyrics. First the website's own API (no token;
   researched 8 Oct: `https://genius.com/api/search/song?q=…` then `https://genius.com/api/referents?song_id=…&per_page=50&text_format=plain`,
   about 3.4 s and 123 KB per song, 11 notes for one test song); the official API (`api.genius.com`, same data) with
   `GENIUS_ACCESS_TOKEN` from `backend/.env` as the fallback when the website's breaks (the owner adds the token; the
   official API without it answers 401). Apps: a faint accent underline under lyric lines that have a note (match each
   note's fragment to the lines, case and punctuation ignored); a click opens a glass popover with the note, credited
   "Genius"; an "About" card in Now Playing (description, produced by, samples). Settings › Lyrics › "Genius notes".
5. **Flutter opens playlist links**: the `app_links` package; register `nononsense` on macOS (Info.plist), Android
   (intent filter) and Windows (registry under `HKCU\Software\Classes\nononsense`, and forwarding a link to the app
   already open, per `app_links`' Windows notes).
6. **Discord in Flutter**: Rich Presence over Discord's local IPC (Windows: the pipe `\\.\pipe\discord-ipc-0`; macOS
   and Linux: the socket `discord-ipc-0` in the temp folder). `mac/NoNonsense/Services/Presence.swift` is the model
   (handshake, frames, the built-in application id, what is shared, the settings).
7. **Footprint in Flutter** (this app's CPU and memory; the Mac's `Services/Footprint.swift` is the model), and card size.
8. Footprint reads up to 11% on the Mac with its page open: measure (low priority).

**Not yours:** recovery codes, rate limiting and the deploy on Render are built with the owner. `playlist_saves` waits on
the owner's decision.

---

## 6. Things learned the hard way (8 Oct)

- The Mac self-tests' pictures cannot draw Liquid Glass or `List` contents: a glass button draws as plain text there. Trust
  the checks; judge looks on a real screen.
- The Mac self-test app shares preferences with the owner's app: a test that changes a setting must put it back.
- Flutter `bool.fromEnvironment('X')` is true only for the word `true`; use `String.fromEnvironment('X') != ''`.
- A Flutter test finder with `.first` throws when nothing is built yet; `scrollUntilVisible` needs the plain finder.
- The Flutter integration test needs its window in front; it stalls if another app is full screen.
- `player.position` on the Mac is the clock's starting point; the playing position is `livePosition`.
- psycopg: a connection block commits on normal exit and rolls back on an exception; raise after the block when a write
  must stay (the expired-session delete).
