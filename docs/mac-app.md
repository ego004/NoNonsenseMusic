# Mac app (Swift, SwiftUI)

All files are in `mac/NoNonsense/`. The project file is generated from [`mac/project.yml`](../mac/project.yml) by XcodeGen (`cd mac && xcodegen`).

| Folder | Holds |
|---|---|
| `App/` | The app's entry point, the windows, the menu commands. |
| `Models/` | Swift copies of the server's JSON shapes, and `Track`. |
| `Services/` | Everything that is not a screen: server calls, playback, library, Discord, colours, shuffle. |
| `Views/` | The screens and their parts. |
| `Debug/` | Debug-build-only tools (the self-test). |

## Three Swift ideas used everywhere

| Idea | Meaning |
|---|---|
| `@Observable` class | When one of its properties changes, every screen that reads it redraws by itself. |
| `async` / `await` | Same meaning as in Python: pause this function until the result arrives; the app keeps running. |
| `actor` | A class whose code runs on its own background thread, one call at a time. Used so slow work never freezes the screen. |

---

## App/NoNonsenseApp.swift

### `NoNonsenseApp`
- **Does:** starts the app.
- **How:** creates one `LibraryStore`, one `Presence`, one `Player` (the player gets the other two). Gives all three to every screen (`.environment`). Makes the main window and the Settings window. Applies the chosen theme (light/dark/system).

### `PlaybackCommands`
- **Does:** the "Controls" menu in the menu bar.
- **Shortcuts:** ⌘→ next, ⌘← previous, ⌘L like, ⇧⌘F Now Playing. Space is handled by `Player.installKeyMonitor`.

---

## Models/Models.swift

| Type | Mirrors | Note |
|---|---|---|
| `Listing` | `Listing` (server) | Adds `key` (`"source:id"`), `sourceName`, `quality`. |
| `SearchSong` | `Song` (server) | |
| `SourceInfo` | `SearchSourceInfo` | `num_results` is renamed to `numResults`. |
| `SearchResponse` | `SearchResponse` | |
| `LibrarySong` | `LibrarySong` | |
| `SongRef` | `SongRef` | `song_id` is renamed to `songID`. |
| `Track` | — | What every screen and the player use. Built from a `SearchSong` or a `LibrarySong`. |

### `Track`
- `id`: the best listing's key. `best`: the copy to play. `listings`: all copies.
- `playing(listing)` → the same song, set to play one chosen copy.

### `formatTime(seconds)` — `200` → `"3:20"`.

---

## Services/API.swift — every server call

| Function | Request | Returns |
|---|---|---|
| `search(query)` | `GET /search?q=` | `SearchResponse` |
| `liked()` | `GET /liked` | `[LibrarySong]` |
| `recent()` | `GET /recent` | `[LibrarySong]` |
| `health()` | `GET /health` | `true` if the server answers |
| `playURL(listing)` | (no request) | The URL `/play/{source}/{id}`, given to AVPlayer |
| `warm(listing)` | `GET /play/…`, redirect **not** followed | Nothing. Asks the server to look up the next song's audio early (pays off with a server cache) |
| `like(listings)` | `POST /liked` | The song's ID |
| `unlike(songID)` | `DELETE /liked/{id}` | Nothing |
| `event(listings, type, position)` | `POST /events` | Nothing |

`baseURL` is `http://127.0.0.1:8000` unless changed in Settings. `get`, `send` and `check` are the shared plumbing: send the request, check the status code, decode the JSON.

---

## Services/LibraryStore.swift

### `LibraryStore` (`@Observable`)
- `liked`, `recent`: the two lists the screens show.
- `likedKeys`: the `"source:id"` keys of every listing of every liked song.

### `isLiked(track)`
- **Returns:** `true` if **any** of the track's listings is in `likedKeys`. (Search results have no song ID, so the check uses listings.)

### `refresh()`
- **How:** loads `/liked` and `/recent` at the same time, rebuilds `liked`, `recent` and `likedKeys`.

### `toggleLike(track)`
- **How:** changes the heart **first** (optimistic: it feels instant), then calls `API.like` or `API.unlike`, then `refresh()`.

---

## Services/Player.swift

### `Player` (`@Observable`)
State the screens read: `queue`, `index`, `current`, `isPlaying`, `position`, `duration`, `isBuffering`, `upNext`, `showNowPlaying`.

| Function | Does |
|---|---|
| `play(tracks, startAt:)` | Replaces the queue and starts one song. Reports a skip for the song it interrupts. |
| `playNext(track)` | Puts a song right after the current one. |
| `togglePlayPause()` | Pause / resume. |
| `next()` | Reports a skip, then the next song. |
| `previous()` | Restarts the song if more than 3 s in; otherwise the previous song. |
| `jump(to:)` | Plays one song from Up Next. |
| `seek(to:)` | Moves to a second in the song. |
| `installKeyMonitor()` | Space = play/pause, except while typing in a text field. |
| `startCurrent()` (private) | Plays the current song's best copy, reports `play`, and warms the next song (`API.warm`). |
| `load(listing)` (private) | Gives AVPlayer the `/play` URL; watches for failure. |
| `statusChanged(status)` (private) | If a copy fails: tries the song's other copies. If all fail: next song. |
| `tick(seconds)` (private) | Every 0.5 s: updates `position`. |
| `itemEnded(item)` (private) | Reports `finish`, then the next song. |
| `reportSkipIfNeeded()` (private) | Reports `skip` with the second, unless the song was in its last 3 s. |
| `report(type, track, at:)` (private) | Sends `API.event` in the background; refreshes the library after a `play`. |
| `publish()` (private) | Updates Control Center / media keys, and calls `Presence.update`. Runs on play, pause, seek. Not every 0.5 s. |
| `loadArtwork(track)` (private) | Fetches the cover for Control Center. |
| `setUpRemoteCommands()` (private) | Connects media keys and Control Center buttons to the functions above. |

