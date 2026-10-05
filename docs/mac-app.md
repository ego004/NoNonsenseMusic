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
- **Shortcuts:** ⌘→ next, ⌘← previous, ⌘↑ / ⌘↓ volume (as in Apple Music), Mute, ⌘L like, ⇧⌘F Now Playing. Space is handled by `Player.installKeyMonitor`.

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
- `listings` order: the default copy first, then the same source, then the rest, most popular first. The listings list and the fallbacks both follow it (checked 5 Oct: sent `yt-big, js-low, js-default, js-high` → `js-default, js-high, js-low, yt-big`).

### `formatTime(seconds)` — `200` → `"3:20"`.

---

## Services/API.swift — every server call

| Function | Request | Returns |
|---|---|---|
| `search(query)` | `GET /search?q=` | `SearchResponse` |
| `liked()` | `GET /liked` | `[LibrarySong]` |
| `recent()` | `GET /recent` | `[LibrarySong]` |
| `health()` | `GET /health` | `true` if the server answers |
| `playURL(listing, fresh:)` | (no request) | The URL `/play/{source}/{id}`, given to AVPlayer. `fresh: true` adds `?serve_fresh=true` |
| `refresh(listing)` | `GET /play/…?serve_fresh=true`, redirect **not** followed | The server's answer (status + detail). Tells the server a URL failed, so its cache fetches a fresh one, and says why the copy failed |
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
State the screens read: `queue`, `index`, `current`, `isPlaying`, `position`, `duration`, `isBuffering`, `upNext`, `showNowPlaying`, `playingListing` (the copy actually playing), `volume`, `isMuted`, `errorMessage`.

