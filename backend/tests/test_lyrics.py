"""Test the lyrics service offline.

LRCLIB answers through a fake HTTP transport and YouTube Music through a fake object, both in the shapes the
real services return. Every word here is made up: real lyrics never go in the repo."""
import asyncio
import time
from types import SimpleNamespace
from uuid import uuid4

import httpx
import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.services import lyrics
from music_backend.core.http_client import SharedClient
from music_backend.sources import ytmusic
from music_backend.services.lyrics import LyricsNotFound, parse_lrc, plain_lines
from music_backend.models import LyricLine, Listing, LyricsRequest, LyricsResponse
from conftest import TEST_URL, sign_up


pytestmark = pytest.mark.usefixtures("no_catalog")

TIMED = {"instrumental": False, "plainLyrics": "first words\nsecond words", "syncedLyrics": "[00:01.50] first words\n[00:03.00] second words"}
PLAIN = {"instrumental": False, "plainLyrics": "first words\n\nsecond words", "syncedLyrics": None}
INSTRUMENTAL = {"instrumental": True, "plainLyrics": None, "syncedLyrics": None}


@pytest.fixture
def lrclib(monkeypatch):
    """Set what the fake LRCLIB answers: a status and body, or an exception. Record every request."""
    state = {"status": 404, "body": {"name": "TrackNotFound"}, "raise": None, "requests": []}

    def handler(request):
        state["requests"].append(request)
        if state["raise"]:
            raise state["raise"]
        return httpx.Response(state["status"], json=state["body"])
    monkeypatch.setattr(lyrics, "http", SharedClient(transport=httpx.MockTransport(handler)))
    return state


class FakeYTMusic:
    """Stand in for ytmusicapi's two calls: get_watch_playlist returns a browse id or None, and get_lyrics
    returns a dict of LyricLine objects or a single string."""

    def __init__(self, browse_id="MPLYfake", timed=True, cue_range_bug=False):
        self.browse_id, self.timed, self.cue_range_bug, self.calls = browse_id, timed, cue_range_bug, 0

    def get_watch_playlist(self, videoId):
        self.calls += 1
        return {"lyrics": self.browse_id, "tracks": [], "playlistId": None, "related": None}

    def get_lyrics(self, browseId, timestamps=False):
        if timestamps and self.cue_range_bug:
            raise KeyError("cueRange")
        if timestamps and self.timed:
            return {"hasTimestamps": True, "source": "Source: Somewhere", "lyrics": [
                SimpleNamespace(text="la la", start_time=1000, end_time=2000, id=0),
                SimpleNamespace(text="na na", start_time=2500, end_time=4000, id=1)]}
        return {"hasTimestamps": False, "source": "Source: Somewhere", "lyrics": "la la\nna na"}


@pytest.fixture
def youtube(monkeypatch):
    fake = FakeYTMusic()
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    return fake


def song(youtube_id="vid", name="Song", artist="Artist", duration=200):
    return LyricsRequest(song_name=name, artist_name=artist, song_duration=duration, youtube_id=youtube_id)


async def find(request):
    reply, _ = await lyrics.find_lyrics(request)
    return reply


def texts(reply):
    return [line.text for line in reply.lines]


# ---------- parsing ----------

def test_lrc_lines_get_their_times_in_ms():
    assert [(l.start_ms, l.text) for l in parse_lrc("[00:19.12] hello\n[01:02.345] there")] == [(19120, "hello"), (62345, "there")]


def test_a_line_with_two_stamps_is_sung_twice():
    lines = parse_lrc("[00:10.00][00:30.00] chorus\n[00:20.00] verse")
    assert [(l.start_ms, l.text) for l in lines] == [(10000, "chorus"), (20000, "verse"), (30000, "chorus")]


def test_tag_lines_are_skipped_and_gaps_are_kept():
    lines = parse_lrc("[ar: Someone]\n[ti: Something]\n[00:01.00] words\n[00:05.00]\n[00:09.00] more")
    assert [(l.start_ms, l.text) for l in lines] == [(1000, "words"), (5000, ""), (9000, "more")]