---

## Services/ServerLauncher.swift

### `ServerLauncher` (`@Observable`)
- **Does:** when the app opens and nothing answers `/health` at a local address, starts the backend: `uv run fastapi dev src/music_backend/main.py --port 8000` in the backend folder. Stops it when the app quits. A server you started yourself is left alone.
- **Why `fastapi dev`:** it reloads when you edit the backend, and listens on `127.0.0.1` only. (`fastapi run` would listen on every network.)
- **Backend folder:** Settings → Server. Default `~/projects/music/backend`, built from the home folder.
- **Log:** `~/Library/Logs/NoNonsense/server.log` (Settings → Open server log).
- **Checked 5 Oct 2026:** server down → it answers 1.1 s after the app opens → gone after the app quits. Stopping `uv` also stops the server under it.
- **Limit:** if the app is force-killed, its server keeps running. The next launch finds it running and leaves it alone.

---

## Services/Presence.swift — Discord Rich Presence

### `DiscordIPC` (`actor`)
- **Does:** talks to the Discord desktop app through its local socket (`$TMPDIR/discord-ipc-0`).
- **Message format:** `[opcode: 4 bytes][length: 4 bytes][JSON]`. Opcode 0 = handshake, 1 = command, 2 = Discord refused.
- `setActivity(activity, clientID)`: connects if needed (handshake with your Application ID), then sends `SET_ACTIVITY`. `nil` clears the status.
- The status uses activity type 2 ("Listening to"). It has no buttons or links.

### `Presence` (`@Observable`)
- `setEnabled(on)`, `setClientID(id)`: the Settings controls. Saved in `UserDefaults`.
- `update(track, isPlaying, position)`: builds the status (song, artists, album cover, start and end times) and sends it. Paused or stopped clears it. `status` shows the result in Settings.

---

## Services/Palette.swift

| Function | Returns |
|---|---|
| `pastel(for:dark:)` | The artwork's average colour, softened toward white (light mode) or black (dark mode). Cached per URL. |
| `fallback(for:)` | A soft colour made from the title, for songs without artwork. |
| `averageRGB(data)` | The average colour of an image (Core Image's area-average filter). Runs off the main thread (`@concurrent`). |

---

## Services/Shuffle.swift

| Function | Does |
|---|---|
| `fisherYates(items, using:)` | True random order. Every order is equally likely. Returns a new array. |
| `artistSpread(items, artist:, using:)` | Spreads each artist's songs evenly through the list (position = offset + i/k, plus jitter). |
| `tracks(tracks)` | What the Shuffle button calls: `artistSpread` by first artist. |

Measured: 3 artists × 4 songs, 1,000 shuffles: same-artist neighbours per shuffle fell from 3.0 (true random) to 0.03.

---

## Views

| File | Type | Shows |
|---|---|---|
| `RootView.swift` | `RootView` | The window: sidebar, the chosen screen over the colour backdrop, the floating player, Now Playing on top. Starts the server if needed, then loads the library. The title bar is see-through. |
| `Screens.swift` | `SidebarItem` | The sidebar's three items. |
| | `SidebarView` | The sidebar, with the Settings link at the bottom. Each row's `.tag` must be its **last** modifier: before `.badge`, it was hidden and no row could be selected (5 Oct). |
| | `SearchView` | A large centred search bar, lower on the screen while empty; it moves to the top when you type. Focused on open; ⌘F focuses it. Waits 350 ms after typing stops (debounce). Shows a note if a source is down. |
| | `SearchBar` | The bar itself: glass capsule, icon, field, a spinner while searching, a clear (×) button. |
| | `SongListView` | Liked Songs and Recently Played: title, count, Play, Shuffle, the list. |
| `SongRow.swift` | `SongRow` | One song: artwork (click to play), title, artists, "N copies", heart (on hover), duration. Double-click plays. Right-click: Play, Play Next, Like. |
| | `VersionsView` | The "N copies" popover: every listing; click one to play that copy. |
| `PlayerViews.swift` | `PlayerBar` | The floating glass bar. Hidden until a song plays. |
| | `TransportControls` | ⏮ ▶ ⏭, shared by the bar and Now Playing. |
| | `NowPlayingView` | Full window: large artwork, progress, controls, Up Next. Esc closes it. |
| | `UpNextView` | The queue panel. Click a song to jump to it. |
| `Components.swift` | `ArtworkView` | A cover with rounded corners. |
| | `Backdrop` | The blurred artwork + pastel colour behind the screens. |
| | `LikeButton` | The heart, with a small bounce. |
| | `ProgressBar` | The thin bar. Drag to seek. |
| | `Chip` | A small label ("JioSaavn", "AAC 320 kbps"). |
| `SettingsView.swift` | `SettingsView` | Theme, Discord (toggle, Application ID, status), server address and status. |

---

## Debug/SelfTest.swift

### `SelfTest` (debug builds only)
- **Run:** `NN_SELFTEST=<folder> mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense`
- **Does:** draws the window into `<folder>/window.png` and `after-click.png`. Prints which view a click on each sidebar row reaches. Clicks the second row, prints the selection before and after, then quits.
- **Why:** checks layout and clicks without screen-recording permission. The app draws only its own window.
- **Limit:** glass (the sidebar, glass buttons) draws as blank in the PNG.

