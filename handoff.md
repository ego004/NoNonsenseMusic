# Handoff · NoNonsense Music

As of 8 Oct 2026. Written for a Claude session that continues on **the apps** while the server work for accounts
is finished on a branch. Read this first, then `TICKETS.md` (the plan; the AUTH section has the design and why),
then `docs/backend.md`, `docs/mac-app.md`.

**If your checkout is older than 8 Oct, reset it first:** history on `main` was rewritten on 8 Oct (a personal
detail removed from an old commit). Old clones have commits that no longer exist:

```bash
git fetch origin && git reset --hard origin/main
```

---

## 1. The map

| Part | Where | State |
|---|---|---|
| Server (FastAPI, PostgreSQL 18) | `backend/` | Accounts, sessions, per-user library, shared playlists: **done on branch `auth-1`**, not on `main` |
| Mac app (SwiftUI, macOS 26) | `mac/` | Works against `main`'s server (no accounts). **Needs sign-in** before `auth-1` can merge |
| Windows / Android / Mac app (Flutter) | `app/` | Milestones 1–2 done (library, playing, under 1% CPU behind other windows). **Needs sign-in** too |
| Plan | `TICKETS.md` | Release 1 = AUTH-1…4, LIVE-1…3, FRIENDS-1, JAM-1 |

**Your job: sign-in in both apps (section 3), against `auth-1`.** The server side is finished and tested; the apps
are what blocks the merge. Branch from `auth-1` (`git switch -c app-auth origin/auth-1`), not from `main`.

**Roles.** The owner writes the backend; Claude reviews, explains and writes the tests. Claude owns the apps. Any app
code that relies on a backend contract, or any edit to a backend file, is named in that reply: the owner's design
wins.

**Rules that hold everywhere:**
- The repo is **public**. Before every push (docs and tickets too), scan the diff and commit messages for personal
  information. No real names as example data ("Alex", "Sam", "Kai" are the examples). No stream URLs, yt-dlp dumps,
  `.env` contents, real lyrics, or IP addresses in commits or logs.
- Lightest is the default: ~0% CPU idle, ~1% playing, measured in Release. A costly feature is a setting that
  shows its measured cost.
- Tests are lean: one per behaviour, each must fail on the old code.
- Comments say why, with a date. Commit and push only when the owner asks; merge to `main` only when the owner asks.
- Tests use the `music_test` database and port 8765, never `music` or 8000.

---

## 2. What `auth-1` changed on the server

Five commits on `auth-1` (`git log --oneline main..origin/auth-1`). `uv run pytest -q` in `backend/`:
**213 passed, 1 xfailed** (8 Oct).

### Accounts and sessions (AUTH-1)
- **Sign up is open to anyone:** username 3–32 characters (unique, case-insensitive), password 8–64.
- **Passwords:** Argon2id (`argon2-cffi`), hashed off the event loop.
- **Sessions are opaque tokens, not JWT:** `secrets.token_urlsafe(32)`; the server stores only its SHA-256. One row
  per signed-in device. 30 days, sliding (each use pushes the expiry, written at most once an hour). Sign-out
  deletes the row, so it ends at once.
- **Every request but three needs `Authorization: Bearer <token>`.** Missing, wrong, expired or signed-out token →
  **401** with `WWW-Authenticate: Bearer`. The open three: `GET /health`, `POST /auth/signup`, `POST /auth/signin`.
- Wrong password and unknown username answer the same 401 body, `"Wrong username or password"`, in the same time.

### Per-user library (AUTH-3)
- Likes, plays (events) and playlists belong to a user. `GET /liked`, `/recent`, `/playlists` answer **yours**.
- Songs, listings, the audio-link cache and the lyrics cache stay shared: computed once for everyone.
- `/prefetch` replaces **your** waiting list only; the workers take one song from each user in turn.

### Shared playlists (AUTH-3)
Each playlist has an owner, an optional list of members (`viewer` or `editor`), and a `public` flag.

| Who | Open, play | Add, remove, reorder songs | Rename, public, delete, invite, remove people |
|---|---|---|---|
| Owner | yes | yes | yes |
| Editor | yes | yes | no (403) |
| Viewer, or anyone signed in when `public` | yes | no (403) | no (403) |
| Anyone else, private | **404** (as if it did not exist) | 404 | 404 |

A member may remove themselves (leave). `GET /playlists` lists your own (in your order), then those shared with
you; a public playlist you are not a member of is **not** listed: it is opened by id (a link).

