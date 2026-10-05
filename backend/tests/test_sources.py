"""How yt-dlp's errors become our two source errors (no network: yt-dlp is replaced by a fake)."""
import pytest
from yt_dlp.networking.exceptions import TransportError
from yt_dlp.utils import DownloadError, ExtractorError

from music_backend.sources import SongNotFound, SourceUnavailable, ytmusic


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


def test_bot_check_means_the_source_is_unavailable(monkeypatch):
    # the exact wording yt-dlp gave on 5 Oct 2026; note the curly apostrophe
    bot = ExtractorError("[youtube] J7p4bzqLvCw: Sign in to confirm you’re not a bot. Use --cookies-from-browser", expected=True)
    monkeypatch.setattr(ytmusic, "YoutubeDL", fake_ytdlp_raising(bot))
    with pytest.raises(SourceUnavailable):
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
