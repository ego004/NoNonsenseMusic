"""How yt-dlp's errors become our two source errors (no network: yt-dlp is replaced by a fake)."""
import time

import pytest
from yt_dlp.networking.exceptions import TransportError
from yt_dlp.utils import DownloadError, ExtractorError

from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable, ytmusic


def fake_ytdlp_raising(inner):
    """A stand-in for YoutubeDL whose extract_info fails the way yt-dlp does: a DownloadError wrapping the real error."""
    class FakeYoutubeDL:
        def __init__(self, options):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False
        def extract_info(self, url, download):
            raise DownloadError(f"ERROR: {inner}", exc_info=(type(inner), inner, None))
    return FakeYoutubeDL


def test_bot_check_means_the_source_is_blocked(monkeypatch):
    # the exact wording yt-dlp gave on 5 Oct 2026; note the curly apostrophe
    bot = ExtractorError("[youtube] J7p4bzqLvCw: Sign in to confirm you’re not a bot. Use --cookies-from-browser", expected=True)
    monkeypatch.setattr(ytmusic, "YoutubeDL", fake_ytdlp_raising(bot))
    with pytest.raises(SourceBlocked):         # a kind of SourceUnavailable: still a 502
        ytmusic.extract_audio_url("J7p4bzqLvCw")


def test_unavailable_video_means_the_song_is_not_found(monkeypatch):
    gone = ExtractorError("[youtube] AAAAAAAAAAA: Video unavailable", expected=True)
    monkeypatch.setattr(ytmusic, "YoutubeDL", fake_ytdlp_raising(gone))
    with pytest.raises(SongNotFound):
        ytmusic.extract_audio_url("AAAAAAAAAAA")


def test_network_failure_means_the_source_is_unavailable(monkeypatch):
    monkeypatch.setattr(ytmusic, "YoutubeDL", fake_ytdlp_raising(TransportError("connection reset")))
    with pytest.raises(SourceUnavailable):
        ytmusic.extract_audio_url("J7p4bzqLvCw")


# ---------- BUG-1: reading a YouTube link's expiry ----------
# Made-up links only: a real one carries your IP address. The margin is the setting's (30 min in .env.example).

MARGIN = ytmusic.settings.youtube_cache_expiry_threshold * 60


def query_link(expires_at: float) -> str:
    return f"https://audio.example/videoplayback?id=abc&expire={int(expires_at)}&n=1"


def test_a_link_with_hours_left_is_fresh():
    assert ytmusic.is_expired(query_link(time.time() + MARGIN + 3600)) is False


def test_a_link_inside_the_margin_is_stale():
    assert ytmusic.is_expired(query_link(time.time() + MARGIN / 2)) is True       # it would die during the song


def test_a_link_already_past_is_stale():
    assert ytmusic.is_expired(query_link(time.time() - 60)) is True


def test_a_link_with_its_expiry_in_the_path_does_not_crash():
    # BUG-1: re.search found nothing, .group(1) raised AttributeError, and /play answered 500 on every play.
    # Your decision (7 Oct): a link whose expiry cannot be read counts as fresh (see is_expired's docstring)
    path_link = f"https://audio.example/videoplayback/expire/{int(time.time() - 60)}/id/abc"
    assert ytmusic.is_expired(path_link) is False


def test_a_link_with_no_expiry_at_all_does_not_crash():
    assert ytmusic.is_expired("https://audio.example/videoplayback?id=abc") is False
