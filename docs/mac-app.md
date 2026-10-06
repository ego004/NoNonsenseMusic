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
- **Shortcuts:** ⌘→ next, ⌘← previous, ⌘S shuffle on/off, ⌘R repeat (off → all → one), ⌘↑ / ⌘↓ volume (as in Apple Music), Mute, ⌘L like, ⇧⌘F Now Playing. Space is handled by `Player.installKeyMonitor`.
- **File menu:** ⌘N New Playlist… (replaces the system's New item).

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
| `prefetch(listings)` | `POST /prefetch` | Nothing (202). The server looks the listings up in the background; `Prefetcher` sends them |
| `like(listings)` | `POST /liked` | The song's ID |
| `unlike(songID)` | `DELETE /liked/{id}` | Nothing |
| `event(listings, type, position)` | `POST /events` | Nothing |

`baseURL` is `http://127.0.0.1:8000` unless changed in Settings. `get`, `send` and `check` are the shared plumbing: send the request, check the status code, decode the JSON.

---

**Playlists (MUS-2).** Ids go in URLs lowercase. Every failure carries the server's own sentence when it sent one (`Failure.http(code, detail:)`), so messages say "A playlist with this name already exists", not "409".

| Function | Request | Returns |
|---|---|---|
| `playlists()` | `GET /playlists` | `[PlaylistSummary]` |
| `playlist(id)` | `GET /playlists/{id}` | `PlaylistDetail` |
| `createPlaylist(named:)` | `POST /playlists` | `PlaylistSummary` |
| `renamePlaylist(id, to:)` | `PATCH /playlists/{id}` | `PlaylistSummary` |
| `deletePlaylist(id)` | `DELETE /playlists/{id}` | — (204) |
| `add(listings, to:)` | `POST /playlists/{id}/items` | `PlaylistItemRef` |
| `remove(item:from:)` | `DELETE /playlists/{id}/items/{item}` | — (204) |
| `move(item:in:top:bottom:)` | `POST /playlists/{id}/items/{item}/move` | — (204) |
| `move(playlist:top:bottom:)` | `POST /playlists/{id}/move` | — (204) |

Swift names for the server's models: `PlaylistSummary` = PlaylistMetadata, `PlaylistEntry` = PlaylistItem, `PlaylistDetail` = PlaylistItems, `PlaylistItemRef` = PlaylistItemRef.

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

### Playlists (MUS-2)
- `playlists`: the sidebar's list. `details[id]`: each opened playlist's rows, as last loaded.
- **Every change goes through the store** and then reloads the playlist it touched; the reload is handed to `playlistChanged`, which the Player sets, so a playing playlist's queue follows edits made anywhere.
- `createPlaylist(named:adding:)`, `renamePlaylist(_:to:)`: return nil when it worked, else the reason for the sheet.
- `add(track, to:)`: shows "✓ Added to “Gym”". `remove(entry, from:)`, `moveItems(in:from:to:)`, `movePlaylists(from:to:)`: change the screen at once, then tell the server; a failure reloads the server's version. A move sends the moved row's new neighbours, so one row changes on the server.
- `newPlaylistRequest`, `renameRequest`, `deleteRequest`: ask RootView for the sheet or the "Delete …?" question, from wherever (sidebar, playlist screen, a song's menu, ⌘N).
- `message` + `messageSymbol`: a problem shows a warning triangle, a success a tick.

## Services/Player.swift

### `Player` (`@Observable`)
State the screens read: `queue`, `index`, `current`, `playingFrom` (the playlist the queue came from, or nil), `isShuffled`, `repeatMode`, `isPlaying`, `position`, `duration`, `isBuffering`, `upNext`, `showNowPlaying`, `playingListing` (the copy actually playing), `volume`, `isMuted`, `errorMessage`.

| Function | Does |
|---|---|
| `play(tracks, startAt:, keys:, source:)` | Replaces the queue and starts one song. Reports a skip for the song it interrupts. With shuffle on, that song plays first and every other one is shuffled. `keys`/`source` (a playlist's item ids and "playlist:<id>") let that playlist's edits reach the queue. |
| `playInOrder(tracks)` | A list's Play button: shuffle off, from the first song. |
| `shufflePlay(tracks)` | A list's Shuffle button: shuffle on, a random song first. |
| `toggleShuffle()`, `cycleRepeat()` | The two mode buttons (and ⌘S, ⌘R). Both are remembered between launches. |
| `syncQueue(source:, items:)` | A playlist changed: if the queue came from it, the queue follows (`PlayQueue.sync`). |
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
| `startCurrent()` (private) | Plays the current song's best copy, reports `play`, and tells the Prefetcher the next 5 songs (`announceNext`). |
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

## Services/PlayQueue.swift

### `PlayQueue` (a plain value, no audio)
The order songs play in. The Player owns one; the self-test checks every rule (`NN_SELFTEST_QUEUE`).
- **Entries** carry the song, `n` (its place in the order you chose) and `key` (a playlist item id, so a song added twice is two entries).
- **Shuffle on:** the songs after the current one are shuffled, each artist spread out (`Shuffle.artistSpread`); played songs stay. **Off:** sorted back by `n`, still on the same song. A new queue with shuffle on puts your song first and shuffles all the others.
- **Repeat:** `off` stops at the end; `all` starts over; `one` plays a song again when it ends, but ⏭ still moves on. ⏮ on the first song wraps to the last unless repeat is off.
- **Play next:** right after the current song, in both orders.
- **`sync(source:items:)`:** your order follows the playlist; removed songs leave (the playing one plays on); new ones join at the end. Shuffled, the play order stays shuffled. Example checked: `abcde` → `adbce` while `a` plays, so `d` is next.

---

## Services/DownloadStore.swift

### `DownloadStore` (`@Observable`)
- **Does:** keeps songs on this Mac to play without the server or the internet. Files in `~/Library/Application Support/NoNonsense/Downloads`, with `index.json` holding each song's details, so the Downloads list works with the server off. Self-tests use `Downloads-selftest`.
- **Downloading:** whatever `/play` points to (this Mac has the server's IP, so YouTube's IP-bound URLs work), the best copy first, then the others. `download(all:name:)` does a playlist one song at a time.
- **Playing:** `Player.startCurrent` plays the downloaded copy's file if there is one (`playingFile`); a broken file falls back to streaming the other copies.
- **Checked 6 Oct (`NN_SELFTEST_DOWNLOADS`):** two songs in 2.5 s (15.1 MB and 12.4 MB at 320 kbps); with the server stopped, a download played from its file; remove and remove-all leave the folder empty.
- **Limit, measured 6 Oct:** YouTube throttles direct downloads to about playback speed: one 5.1 MB YouTube song took 159 s (JioSaavn: about 1 s per song).

---

## Services/Prefetcher.swift

### `Prefetcher.shared`
- **Does:** tells the server what comes next (`API.prefetch` → `POST /prefetch`), so those songs start from the server's cache.
- **The list:** the next 5 songs in play order (round again with repeat on; `Player.announceNext`), then the top 5 of the search on screen; queue first, no song twice, each as its best listing. Sent 0.3 s after things settle and only when it changed. Replaces `API.warm`, which warmed only the next song.
- **Checked 6 Oct (`NN_SELFTEST_PREFETCH`):** queue songs 2–4 played in 2.5–5.8 ms (one of them YouTube, ~1.9 s without prefetch); the search's top result in 5.2 ms.

---

## Services/ServerLauncher.swift

### `ServerLauncher` (`@Observable`)
- **Does:** when the app opens and nothing answers `/health` at a local address, starts the backend: `uv run fastapi dev src/music_backend/main.py --port 8000` in the backend folder. Stops it when the app quits. A server you started yourself is left alone.
- **Why `fastapi dev`:** it reloads when you edit the backend, and listens on `127.0.0.1` only. (`fastapi run` would listen on every network.)
- **Backend folder:** Settings → Server. Default `~/projects/music/backend`, built from the home folder.
- **Log:** `~/Library/Logs/NoNonsense/server.log` (Settings → Open server log).
- **Checked 5 Oct 2026:** server down → it answers 1.1 s after the app opens → gone after the app quits.
- **Fixed 6 Oct 2026:** a test server sometimes outlived its app: the `fastapi dev` reloader kept the port and even ignored its own SIGTERM. Now: one shared launcher (`ServerLauncher.shared`, so one quit observer), one start at a time (a second `ensureRunning()` waits for the first), and on quit SIGTERM to `uv` and everything under it, 2 s to finish, then SIGKILL. 6 test runs after the fix: 0 leaks.
- **Fixed 6 Oct 2026:** the log is opened in append mode. Before, each writer kept its own position, so two servers (8000 and a test one on 8765) and the app's notes overwrote each other's lines.
- **Notes:** the app writes its own lines into the log (`NoNonsense: started a server on port …`, `app quitting: …`, `stopped the server: pids […]`).
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
- **Playlist name (6 Oct):** `sharePlaylist`, off by default (playlist names can be personal). On, a song playing from a playlist shows "by The Weeknd · from “Gym”" under it. The Player passes the name (`Player.playingFrom`).


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
| `Screens.swift` | `SidebarItem` | The sidebar's fixed items: Home (the first screen), Search, Liked Songs, Recently Played. |
| | `Destination` | What the window shows: a fixed item, or one playlist. |
| | `SidebarView` | The sidebar, with the Settings link at the bottom. A **Playlists** section: its last row, **New Playlist** (or ⌘N), makes one; drag to reorder; right-click to Play, Shuffle, Rename, Delete. New Playlist was a + in the section header, but the header is wider than the rows, so the + sat against the sidebar's edge (6 Oct); as a row it lines up with the rest (measured: every icon centred at x 37, every title starting at x 54). Each row's `.tag` must be its **last** modifier: before `.badge`, it was hidden and no row could be selected (5 Oct). macOS 26 draws the sidebar as a floating glass panel (`NSContainerConcentricGlassEffectView`, 8 pt in from the window's edges) that SwiftUI cannot change; Surfaces › Sidebar adds frost and fill over it. |
| | `SearchView` | A large centred search bar, lower on the screen while empty, with your recent searches under it (chips; a search becomes recent once it led to a song you played); it moves to the top when you type. Focused on open; ⌘F focuses it. Waits 350 ms after typing stops (debounce), but counts as loading from the first keystroke, so "No Results" only shows for a search that finished empty. Shows a note if a source is down. |
| | `SearchBar` | The bar itself: glass capsule, icon, field, a spinner while searching, a clear (×) button. |
| | `RecentSearches` | The searches that led to a song you played: newest first, at most 12, other capitals count once. Stored on this Mac only (`recentSearches`). |
| | `RecentSearchChips` | The idle Search screen: recent searches as glass chips that wrap (`FlowLayout`). Click searches again; ✕ on hover or right-click removes one; Clear removes all. |
| | `FlowLayout` | Lays views out left to right, starting a new line when one does not fit. |
| | `TiltCard` | Any square artwork that answers the pointer: tilts toward it, a light follows the pointer, the shadow deepens, a glass ▶ floats in. No tilt with Reduce Motion. Used by song covers and playlist cards. |
| | `CoverTile` | One cover: under the pointer it tilts toward it with a soft light following the pointer (the Apple TV focus look), lifts, deepens its shadow and shows a glass play button; click plays (the whole Recently Played list becomes the queue). No tilt with Reduce Motion. |
| | `SongListView` | Liked Songs and Recently Played: title, count, Play, Shuffle, the list. |
| `SongRow.swift` | `SongRow` | One song: artwork (click to play), title, artists, "N listings" (click to open), heart (on hover), duration. Double-click plays. Right-click: Play, Play Next, Like, Add to Playlist (every playlist, or New Playlist…), and in a playlist "Remove from …". Playing a chosen listing keeps the rest of the list as the queue. |
| | `ListingRow` | One copy, inside an opened song: title, artists, "Default" for the copy that plays normally, source, quality, length. Click plays exactly this copy; the playing copy shows an animated speaker. |
| `PlayerViews.swift` | `UpNextView` | Now Playing's Up Next: drag to reorder, ✕ or right-click to remove, Clear. Once you change it by hand, the queue is yours: the playlist it came from no longer reorders it. |
| | `PlayerBar` | The floating bar (a rounded rectangle, at most 900 pt wide, 70 pt tall): the song on the left; in the centre ⏮ ▶ ⏭ with the progress line under them, elapsed time on its left and time left on its right; the buttons on the right. The progress line used to run along the bar's curved bottom edge, which looked stuck on (6 Oct). Liquid Glass by default (*interactive*: reacts to hover and press; *materializes* in), or Frosted (Settings › Appearance › Surfaces › Player bar). In a narrow window the volume slider folds away first (the speaker still mutes). Hidden until a song plays. |
| | `PlayerBarLayout` | The bar's layout: the centre gets what the sides leave (280–480 pt), and both sides always get the same width, so the centre is the bar's exact centre whatever the title. Measured 6 Oct: at a 1,180 pt window the centre is 363 pt and the progress line 267 pt; at the narrowest window (900 pt) 280 pt and 184 pt; ⏮ ▶ ⏭ 0.0 pt off centre in both. |
| | `TransportControls` | Shuffle ⏮ ▶ ⏭ Repeat, shared by the bar and Now Playing. Shuffle and repeat are the same width on each side, so ▶ stays centred; when on they take the Buttons colour on a soft disc, and repeat's icon morphs to `repeat.1`. While a song loads, the play button is a spinner (so is the cover on the row you clicked). |
| | `NowPlayingPanel` | What sits beside the song in Now Playing: Up Next, Lyrics, or nothing (remembered as `nowPlayingPanel`). |
| | `LyricsPanel` | Until MUS-12: says lyrics are coming, in the same glass as Up Next. |
| | `NowPlayingView` | Full window, over a blur and fill of its own (Settings › Appearance › Surfaces › Now Playing): large artwork (sized from the height left after the top bar and the controls), progress, controls, volume, and a side panel. Top right: Lyrics, Up Next (press the showing one again to hide it: the song alone, centred, bigger) and Full Screen. Esc or a pinch in closes it. The player bar opens it three ways: 💬 Lyrics, ☰ Up Next, ⤢ the song alone. |
| | `UpNextView` | The queue panel. Click a song to jump to it. |
| `Home.swift` | `HomeView` | The first screen: a greeting; "Jump back in" (recently played covers in a shelf that stops on a cover); "Your playlists" (a grid of cards); "Liked Songs" (compact rows three high, scrolling sideways); See All on each. A new library shows one step: Search. Sections fade up one after another (not with Reduce Motion). |
| | `PlaylistCard` | A playlist on Home: cover (its songs are loaded on first sight), name, length. Click opens it; the glass ▶ plays it; right-click: Open, Play, Rename, Delete. |
| | `CompactSongTile` | A song as a compact row for the sideways grids. Click plays; right-click has the full row's menu. |
| `Playlists.swift` | `PlaylistView` | One playlist: cover, name, "12 songs · 48 min", Play, Shuffle, ⋯ (Rename, Delete), the songs. Drag a song to move it; right-click to remove it. "This playlist is gone" if it was deleted elsewhere. |
| | `PlaylistCover` | Until uploads exist: the first four different covers in a 2×2 grid, one cover for fewer, a soft gradient for none. The gradient's colour comes from the playlist's name, so empty playlists differ. |
| | `NamePlaylistSheet` | New Playlist and Rename: the server decides whether a name is free; its reason shows under the field, and the field shakes (not with Reduce Motion). |
| | `AddToPlaylistMenu` | "Add to Playlist" in a song's menu: New Playlist… (made, then the song added), then every playlist. |
| `Components.swift` | `ArtworkView` | A cover with rounded corners. A cover already in the cache shows at once (no empty square fading in each time a screen reappears). |
| | `textStyle(_:)` | Text at Settings › Appearance › Text size (0.85…1.4 times the Mac's sizes). macOS ignores SwiftUI's `dynamicTypeSize` (measured: the same width at every size), so content text uses this instead of `.font(...)`; icons keep fixed sizes. At 1.0 it matches the Mac exactly (135 pt for the test line, as `.font(.body)`). |
| | `WindowBlur` | The see-through window background: AppKit's behind-window blur (`NSVisualEffectView`, `.behindWindow`). `amount` (Settings › Blur) thins it: 0 shows the desktop sharp. With `blending: .withinWindow` it blurs the app's own content under it instead (the Frosted bar, Now Playing). |
| | `SurfaceLayer` | One surface's background: a `WindowBlur` at `blur`, and over it the window's colour at `solid`. At 0 / 0 it draws nothing, so the sidebar and the bar look exactly as before until you move a slider. `Look.readable` keeps some fill when the blur is low (the same 30% floor as the window, fading out as the blur grows). |
| | `selfTestFrame(_:)` | Debug builds: records where a view is (`SelfTest.frames`), for checks that cannot use pictures. Release builds: nothing. |
| | `ClearWindow` | Makes the window non-opaque with a clear background, so a thinned blur shows the desktop, not grey. |
| | `Backdrop` | The cover's nine colours as a `MeshGradient` whose inner points drift (about 30 s per cycle); a new song crossfades in. With **Custom** colours it is nine shades of your Background colour instead. `strength` scales it, `base:` adds a fill under it. **Battery:** at most 30 frames a second, and still (no frames at all) unless music plays, the app is in front, Low Power Mode is off, Reduce Motion is off and the setting is on. Measured 5 Oct: ~1.5% CPU and energy impact ~1.5 during playback, the same with it moving or still. |
| | `Color(hex:)`, `.hexString` | `#RRGGBB` ⟷ colour (sRGB), for the custom colours. |
| | `VolumeControl` | Mute button (the speaker's waves follow the level: an SF Symbols variable value) and a slider (`slider: false`: the speaker alone, for a narrow bar). |
| | `LikeButton` | The heart, with a small bounce. |
| | `ProgressBar` | The thin bar. Drag to seek. The played part takes the tint (the cover's colour). A haptic tick at each minute while you drag (if Trackpad › Haptic ticks is on). |
| `SettingsView.swift` | `SettingsView` | Tabs, as in the Mac's own apps: **Appearance** (**Window**: theme, moving background; **Surfaces**: pick a part (Main area, Sidebar, Player bar, Now Playing) and set its blur (Clear ↔ Frosted) and transparency (See-through ↔ Solid), plus colour strength for the main area and Now Playing, and Liquid Glass or Frosted for the bar; the main area's transparency is never below 30%, `Look.minWindowOpacity`: the window stays readable over a video call; **Sizes**: text size and card size with a live sample; **Colours**: seven elements, each System / Song / Custom, Custom with a hex field + swatch; set all; reset all), **Trackpad** (haptic ticks on/off, the gestures), **Discord** (on/off, Application ID, test, what to share, a preview of what friends see), **Server**. Defaults live in `Look`; colours in `ThemeStore`. `HexColorControl` keeps a swatch and its `#RRGGBB` code in step (checked 5 Oct: six colours round-trip exactly, bad codes are rejected). **Collapsible sections (6 Oct):** Appearance has Window, Sizes and Colours; Discord has Share and What friends see. Each remembers whether it is open (`settings.open.…`). Colours opens on its own (it closes Window, Sizes and Surfaces, and they close it): with everything open the page was 1,165 pt tall, taller than a MacBook's 847 pt of usable screen. **Every page is capped at the screen (`SettingsPage`, 6 Oct):** as tall as its content, never taller than the usable screen less 120 pt; past that it scrolls. Discord with everything open was 983 pt on an 847 pt screen, its bottom 34 pt below the screen's edge; now 815 pt (measured). The cap is a small `Layout` (`CappedHeight`) that asks the page for its natural height with no height proposed: measuring the Form's scroll content instead looped (the content is at least as tall as the frame, so each pass grew it) until AppKit stopped the app. |

---

## Performance (measured 6 Oct, debug build)

| State | App CPU, one sample a second |
|---|---|
| Idle on Home | 0.0% in 7 of 8 samples (one 1.8% blip) |
| Playing, muted, Home visible (moving backdrop on) | 0.6–2.8%, about 2.5% |

## Motion (6 Oct)

| When | What moves | Reduce Motion |
|---|---|---|
| A song will not play | The player bar shakes once (`Player.problems` counts each problem, so clearing the message does not shake it); a haptic on Force Touch trackpads; the message's icon hops | No shake |
| A message arrives | It grows out of the player bar's glass and sinks back into it; its icon hops | — |
| A taken playlist name | The name field shakes; the server's reason slides in under it | No shake |
| "Add to Playlist" | That playlist's icon in the sidebar hops | — |
| Lists change (liked, recent, a playlist, the sidebar's playlists) | Rows slide in and out; a reorder gives a light haptic | — |
| Home opens | Sections fade up one after another | No lift |
| The pointer over a cover or a card | Tilt, light, shadow, glass ▶ | No tilt |
| Now Playing's panel | Slides in or out; the artwork grows or shrinks with a spring | — |

## Debug/SelfTest.swift

### `SelfTest` (debug builds only)
- **Run:** `NN_SELFTEST=<folder> mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense`
- **Does:** draws the window into `<folder>/window.png` and `after-click.png`. Prints which view a click on each sidebar row reaches. Clicks the second row, prints the selection before and after, then quits.
- **Why:** checks layout and clicks without screen-recording permission. The app draws only its own window.
- **Limit:** glass (the sidebar, glass buttons) draws as blank in the PNG.

### Every scenario
- **Run one:** `mac/Scripts/selftest.sh NN_SELFTEST_PLAYLISTS=arijit` (any scenario's variable). It builds first, runs against the test server (8765, `music_test`), stops a hung run after 180 s, and reports a test server that outlived the app as a LEAK. Pictures go to `$NN_SNAPS` (default `$TMPDIR/nononsense-snaps`).
- Any `NN_SELFTEST…` variable puts an orange "Self-test · test library" label on the window: a test window opens on your screen and must not pass for your app.
- `NN_SELFTEST_SNAP=<folder>`: scenarios save pictures of the window at key moments (two methods: drawn, and from its layers). **Limit:** neither can draw lists (table views) or glass; the scenarios count list rows instead.
- Run them against the test server: `-serverURL http://127.0.0.1:8765`, `DATABASE_URL=postgresql:///music_test`, and `-discordEnabled NO`.

- **Your settings are borrowed, not changed:** a scenario that changes settings saves them to a file first (`borrowDefaults`) and puts them back at the end (`returnDefaults`). If it dies first, the next self-test launch puts them back before anything else (a crash on 6 Oct had left four Settings sections changed).
- `NN_SELFTEST_SIDEBAR=1`: New Playlist lines up with every other sidebar row, and a click on it asks for the New Playlist sheet.
- `NN_SELFTEST_SETTINGS_FIT=1`: every Settings tab, with every section open, fits on the screen.
- `NN_SELFTEST_BAR=<search>`: the player bar's layout at the window's size and at its narrowest (centred controls; the progress line inside, under them; nothing overlapping), then each surface setting, checked by the blur view it must create at its strength.
- `RootView` listens for `.selfTestOpen` (a playlist's UUID, or a `Destination`): scenarios move the window to the screen they test.
- **Limit, measured 6 Oct:** window pictures also miss everything inside scroll views (Home is all scroll views). Scenarios count what appeared instead (`SelfTest.appeared`), and draw components off screen with `ImageRenderer` (which shows sliders as a yellow placeholder and skips glass).

### Queue rules (`NN_SELFTEST_QUEUE=1`)
- **Does:** 21 checks of `PlayQueue` on made-up songs (shuffle, repeat, play next, a playlist's edits), PASS/FAIL each. Plays nothing; needs no server.

### Playlists (`NN_SELFTEST_PLAYLISTS="<search>"`)
- **Does:** create, the same name again (expects the server's reason), add 4 songs from one search, play, drag the 4th song up (checks the screen, the playing queue and the server agree), remove, rename, delete. Counts the playlist screen's rows. Refuses to run against port 8000.

### Home (`NN_SELFTEST_HOME="<search>"`)
- **Does:** fills the test library (a playlist of 4 songs, 3 liked), waits on Home, reports how many covers, playlist cards and liked rows appeared (6 Oct: 4, 4, 4, matching the data), draws the cards off screen into `home-cards.png`, then cleans up.

### Now Playing (`NN_SELFTEST_NOWPLAYING="<search>"`)
- **Does:** plays 4 songs (muted) and draws Now Playing off screen in each layout: `nowplaying-none.png`, `-lyrics.png`, `-upNext.png`. Puts your remembered layout back before quitting.

### Text size (`NN_SELFTEST_SIZES=1`)
- **Does:** measures `textStyle(.body)` at 0.85 / 1 / 1.3 (6 Oct: 117 / 135 / 168 pt) and checks 1.0 equals `.font(.body)`.

### Settings (`NN_SELFTEST=<folder> NN_SELFTEST_SETTINGS=1`)
- **Does:** opens Settings through its menu item, draws it, then measures the Appearance page's height with Colours closed and open (6 Oct: 740 and 715 pt, screen 847 pt usable). Puts your open/closed sections back, twice (putting one back can make the page close another).

### Your settings stay yours
Self-test windows share your settings file. Tests that touch a setting (shuffle, the Now Playing layout) put it back before quitting; checked 6 Oct: shuffle, repeat, nowPlayingPanel, textScale and cardSize all still unset after every scenario.

### Playback scenario (`NN_SELFTEST_PLAY=1`)
- **Run:** `NN_SELFTEST_PLAY=1 DATABASE_URL=postgresql:///music_test mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense -serverURL http://127.0.0.1:8765`. The launch argument overrides the server address for this run only; the app starts a test server there, on `music_test`, so your library stays clean.
- **Does:** plays a song whose only copy fails, then a song whose best copy fails but whose second works. Prints the player every second for 10 s, then quits. At 2 s it also prints `centre: … off by N pt`: how far ⏮ ▶ ⏭ sit from the bar's centre (0 expected).
- **Check:** `~/Library/Logs/NoNonsense/server.log` shows the `serve_fresh` retry for song 1, the background `serve_fresh` for song 2's bad copy, and a 307 for its good copy.

### Search scenario (`NN_SELFTEST_SEARCH="<query>"`)
- Also checks recent searches: the rules (newest first, capitals, at most 12, remove), then plays the first result as a double-click does and checks the search became recent. Your list is put back after.
- **Run:** `NN_SELFTEST_SEARCH="arijit" DATABASE_URL=postgresql:///music_test mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense -serverURL http://127.0.0.1:8765`
- **Does:** types the query into the search bar one letter every 120 ms, samples every 50 ms until 3 s after the last letter, then quits. One real search goes out (the debounce cancels the partial ones). It reads what SearchView decides to draw (`SelfTest.noResultsShowing`, set in debug builds), not the screen: the accessibility tree came back empty without a screen reader attached.
- **Check:** `"No Results" showed in 0 of N samples` and a result count above 0. Before the 6 Oct fix: 16 of 72.

---

## The app icon

- **Drawn by code:** [`mac/Icon/make_icon.swift`](../mac/Icon/make_icon.swift): a white body on Apple's icon grid (824 px in 1024, continuous corners) and a folded-paper N. One strip in a zigzag: up the left stem (graphite front), over the top so its near-black back runs down the diagonal over the left stem, then the right stem (front again) folded over the diagonal's foot.
- **Regenerate:** `swift mac/Icon/make_icon.swift icon_1024.png`, then the ten sizes into `mac/NoNonsense/Assets.xcassets/AppIcon.appiconset/` (16–512 px, each at 1× and 2×).
- **Checked 5 Oct:** the built app's `Assets.car` holds AppIcon at 16, 32, 64, 128, 256, 512 and 1024 px; `CFBundleIconName` is `AppIcon`.

