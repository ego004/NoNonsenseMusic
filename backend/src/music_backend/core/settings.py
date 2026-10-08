"""Settings, read once from backend/.env. A variable set in the real environment wins over the file.

Use it anywhere:   from music_backend.core.settings import settings   ->   settings.cache_max_size
Add a setting:     a field here, plus the same name in UPPER_CASE in .env and .env.example.
A key in .env that has no field here stops the server at startup (that catches typos).
"""
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# an absolute path, so .env is found whichever folder the server is started from
ENV_FILE = Path(__file__).resolve().parents[3] / ".env"   # backend/.env (this file: backend/src/music_backend/core/)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=ENV_FILE,
        env_parse_none_str="None",   # KEY="None" means Python None
        env_ignore_empty=True,       # KEY= (nothing) means "not set": the default below is used
    )

    # no host or password: connect over the local socket as the current macOS user
    database_url: str = "postgresql:///music"
    # minutes: a cached YouTube URL this close to its expire= time is fetched again
    youtube_cache_expiry_threshold: int = 30
    # prefetch workers: at most this many prefetch lookups at once (yt-dlp shares its threads with your clicks)
    num_prefetch_workers: int = 4
    # minutes: after a source's first bot check, ask it nothing for this long; each bot check in a row doubles it
    backoff_start_minutes: float = 2
    # minutes: the pause never grows past this, so a lifted block is noticed within this long
    backoff_max_minutes: float = 60
    # entries in the cache's memory before the least recently used one is dropped
    cache_max_size_in_memory: int = 3000
    # rows in the listing_urls table: after each write, the oldest-fetched beyond this are deleted
    cache_max_size_in_db: int = 6000
    # days: plain or empty lyrics are asked for again after this long (timed lyrics are kept for good)
    lyrics_recheck_days: float = 7
    # Genius notes (experimental): the official API's token, used only when the website's own API fails. None: no
    # fallback (the official API answers 401 without one). Get one at genius.com/api-clients
    genius_access_token: str | None = None
    # days: a song's Genius notes are asked for again after this long (people keep adding notes)
    genius_recheck_days: float = 30

    # days: a session (one signed-in device) not used for this long ends; each use pushes the end forward (AUTH-1)
    session_days: int = 30
    # minutes: a session's end is pushed forward at most this often, so most requests only read their session
    # instead of writing it (a write on every request was the cost; a 30-day window does not care about an hour)
    session_slide_minutes: int = 60
    session_cleanup_hours: int = 6       # how often expired sessions are deleted (AUTH-1, 8 Oct)


settings = Settings()