def test_plain_lyrics_have_no_times_and_keep_verse_gaps():
    lines = plain_lines("one\n\ntwo\n")
    assert [(l.start_ms, l.text) for l in lines] == [(None, "one"), (None, ""), (None, "two")]


# ---------- choosing a source ----------

@pytest.mark.anyio
async def test_timed_lyrics_from_lrclib_and_youtube_is_not_asked(lrclib, youtube):
    lrclib.update(status=200, body=TIMED)
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("lrclib", True, ["first words", "second words"])
    assert [l.start_ms for l in reply.lines] == [1500, 3000]
    assert youtube.calls == 0


@pytest.mark.anyio
async def test_lrclib_gets_the_title_artist_and_duration(lrclib, youtube):
    lrclib.update(status=200, body=TIMED)
    await find(song(None, "Some Song", "Some Artist", 317))
    params = lrclib["requests"][0].url.params
    assert (params["track_name"], params["artist_name"], params["duration"]) == ("Some Song", "Some Artist", "317")


@pytest.mark.anyio
async def test_lrclib_saying_instrumental_still_asks_youtube(lrclib, youtube):
    lrclib.update(status=200, body=INSTRUMENTAL)
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("ytmusic", True, ["la la", "na na"])
    assert youtube.calls == 1


@pytest.mark.anyio
async def test_an_instrumental_everywhere_is_an_empty_reply(lrclib, youtube):
    lrclib.update(status=200, body=INSTRUMENTAL)
    youtube.browse_id = None
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, reply.lines) == (None, False, [])


@pytest.mark.anyio
@pytest.mark.parametrize("status,body", [(404, {"name": "TrackNotFound"}), (503, {"name": "ServerOverloaded"})])
async def test_both_kinds_of_lrclib_miss_go_to_youtube(lrclib, youtube, status, body):
    lrclib.update(status=status, body=body)
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("ytmusic", True, ["la la", "na na"])
    assert [l.start_ms for l in reply.lines] == [1000, 2500]


@pytest.mark.anyio
async def test_lrclib_timing_out_goes_to_youtube(lrclib, youtube):
    lrclib.update({"raise": httpx.ReadTimeout("too slow")})
    reply = await find(song())
    assert reply.lyrics_source == "ytmusic"


@pytest.mark.anyio
async def test_plain_from_lrclib_loses_to_timed_from_youtube(lrclib, youtube):
    lrclib.update(status=200, body=PLAIN)
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced) == ("ytmusic", True)


@pytest.mark.anyio
async def test_plain_from_lrclib_beats_plain_from_youtube(lrclib, youtube):
    lrclib.update(status=200, body=PLAIN)
    youtube.timed = False
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("lrclib", False, ["first words", "", "second words"])


@pytest.mark.anyio
async def test_plain_from_lrclib_without_a_youtube_id(lrclib, youtube):
    lrclib.update(status=200, body=PLAIN)
    reply = await find(song(None))
    assert (reply.lyrics_source, reply.synced) == ("lrclib", False)
    assert youtube.calls == 0


@pytest.mark.anyio
async def test_untimed_youtube_lyrics_are_lines_not_characters(lrclib, youtube):
    youtube.timed = False
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("ytmusic", False, ["la la", "na na"])
    assert all(l.start_ms is None for l in reply.lines)


@pytest.mark.anyio
async def test_the_cue_range_bug_falls_back_to_untimed(lrclib, youtube):
    youtube.cue_range_bug = True
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, texts(reply)) == ("ytmusic", False, ["la la", "na na"])


@pytest.mark.anyio
async def test_nothing_anywhere_is_an_empty_reply(lrclib, youtube):
    youtube.browse_id = None                   # YouTube Music: this song has no lyrics
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, reply.lines) == (None, False, [])


@pytest.mark.anyio
async def test_no_youtube_id_and_no_lrclib_is_an_empty_reply(lrclib, youtube):
    reply = await find(song(None))
    assert (reply.lyrics_source, reply.lines) == (None, [])
    assert youtube.calls == 0


