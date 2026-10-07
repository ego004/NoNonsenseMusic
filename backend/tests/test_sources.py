"""How each source's failures become our source errors (no network: yt-dlp and JioSaavn's replies are fakes)."""
import logging
import time

import httpx
import pytest
from yt_dlp.networking.exceptions import TransportError
from yt_dlp.utils import DownloadError, ExtractorError

from music_backend.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable, jiosaavn, ytmusic


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


# ---------- BUG-3 and BUG-4: JioSaavn's bad replies ----------

def fake_jiosaavn(monkeypatch, status=200, text=None, json=None):
    """JioSaavn answers this (HTML when `text` is given, else JSON), without the internet."""
    def handler(request):
        return httpx.Response(status, text=text) if text is not None else httpx.Response(status, json=json)
    monkeypatch.setattr(jiosaavn, "http", SharedClient(transport=httpx.MockTransport(handler)))


# one case per way the lookup can fail; each crashed (a 500 from /play) or said the wrong thing before BUG-3
@pytest.mark.anyio
@pytest.mark.parametrize("status, reply, expected", [
    (429, {"json": {"msg": "Too many requests"}}, SourceBlocked),              # slow down: the back-off pauses JioSaavn
    (503, {"text": "<html>Service Unavailable</html>"}, SourceUnavailable),
    (200, {"text": "<html>Down for maintenance</html>"}, SourceUnavailable),
    (200, {"json": {"songs": []}}, SongNotFound),
    (200, {"json": {"songs": [{"more_info": {}}]}}, SongNotFound),            # no audio URL
    (200, {"json": {"songs": [{"more_info": {"encrypted_media_url": "garbled"}}]}}, SourceUnavailable),
])
async def test_a_bad_jiosaavn_reply_becomes_one_of_our_errors(monkeypatch, status, reply, expected):
    fake_jiosaavn(monkeypatch, status, **reply)
    with pytest.raises(expected) as raised:
        await jiosaavn.get_song_url("abc123")
    assert str(raised.value)                                 # with a message: the log says why


def jiosaavn_row(i, **more_info):
    """One search result, shaped like JioSaavn's; `more_info` overrides its fields."""
    return {"id": f"id{i}", "title": f"Song {i}", "image": "", "explicit_content": "0",
            "more_info": {"artistMap": {"primary_artists": [{"name": "Artist"}]}, "album": "Album", "duration": "200"} | more_info}


@pytest.mark.anyio
async def test_one_odd_jiosaavn_row_is_skipped_not_the_whole_search(monkeypatch, caplog):
    # BUG-4: one odd row lost all 20 (JioSaavn reported unhealthy, 0 results)
    odd = [jiosaavn_row(2, duration=""),                    # a value Listing refuses
           {"id": "id4", "title": "Song 4"}]                # no more_info at all
    fake_jiosaavn(monkeypatch, json={"results": [jiosaavn_row(1), *odd, jiosaavn_row(3)]})
    with caplog.at_level(logging.WARNING, logger="music_backend.sources.jiosaavn"):
        listings = await jiosaavn.search("anything")
    assert [listing.id for listing in listings] == ["id1", "id3"]
    assert len([r for r in caplog.records if "skipped" in r.getMessage()]) == 2   # one line per skipped row
