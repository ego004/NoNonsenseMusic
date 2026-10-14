<div align="center">

# NoNonsenseMusic

A native macOS music player, designed with care.

[![Platforms](https://img.shields.io/badge/platforms-macOS%20·%20Windows%20·%20Android-111?style=flat-square)](#getting-started)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](mac)
[![Flutter](https://img.shields.io/badge/Flutter-3-02569B?style=flat-square&logo=flutter&logoColor=white)](app)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=flat-square&logo=python&logoColor=white)](backend)
[![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white)](backend)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)](backend/migrations)
[![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f?style=flat-square)](#privacy)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square)](#license)

<img src=".github/screenshots/home.png" alt="NoNonsenseMusic on a Mac" width="860">

</div>

NoNonsenseMusic is a music player built natively for macOS, featuring a refined user experience, privacy and customizability. It collects no telemetry. Windows and Android support (via Flutter) is experimental and under development.

The apps connect to a small server, which you can run yourself or share with friends.

- One search across JioSaavn, YouTube Music and YouTube, with each song listed once
- Accounts for several people on one server
- Playlists shared with friends, or with anyone through a link
- Jams, where friends listen together and share one queue
- Timed lyrics with translation, and optional annotations from Genius
- Downloads for listening offline
- Autoplay when the queue runs out
- About 0.3% CPU when idle on a Mac

## Getting started

You need two things: the app, and a server for it to connect to. You can run the server on your own computer for personal use, or host it online so that friends can join you.

### The app

Download the Mac, Windows or Android app from the [latest release](../../releases/latest). The release notes explain how to connect it to a server.

The Mac app runs on macOS 15 or later. On macOS 26 it uses Liquid Glass and translates on the device; on macOS 15 it uses the older materials and translates online. To build it yourself, you need Xcode 26:

```bash
brew install xcodegen
cd mac
xcodegen
xcodebuild -project NoNonsense.xcodeproj -scheme NoNonsense -configuration Release -derivedDataPath build build
open build/Build/Products/Release/NoNonsenseMusic.app
```

To build the Windows or Android app yourself, you need Flutter 3:

```bash
cd app
flutter run -d windows    # or: flutter run -d <android device>
```

### The server

See [Running a server](#running-a-server) below.

## Features

### Search
JioSaavn, YouTube Music and YouTube are used as search sources currently; more may be added later. When the same recording appears on more than one of them, it is shown as a single song, and the best copy is the one that plays. You can choose a preferred source in Settings, and filter results to songs, artists or albums.

<img src=".github/screenshots/search.png" alt="Search" width="760">

### Artists and albums
Every artist and album has its own page, opened by clicking its name anywhere in the app. Albums can be pinned to Home.

<img src=".github/screenshots/artist.png" alt="An artist page" width="760">

### Lyrics and translation
Lyrics are fetched from several sources, currently LRCLIB and YouTube Music, and shown in the lyrics pane when found. Timed lyrics follow the song. Lyrics in another language can be translated line by line. On a Mac, translation runs on the device with Apple's Translation framework. Languages it does not support, such as Punjabi, are translated via Google Translate. Annotations from Genius can be turned on in Settings.

<img src=".github/screenshots/lyrics.png" alt="Lyrics and translation" width="760">

### Playback, caching and downloads
Songs are cached on your device and search results on the server, and the next song is fetched in advance, so playback starts quickly. Downloaded songs and playlists play without an internet connection. On Android, music keeps playing in the background with lock-screen controls, and a home-screen widget plays, skips and likes without opening the app.

### Autoplay
When the queue ends, Autoplay continues with similar songs. They appear in Up Next (under their own heading) after the songs you added.

### Jams
A jam lets friends listen together. Every device in the jam plays the music, in step, and everyone can add songs and control playback. The host can choose to play the jam on their device alone (friends in one room, one set of speakers), or to control playback alone. You can invite friends from the jam, or share its code.

<img src=".github/screenshots/jam.png" alt="A jam" width="520">

### Friends and sharing
You can add friends by their username and share a playlist with them as a viewer or an editor, or make it public with a link. Friend requests, shared playlists and jam invitations arrive as notifications.

<img src=".github/screenshots/friends.png" alt="Friends" width="760">

### Accounts
An account needs only a username and a password, with no email address. In the current server, a forgotten password is reset with a recovery code. Ten codes are shown once, when the account is created. These codes can be regenerated at any time via Settings.

## On the Mac

The Mac app is written in SwiftUI and follows the platform closely.

- Pinch out on the player bar to open Now Playing, and pinch in to close it.
- On a Force Touch trackpad, scrubbing, reordering a playlist and errors give haptic feedback.
- The window's transparency can be adjusted, and its background takes its colours from the current cover.
- Lyrics are translated on the device for the languages Apple supports.
- Media keys and Control Center control playback.
- Keyboard shortcuts cover playback, volume, search and lyrics.
- What you are listening to can be shown on your Discord profile.
- Settings › Footprint shows the CPU and memory the app is using.
- Started from the repository, the app starts the server itself when none is running.

## Privacy

- The apps collect no telemetry, analytics or crash reports.
- YouTube links are looked up by your own device, not by the server.
- Once per launch, the apps ask GitHub whether a newer version exists. Settings can turn this off.
- The server does not log IP addresses, searches or passwords.
- Your library is stored in your server's database.

## Running a server

The server needs PostgreSQL 18 and Python 3.13, which [uv](https://docs.astral.sh/uv/) installs for you. It creates its tables when it first starts.

**macOS**

```bash
brew install postgresql@18 uv
brew services start postgresql@18
"$(brew --prefix postgresql@18)/bin/createdb" music
```

**Linux** (Debian or Ubuntu)

```bash
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt install -y postgresql-18
sudo -u postgres createuser --superuser "$USER"
createdb music
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Windows**

Install [WSL](https://learn.microsoft.com/windows/wsl/install) with `wsl --install`, then follow the Linux steps inside it.

**Then, on any system**

```bash
cd backend
cp .env.example .env
uv run fastapi run src/music_backend/main.py --port 8000
```

Open `http://127.0.0.1:8000/health` to check that it is running.

JioSaavn's audio addresses are encrypted, and the key is not included in this repository. Without `JIOSAAVN_KEY` in `.env`, JioSaavn results still appear, and the apps play another copy of the song.

### On the internet

To share the server with friends, run it on a machine they can reach, behind a reverse proxy such as Caddy or nginx that provides HTTPS. Use this command instead:

```bash
uv run uvicorn music_backend.main:app --host 127.0.0.1 --port 8000 --workers 1 --no-access-log --no-proxy-headers
```

Set `TRUSTED_PROXIES` in `.env` to the proxy's address, so that rate limits apply to each user rather than to the proxy. The server reads forwarded addresses only from that proxy, which is why uvicorn's own handling is turned off. Run a single worker: jam rooms, live notifications and rate limits are kept in the server's memory.

## Thanks

NoNonsenseMusic is made by ego004, with special thanks to:

- **[@vivekkk77](https://github.com/vivekkk77)**, for the Windows app, jams where everyone hears the music, the Downloads page, the smoother volume slider, and performance work across the server and every app.
- **[@SingeyDorje21](https://github.com/SingeyDorje21)**, for the phone redesign, the Android home-screen widget, and testing on Windows.

## Sources and licences

NoNonsenseMusic does not host any music. Audio, lyrics and artwork are retrieved from third-party services at the user's request. JioSaavn, YouTube Music, YouTube, LRCLIB, Genius and Google Translate belong to their respective owners, and this project is not affiliated with or endorsed by any of them. Users are responsible for using these services in accordance with their terms and with the copyright law of their country.

The project depends on open-source software, each under its own licence, including (but not limited to):

| Software | Licence |
|---|---|
| FastAPI | MIT |
| Uvicorn | BSD-3-Clause |
| psycopg 3 | LGPL-3.0 |
| ytmusicapi | MIT |
| yt-dlp | Unlicense |
| Flutter | BSD-3-Clause |
| just_audio | MIT |

## License

Copyright © 2026 ego004.

NoNonsenseMusic is free software, released under the [GNU Affero General Public License v3.0](LICENSE). You may use, study, change and share it. If you distribute a changed version, or run one as a service for others, you must publish its source code under the same licence.