@pytest.mark.anyio
async def test_youtube_failing_is_an_empty_reply_not_an_error(lrclib, monkeypatch):
    class Broken:
        def get_watch_playlist(self, videoId):
            raise RuntimeError("YouTube changed its page")
    monkeypatch.setattr(ytmusic, "client", lambda: Broken())
    reply = await find(song())
    assert (reply.lyrics_source, reply.lines) == (None, [])


@pytest.mark.anyio
async def test_youtube_runs_in_a_thread_so_the_server_keeps_answering(lrclib, monkeypatch):
    class Slow(FakeYTMusic):
        def get_watch_playlist(self, videoId):
            time.sleep(0.5)                    # blocking, like ytmusicapi's requests
            return super().get_watch_playlist(videoId)
    slow = Slow()
    monkeypatch.setattr(ytmusic, "client", lambda: slow)
    ticks = 0

    async def other_requests():
        nonlocal ticks
        while True:
            await asyncio.sleep(0.05)
            ticks += 1
    other = asyncio.create_task(other_requests())
    await find(song())
    other.cancel()
    assert ticks >= 5                          # about 10 in 0.5 s; 0 if the event loop had been blocked


@pytest.mark.anyio
async def test_cancelling_a_lookup_really_cancels_it(lrclib, monkeypatch):
    async def slow(request):
        await asyncio.sleep(5)
    monkeypatch.setitem(lyrics.LYRICS_SOURCES, "ytmusic", slow)   # LYRICS_SOURCES maps a name to the function itself
    task = asyncio.create_task(find(song()))
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task


# ---------- the loop over LYRICS_SOURCES ----------

def answer(source, synced, n=2):
    lines = [lyrics.LyricLine(start_ms=1000 * i if synced else None, text=f"{source} {i}") for i in range(n)]
    return LyricsResponse(lyrics_source=source, synced=synced, lines=lines)


def fake_source(result, asked):
    async def source(request):
        if isinstance(result, Exception):
            asked.append(type(result).__name__)
            raise result
        asked.append(result.lyrics_source)
        return result
    return source


@pytest.mark.anyio
async def test_sources_are_asked_in_order_and_timed_ends_the_search(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(answer("lrclib", synced=False), asked),
        "b": fake_source(answer("ytmusic", synced=True), asked),
        "c": fake_source(answer("lrclib", synced=True), asked)})
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced) == ("ytmusic", True)
    assert asked == ["lrclib", "ytmusic"]                  # c never asked: b was timed


@pytest.mark.anyio
async def test_the_first_plain_answer_is_kept_when_nobody_has_timed(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(LyricsNotFound("none"), asked),
        "b": fake_source(answer("lrclib", synced=False), asked),
        "c": fake_source(answer("ytmusic", synced=False), asked)})
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced) == ("lrclib", False)
    assert len(asked) == 3                                 # every source is asked: a later one might have had timed


@pytest.mark.anyio
async def test_a_source_with_no_lines_does_not_stop_the_search(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(answer("lrclib", synced=False, n=0), asked),
        "b": fake_source(answer("ytmusic", synced=False), asked)})
    reply = await find(song())
    assert (reply.lyrics_source, len(reply.lines)) == ("ytmusic", 2)


@pytest.mark.anyio
async def test_a_source_that_crashes_is_skipped(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(RuntimeError("bug"), asked),
        "b": fake_source(answer("ytmusic", synced=True), asked)})
    assert (await find(song())).lyrics_source == "ytmusic"


@pytest.mark.anyio
async def test_every_source_failing_is_an_empty_reply(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(LyricsNotFound("none"), asked), "b": fake_source(RuntimeError("bug"), asked)})
    reply = await find(song())
    assert (reply.lyrics_source, reply.synced, reply.lines) == (None, False, [])