| Function | Does |
|---|---|
| `play(tracks, startAt:)` | Replaces the queue and starts one song. Reports a skip for the song it interrupts. |
| `playNext(track)` | Puts a song right after the current one. |
| `togglePlayPause()` | Pause / resume. |
| `next()` | Reports a skip, then the next song. |
| `previous()` | Restarts the song if more than 3 s in; otherwise the previous song. |
| `jump(to:)` | Plays one song from Up Next. |
| `setVolume(level)` | 0…1, remembered between launches; unmutes. |
| `nextPresses`, `previousPresses` | Count every skip (button, menu, media key, swipe); the transport buttons bounce on them. |
| `toggleMute()` | Mute / unmute. |
| `seek(to:)` | Moves to a second in the song. |
| `installKeyMonitor()` | Space = play/pause, except while typing in a text field. |
| `installSwipeMonitor()` | Two-finger swipe across the player bar: fingers left = next, right = previous. One skip per swipe; the coasting afterwards is ignored; vertical swipes pass through. Uses `barFrame`, which the bar reports. Checked 5 Oct with a synthetic swipe: one swipe, one `next()`. |
| `startCurrent()` (private) | Plays the current song's best copy, reports `play`, and warms the next song (`API.warm`). |
| `load(listing, fresh:)` (private) | Gives AVPlayer the `/play` URL (or the `serve_fresh` one); remembers which copy is loaded; watches for failure. |
| `statusChanged(status)` (private) | A copy failed. **2+ copies:** switch to the next one at once, then `API.refresh` the failed one and show why ("YouTube Music is unavailable right now. Playing the JioSaavn copy."). **1 copy:** `API.refresh` first (spinner); play the fresh URL if one came back (307), else say why and move on. Checked 5 Oct with `NN_SELFTEST_PLAY` and `NN_SELFTEST_LISTINGS` (a bot-checked YouTube copy → 502 → JioSaavn copy plays → message). |
| `show(message)` (private) | Shows `errorMessage` for 4 seconds; a newer message replaces it. |
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
- `setActivity(activity, clientID)`: connects if needed (handshake with your Application ID), then sends `SET_ACTIVITY`. `nil` clears the status. A connection that turns out dead (Discord restarted) is replaced once; a timeout is not retried at once.
- Failures are told apart: `notRunning` (no socket), `rejected(reason)` (Discord's words, e.g. "Invalid Client ID"), `closed`, `timeout`, `discord(message)` (Discord answered the command with an error).
- **Measured 5 Oct:** a handshake took 0.4 s, then 4.5 s, then no answer within 10 s when several came close together. The old 2 s limit reported this as "Discord isn't running". The wait is now 10 s (it runs on the actor, not the main thread), and the Application ID field applies on Return, not on every keystroke (each change is a new handshake).
- The status uses activity type 2 ("Listening to"). Every part follows Settings › Discord: the song (`details`), the artist (`state`), the cover (`assets`), the time bar (`timestamps`), each optional; the member-list line (`status_display_type`: 2 the song, 1 the artist, 0 the app's name); and what it shows while paused. It has no buttons or links.
- Needs an Application ID: create an application at discord.com/developers (its name is what people see: "Listening to NoNonsense") and paste its ID in Settings.
- Open question: Discord's gateway docs give timestamps in milliseconds; the app sends seconds, as common presence libraries do over this socket. Check the time bar once an ID is set.

### `Presence` (`@Observable`)
- `setEnabled(on)`, `setClientID(id)`, and the share settings (`statusLine`, `shareSong`, `shareArtist`, `shareArt`, `shareTime`, `showWhenPaused`): saved in `UserDefaults`; each change is sent to Discord at once.
- `update(track, isPlaying, position)`: called by the player on every change; sends `activity(for:)`, or clears the status. `status` shows the result in Settings.
- `activity(for:isPlaying:position:)`: the one place the status is built from the share settings.
- `sendTest()`: Settings' "Send a test status" (the last song, or a sample), to check the setup without playing.
- Only IDs of 17–20 digits are tried; an unchanged ID keeps its connection; only the newest attempt may set `status`.
- **The logo:** `shareLogo` uses the art asset named `nononsense` (you upload it once in the Developer Portal): the picture while paused or for a song without a cover, and a small badge on a real cover. Checked 5 Oct with `NN_SELFTEST_PRESENCE` (nothing sent).
- **When paused** (`whenPaused`): `message` shows your text (`pausedMessage`, default "Nothing playing"; applied on Return), `keep` shows the song without the time bar, `clear` removes the status. Checked 5 Oct with `NN_SELFTEST_PRESENCE` (nothing sent).

---

## Services/ThemeStore.swift

### `ThemeStore` (`@Observable`)
- **Does:** every coloured element and how its colour is chosen: `.system` (Apple's look; the view decides), `.song` (`songColor`, the playing cover's most vivid colour, kept current by `RootView`), `.custom` (your `#RRGGBB`).
- **Elements:** Background (the window's wash), Buttons (`.tint`), Progress line, Volume, Heart, Playing song (title, icon, Now Playing glow), Player bar (the glass, tinted).
- `color(element)` → the colour, or `nil` for the system look. Saved as `theme.<element>.mode` / `.hex` in `UserDefaults`.
- **Checked 5 Oct** (`NN_SELFTEST_THEME`): System → nil for all; Song → the song colour for all; Custom → each element's own colour.

---

## Services/ArtworkCache.swift

### `ArtworkCache.shared`
- **Does:** downloads each cover once and keeps it in memory, so a cover shown once appears instantly, and a new cover can replace the old one with no empty frame between them (that grey frame was the white flash between songs).

| Function | Returns |
|---|---|
| `image(for:)` | The cover. Two views asking for the same URL at once share one download (single-flight). |
| `cached(_:)` | The cover if already loaded, without waiting. |
| `colorGrid(for:)` | The cover shrunk to 3×3 pixels: nine colours, each where it sits on the cover. The background mesh is made from them. |
| `accent(for:dark:)` | The cover's most vivid colour, made readable; `nil` for grey covers (the system accent stays). Tints sliders, the progress line and the heart. |

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
| `RootView.swift` | `RootView` | The window: sidebar, the chosen screen over the colour backdrop, the floating player, Now Playing on top. Starts the server if needed, then loads the library. The title bar is see-through. Shows the player's message ("Couldn't play …") above the player bar. |
| `Screens.swift` | `SidebarItem` | The sidebar's three items. |
| | `SidebarView` | The sidebar, with the Settings link at the bottom. Each row's `.tag` must be its **last** modifier: before `.badge`, it was hidden and no row could be selected (5 Oct). |
| | `SearchView` | A large centred search bar, lower on the screen while empty, with your recently played covers under it; it moves to the top when you type. Focused on open; ⌘F focuses it. Waits 350 ms after typing stops (debounce). Shows a note if a source is down. |
| | `SearchBar` | The bar itself: glass capsule, icon, field, a spinner while searching, a clear (×) button. |
| | `RecentShelf` | The idle home: up to 12 recently played songs as large covers. Empty history shows nothing. |
| | `CoverTile` | One cover: under the pointer it tilts toward it with a soft light following the pointer (the Apple TV focus look), lifts, deepens its shadow and shows a glass play button; click plays (the whole Recently Played list becomes the queue). No tilt with Reduce Motion. |
| | `SongListView` | Liked Songs and Recently Played: title, count, Play, Shuffle, the list. |
| `SongRow.swift` | `SongRow` | One song: artwork (click to play), title, artists, "N listings" (click to open), heart (on hover), duration. Double-click plays. Right-click: Play, Play Next, Like. Playing a chosen listing keeps the rest of the list as the queue. |
| | `ListingRow` | One copy, inside an opened song: title, artists, "Default" for the copy that plays normally, source, quality, length. Click plays exactly this copy; the playing copy shows an animated speaker. |
| `PlayerViews.swift` | `PlayerBar` | The floating glass bar, with the volume control. Its glass is *interactive* (reacts to hover and press) and *materializes* in. Hidden until a song plays. |
| | `TransportControls` | ⏮ ▶ ⏭, shared by the bar and Now Playing. While a song loads, the play button is a spinner (so is the cover on the row you clicked). |
| | `NowPlayingView` | Full window, over a thick material: large artwork, progress, controls, a volume slider, Up Next. Esc closes it. |
| | `UpNextView` | The queue panel. Click a song to jump to it. |
| `Components.swift` | `ArtworkView` | A cover with rounded corners. |
| | `WindowBlur` | The see-through window background: AppKit's behind-window blur (`NSVisualEffectView`, `.behindWindow`). `amount` (Settings › Blur) thins it: 0 shows the desktop sharp. |
| | `ClearWindow` | Makes the window non-opaque with a clear background, so a thinned blur shows the desktop, not grey. |
| | `Backdrop` | The cover's nine colours as a `MeshGradient` whose inner points drift (about 30 s per cycle); a new song crossfades in. With **Custom** colours it is nine shades of your Background colour instead. `strength` scales it, `base:` adds a material (Now Playing). **Battery:** at most 30 frames a second, and still (no frames at all) unless music plays, the app is in front, Low Power Mode is off, Reduce Motion is off and the setting is on. Measured 5 Oct: ~1.5% CPU and energy impact ~1.5 during playback, the same with it moving or still. |
| | `Color(hex:)`, `.hexString` | `#RRGGBB` ⟷ colour (sRGB), for the custom colours. |
| | `VolumeControl` | Mute button (the speaker's waves follow the level: an SF Symbols variable value) and a slider. |
| | `LikeButton` | The heart, with a small bounce. |
| | `ProgressBar` | The thin bar. Drag to seek. The played part takes the tint (the cover's colour). A haptic tick at each minute while you drag (if Trackpad › Haptic ticks is on). |
| `SettingsView.swift` | `SettingsView` | Tabs, as in the Mac's own apps: **Appearance** (theme; transparency (never below 30%, `Look.minWindowOpacity`: the window stays readable over a video call), blur, colour strength; moving background; **Colours**: seven elements, each System / Song / Custom, Custom with a hex field + swatch; set all; reset all), **Trackpad** (haptic ticks on/off, the gestures), **Discord** (on/off, Application ID, test, what to share, a preview of what friends see), **Server**. Defaults live in `Look`; colours in `ThemeStore`. `HexColorControl` keeps a swatch and its `#RRGGBB` code in step (checked 5 Oct: six colours round-trip exactly, bad codes are rejected). |

---

## Debug/SelfTest.swift

### `SelfTest` (debug builds only)
- **Run:** `NN_SELFTEST=<folder> mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense`
- **Does:** draws the window into `<folder>/window.png` and `after-click.png`. Prints which view a click on each sidebar row reaches. Clicks the second row, prints the selection before and after, then quits.
- **Why:** checks layout and clicks without screen-recording permission. The app draws only its own window.
- **Limit:** glass (the sidebar, glass buttons) draws as blank in the PNG.

### Playback scenario (`NN_SELFTEST_PLAY=1`)
- **Run:** `NN_SELFTEST_PLAY=1 DATABASE_URL=postgresql:///music_test mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense -serverURL http://127.0.0.1:8765`. The launch argument overrides the server address for this run only; the app starts a test server there, on `music_test`, so your library stays clean.
- **Does:** plays a song whose only copy fails, then a song whose best copy fails but whose second works. Prints the player every second for 10 s, then quits.
- **Check:** `~/Library/Logs/NoNonsense/server.log` shows the `serve_fresh` retry for song 1, the background `serve_fresh` for song 2's bad copy, and a 307 for its good copy.

---

## The app icon

- **Drawn by code:** [`mac/Icon/make_icon.swift`](../mac/Icon/make_icon.swift): a white body on Apple's icon grid (824 px in 1024, continuous corners) and a folded-paper N. One strip in a zigzag: up the left stem (graphite front), over the top so its near-black back runs down the diagonal over the left stem, then the right stem (front again) folded over the diagonal's foot.
- **Regenerate:** `swift mac/Icon/make_icon.swift icon_1024.png`, then the ten sizes into `mac/NoNonsense/Assets.xcassets/AppIcon.appiconset/` (16–512 px, each at 1× and 2×).
- **Checked 5 Oct:** the built app's `Assets.car` holds AppIcon at 16, 32, 64, 128, 256, 512 and 1024 px; `CFBundleIconName` is `AppIcon`.