### The API the apps call (generated from the routes, 8 Oct)

| Route | Answer | Notes |
|---|---|---|
| `GET /health` | 200 | open |
| `POST /auth/signup` `{username, password, device_name?}` | **201** `{token, user: {id, username}}` | open. 409 taken, 422 bad length |
| `POST /auth/signin` `{username, password, device_name?}` | 200 `{token, user}` | open. 401 wrong |
| `GET /auth/me` | 200 `{id, username}` | check a stored token at launch |
| `POST /auth/signout` | 204 | ends this token only |
| `GET /search?q=` | 200 | |
| `GET /play/{source}/{source_id}[?serve_fresh=true]` | **307** to the audio URL | needs the token: see 3.2 |
| `POST /prefetch` `{listings}` | 202 | |
| `POST /liked` · `DELETE /liked/{song_id}` · `GET /liked` | `SongRef` · 204 · list | yours |
| `GET /recent?limit=` · `POST /events` | list · `SongRef` | yours |
| `POST /playlists` `{name}` | 201 `PlaylistMetadata` | 409 if **you** have that name |
| `GET /playlists` | `{playlists: [PlaylistMetadata]}` | each now has `public` and `role` |
| `GET /playlists/{id}` | `PlaylistItems` | has `public`, `role`; `liked` on items is the viewer's own |
| `PATCH /playlists/{id}` `{name?, public?}` | 200 `PlaylistMetadata` | owner only. Was rename (`{name}`) only; the apps' existing rename calls still work. `public` is new |
| `DELETE /playlists/{id}` | 204 | owner only |
| `POST /playlists/{id}/items` · `DELETE …/items/{item_id}` · `POST …/items/{item_id}/move` | 201 · 204 · 204 | editor or owner |
| `POST /playlists/{id}/move` | 204 | reorders **your** list (own playlists) |
| `PUT /playlists/{id}/members` `{username, role: viewer\|editor}` | 204 | **new**, owner. Same call again changes the role. 404 `"No account with that username"` |
| `DELETE /playlists/{id}/members/{user_id}` | 204 | **new**. Owner removes anyone; a member removes themselves |
| `POST /lyrics` | 200 | |

`PlaylistMetadata` = `{id, name, song_count, thumbnail, duration, public, role}`; `role` is
`"owner" | "editor" | "viewer"`.

**There is no route that lists a playlist's members yet.** The sharing screen can invite and change roles, but cannot
show who is on it. If the app needs that list, ask the owner first: it is a backend change, and the owner writes the
backend.

---

## 3. Your work: sign-in in both apps

### 3.1 Both apps

1. **Sign-in / sign-up screen** at launch when no token is stored. One screen, two buttons. Show the server's
   `detail` text on 401, 409 and 422 errors (it is written to be shown).
2. **Store the token in the platform's secure store**, not in preferences: the Keychain on macOS; on Flutter, the
   `flutter_secure_storage` package (Keychain on Apple, DPAPI-encrypted on Windows, the Android Keystore).
   `flutter_secure_storage` is a new dependency: say so when you add it.
3. **Send `Authorization: Bearer <token>` on every request.**
   - Mac: `API.swift` builds every `URLRequest` in `get`, `sendNoContent`, `send` (around line 181–210), plus
     `health` (line 37), `DELETE /liked` (line 113), and `Debug/SelfTest.swift:271`. One place should add the
     header.
   - Flutter: `lib/core/api.dart`, `_send` (around line 22).
4. **On 401 from any route** (expired, or signed out on another device): drop the token, show the sign-in screen.
   Not a "server unreachable" banner: the server answered.
5. **Launch:** with a stored token, call `GET /auth/me`. 200 → in; 401 → sign-in screen.
6. **Sign out** in Settings: `POST /auth/signout`, then delete the token.
7. **`device_name`** on sign-up and sign-in: the computer's name (it becomes the device list in AUTH-4).

### 3.2 Playing audio: do not give the token to the player

`/play` needs the token, and it answers 307 to the audio host (YouTube or JioSaavn). Today both apps hand the
`/play` URL straight to the player (`Player.swift:374` `AVPlayerItem(url:)`, `DownloadStore.swift:79`,
`player.dart:200` `_audio.setUrl`). With accounts, the player would have to send `Authorization`, and if its
HTTP stack follows the redirect with that header, **the token goes to the audio host.**
**Not verified:** whether AVFoundation, `URLSession` and just_audio's three backends forward `Authorization` across
hosts. Do not rely on it either way.