@pytest.mark.anyio
async def test_the_flag_says_whether_every_source_answered(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(LyricsNotFound("none"), asked), "b": fake_source(answer("ytmusic", synced=False), asked)})
    assert (await lyrics.find_lyrics(song()))[1] is True          # "not here" is an answer
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {
        "a": fake_source(RuntimeError("bug"), asked), "b": fake_source(answer("ytmusic", synced=True), asked)})
    reply, every_source_answered = await lyrics.find_lyrics(song())
    assert reply.synced and every_source_answered is False       # timed, but a source failed: the flag says so


@pytest.mark.anyio
async def test_lrclib_answering_400_is_skipped_not_fatal(lrclib, youtube):
    lrclib.update(status=400, body={"error": "missing artist"})
    assert (await find(song())).lyrics_source == "ytmusic"


# ---------- the endpoint ----------

@pytest.fixture
def server(monkeypatch, lrclib, youtube):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        yield client
    with psycopg.connect(TEST_URL) as conn:      # the cache stored these answers: remove them
        conn.execute("DELETE FROM lyrics WHERE song_name LIKE 'lyrics-test-%'")


def unique():
    return f"lyrics-test-{uuid4().hex[:8]}"


def test_post_lyrics_answers_lines(server, lrclib):
    lrclib.update(status=200, body=TIMED)
    r = server.post("/lyrics", json={"song_name": unique(), "artist_name": "Artist", "song_duration": 200, "youtube_id": "vid"})
    assert r.status_code == 200
    assert r.json() == {"lyrics_source": "lrclib", "synced": True,
                        "lines": [{"start_ms": 1500, "text": "first words"}, {"start_ms": 3000, "text": "second words"}]}


def test_post_lyrics_with_nothing_found_is_still_200(server, lrclib, youtube):
    youtube.browse_id = None
    r = server.post("/lyrics", json={"song_name": unique(), "artist_name": "Artist", "song_duration": 200})
    assert (r.status_code, r.json()) == (200, {"lyrics_source": None, "synced": False, "lines": []})


@pytest.mark.parametrize("missing", ["song_name", "artist_name", "song_duration"])
def test_post_lyrics_needs_title_artist_and_duration(server, missing):
    body = {"song_name": "Song", "artist_name": "Artist", "song_duration": 200}
    del body[missing]
    assert server.post("/lyrics", json=body).status_code == 422


def test_shutdown_closes_the_lrclib_connection(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app):
        client = lyrics.http.client
    assert client.is_closed


def test_a_translation_after_a_caret_is_split_off_the_line():
    # an LRCLIB upload's "original^translation" line (seen on one song); cached replies are split the same way
    line = parse_lrc("[00:12.00]Despacito^Slowly")[0]
    cached = LyricsResponse.model_validate({"lyrics_source": "lrclib", "synced": True,
                                            "lines": [{"start_ms": 12000, "text": "Despacito^Slowly"}]}).lines[0]
    assert (line.text, line.translation) == ("Despacito", "Slowly") == (cached.text, cached.translation)
    assert parse_lrc("[00:12.00]Plain line")[0].translation is None


def lrclib_knowing(name: str, artist: str, asked: list):
    """A fake LRCLIB with timed lyrics for one song only, noting each (title, artist, length) it is asked for."""
    async def lrclib(song):
        asked.append((song.song_name, song.artist_name, song.song_duration))
        if (song.song_name, song.artist_name) == (name, artist):
            return LyricsResponse(lyrics_source="lrclib", synced=True, lines=[LyricLine(start_ms=0, text="la")])
        raise lyrics.LyricsNotFound("no")
    return lrclib


def catalog_with(*listings: Listing, queries: list | None = None):
    async def search(query):
        if queries is not None:
            queries.append(query)
        return list(listings)
    return search


def ytmusic_copy(title: str, artists: list[str], duration: int) -> Listing:
    return Listing(source="ytmusic", id="catalog0001", title=title, artists=artists, album=None, duration=duration, popularity=None)


@pytest.mark.anyio
async def test_a_youtube_upload_stored_under_its_channel_finds_its_lyrics_as_the_catalogue_names_it(monkeypatch):
    asked, queries = [], []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("slow days", "Lomtre", asked)})
    monkeypatch.setattr(lyrics.ytmusic, "search", catalog_with(ytmusic_copy("slow days", ["Lomtre"], 165), queries=queries))
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="Lomtre - slow days", artist_name="Ikigai", song_duration=165))
    assert queries == ["Lomtre - slow days"]
    assert found.synced and asked == [("Lomtre - slow days", "Ikigai", 165), ("slow days", "Lomtre", 165)]


@pytest.mark.anyio
async def test_an_upload_the_catalogues_do_not_know_is_asked_as_both_readings_of_its_title(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("Lomtre", "slow days", asked)})
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="Lomtre - slow days", artist_name="Ikigai", song_duration=165))
    assert found.synced
    assert asked == [("Lomtre - slow days", "Ikigai", 165), ("slow days", "Lomtre", 165), ("Lomtre", "slow days", 165)]


@pytest.mark.anyio
async def test_a_title_without_two_sides_is_not_read(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("x", "y", asked)})
    await lyrics.find_lyrics(LyricsRequest(song_name="Coke Studio | Season 14 | Pasoori", artist_name="Coke Studio Pakistan", song_duration=228))
    assert asked == [("Coke Studio | Season 14 | Pasoori", "Coke Studio Pakistan", 228)]


@pytest.mark.anyio
async def test_a_song_named_properly_is_asked_once(monkeypatch):
    asked, queries = [], []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("nothing", "nobody", asked)})
    monkeypatch.setattr(lyrics.ytmusic, "search", catalog_with(queries=queries))
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="Kesariya", artist_name="Arijit Singh", song_duration=268))
    assert not found.lines and len(asked) == 1 and queries == []


@pytest.mark.anyio
async def test_a_song_the_catalogues_know_is_asked_as_they_name_it(monkeypatch):
    asked, queries = [], []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("Pasoori", "Ali Sethi", asked)})
    monkeypatch.setattr(lyrics.ytmusic, "search", catalog_with(ytmusic_copy("Pasoori", ["Ali Sethi", "Shae Gill"], 224), queries=queries))
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="Coke Studio | Season 14 | Pasoori | Ali Sethi x Shae Gill",
                                                      artist_name="Coke Studio Pakistan", song_duration=228))
    # searched by the video's own title; asked with the catalogue's length; 4 s apart, so still timed
    assert queries == ["Coke Studio | Season 14 | Pasoori | Ali Sethi x Shae Gill"]
    assert asked[-1] == ("Pasoori", "Ali Sethi", 224) and found.synced


@pytest.mark.anyio
async def test_a_music_video_longer_than_the_song_gets_its_words_without_times(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("Blinding Lights", "The Weeknd", asked)})
    monkeypatch.setattr(lyrics.ytmusic, "search", catalog_with(ytmusic_copy("Blinding Lights", ["The Weeknd"], 202)))
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="The Weeknd - Blinding Lights (Official Video)",
                                                      artist_name="TheWeekndVEVO", song_duration=263))
    assert asked[1] == ("Blinding Lights", "The Weeknd", 202)
    assert not found.synced and [(line.start_ms, line.text) for line in found.lines] == [(None, "la")]


@pytest.mark.anyio
async def test_a_song_of_the_same_name_and_length_by_an_artist_the_video_never_names_is_not_the_song(monkeypatch):
    asked = []
    monkeypatch.setattr(lyrics, "LYRICS_SOURCES", {"lrclib": lrclib_knowing("Blinding Lights", "Rising Insane", asked)})
    monkeypatch.setattr(lyrics.ytmusic, "search", catalog_with(ytmusic_copy("Blinding Lights", ["Rising Insane"], 263)))
    found, _ = await lyrics.find_lyrics(LyricsRequest(song_name="The Weeknd - Blinding Lights (Official Video)",
                                                      artist_name="TheWeekndVEVO", song_duration=263))
    assert not found.lines and ("Blinding Lights", "Rising Insane", 263) not in asked