**Do this instead:** the app asks `/play` itself, with the token, **without following the redirect**, reads the
`Location` header, and gives that audio URL to the player. The Mac app already does exactly this for
`serve_fresh` (`API.swift:59`, the `noRedirect` session): make it the only path. It costs no extra round trip:
following the redirect was already two requests. The player never sees the token; downloads use the same audio URL.

### 3.3 Playlists in the UI
- Show shared playlists under your own. The server sends yours first, then the shared ones; tell them apart by
  `role != "owner"` (there is no separate `shared` field).
- Use `role` to show or hide actions: viewer → no add, remove, reorder; editor → no rename, delete, public toggle,
  share. The server enforces this anyway (403); the UI should not offer what will be refused.
- Owner: a **Share** sheet (username + viewer/editor), a **Public** toggle (`PATCH {public}`), rename via
  `PATCH {name}`. Member: **Leave** (`DELETE …/members/{own user id}`; the id is in `/auth/me`).
- A playlist that answers 404 after it was open (unshared, or deleted by its owner): close it and refresh the list.

### 3.4 Tests that will need a token
- Mac self-tests (`mac/Scripts/selftest.sh`, test server on 8765): sign up a `test-<random>` account first.
- Flutter `test/library_server_test.dart`: the same.
- The backend's own `tests/conftest.py` has `sign_up(client)` as the pattern: accounts named `test-…` are deleted
  after the run.

### 3.5 Building
- Mac app: `cd mac && xcodegen && xcodebuild -project NoNonsense.xcodeproj -scheme NoNonsense -configuration Release -derivedDataPath build build`.
  **The app starts its own server** (`ServerLauncher`) from `backend/` on port 8000: whatever branch is checked out.
- Flutter: `cd app && flutter build macos` (also `windows` in CI: `.github/workflows/windows.yml`; `apk` for
  Android).

---

## 4. Merging `auth-1` (the owner does this, when both apps sign in)

The server on `auth-1` **refuses to start on a database from before accounts**, with a message that says what to
run. The owner's own library must move to their account once, in one transaction:

```bash
cd ~/projects/music/backend && uv run python scripts/migrate_auth3.py --username <their username>
```

It asks for the password itself (never type it for them, never put it in a command). It was verified on a copy of
the real database on 8 Oct (22 likes and 510 plays moved; a second run prints "Nothing to do"). `music_test` is
already migrated.

Order: both apps sign in → owner runs the migration → merge `auth-1` (and the app branch) into `main`.

---

## 5. What is left for release 1, in order

| Item | What | Who |
|---|---|---|
| **App sign-in** | Section 3 | you (Claude, apps) |
| **AUTH-2** | Email: verification at sign-up, password reset by emailed code. A sender must be chosen (an app password on a mail account, or a provider with an own domain): **ask the owner** | owner + Claude |
| **AUTH-4** | Devices: list your sessions (name, last used), sign one out remotely | owner + Claude |
| **Rate limits** | Per account after sign-in; per IP only for sign-in attempts (decided 8 Oct) | owner + Claude |
| **LIVE-1…3** | A live connection per device; control one device from another (Spotify Connect-like); choose the audio output per device | both |
| **FRIENDS-1, JAM-1** | Friends by list or link; a jam everyone in it controls | both |
| **Releases** | GitHub Releases: Mac `.dmg` (the Swift app), Windows installer or zip, Android `.apk` | Claude |

**Undecided (ask before building):** saving someone else's public playlist to your list. Proposed: a separate
`playlist_saves` table (not a fourth role: a save gives no rights, it only lists it). The owner has not chosen.

**Known, open:**
- YouTube copies fail to play in the Flutter app's **macOS** build (just_audio error -1); JioSaavn copies play.
  Windows is unaffected as far as tested.
- Home's sideways shelf swipe (Flutter) is not verified on a real trackpad.
- Mac app: dragging inside a playlist that is then deleted leaves the top and bottom bars transparent.
- Recently Played reads all of a user's plays (fast now, 0.4 ms at test scale); a "last played" table fixes it if
  it grows.
- Hosting test: YouTube audio URLs are bound to the IP that asked for them, so a hosted server must also be the
  thing that streams, or the URLs fail on another network. Not tested yet.
- MUS-15 onwards in `TICKETS.md`; BUG-5 and BUG-7 (backend, the owner's).
- The docs (`docs/backend.md`) do not describe `auth-1` yet: **the owner writes the README and docs**; leave them.
