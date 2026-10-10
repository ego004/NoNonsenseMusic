"""How each source's failures become our source errors (no network: yt-dlp and JioSaavn's replies are fakes)."""
import json
import logging
import time
from pathlib import Path

import httpx
import pytest
from yt_dlp.networking.exceptions import TransportError
from yt_dlp.utils import DownloadError, ExtractorError

from music_backend.core.http_client import SharedClient
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable, jiosaavn, ytmusic, youtube


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


# ---------- MUS-13: plain YouTube as a source ----------

def test_youtube_bot_check_means_the_source_is_blocked(monkeypatch):
    bot = ExtractorError("[youtube] J7p4bzqLvCw: Sign in to confirm you’re not a bot. Use --cookies-from-browser", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(bot))
    with pytest.raises(SourceBlocked):
        youtube.extract_audio_url("J7p4bzqLvCw")


def test_youtube_unavailable_video_means_the_song_is_not_found(monkeypatch):
    gone = ExtractorError("[youtube] AAAAAAAAAAA: Video unavailable", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(gone))
    with pytest.raises(SongNotFound):
        youtube.extract_audio_url("AAAAAAAAAAA")


def test_youtube_network_failure_means_the_source_is_unavailable(monkeypatch):
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(TransportError("connection reset")))
    with pytest.raises(SourceUnavailable):
        youtube.extract_audio_url("J7p4bzqLvCw")


def test_youtube_link_expiry_uses_the_same_rule_as_youtube_music():
    # same URL format, same setting; one test here, the behaviour is exercised fully above for ytmusic
    assert youtube.is_expired(query_link(time.time() + MARGIN + 3600)) is False
    assert youtube.is_expired(query_link(time.time() - 60)) is True


def test_youtube_parses_a_real_search_reply():
    samples = Path(__file__).parent.parent / "samples"
    reply = json.loads((samples / "youtube_search.json").read_text())
    rows = youtube.video_rows(reply)
    assert len(rows) >= 5                                        # the reply also holds playlists and shelves
    listing = youtube.to_listing(rows[0])
    assert listing.source == "youtube"
    assert listing.title == "The Weeknd - Blinding Lights (Official Video)"   # RAW: no keyword cleanup (MUS-13)
    assert listing.artists == ["The Weeknd"]                     # the channel, one artist
    assert listing.album is None                                 # plain YouTube search rows carry no album
    assert listing.duration == 263                               # "4:23"
    assert listing.popularity == 1_071_511_379                   # "1,071,511,379 views"
    assert "hq720" in listing.image


def fake_youtube(monkeypatch, json=None):
    """Plain YouTube answers this, without the internet."""
    def handler(request):
        return httpx.Response(200, json=json)
    monkeypatch.setattr(youtube, "http", SharedClient(transport=httpx.MockTransport(handler)))


@pytest.mark.anyio
async def test_youtube_a_live_row_without_a_duration_is_skipped(monkeypatch, caplog):
    good = {"videoId": "abc", "title": {"runs": [{"text": "A Song"}]},
            "ownerText": {"runs": [{"text": "A Channel"}]}, "lengthText": {"simpleText": "3:20"},
            "viewCountText": {"simpleText": "1,000 views"},
            "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/abc/hq720.jpg"}]}}
    live = {"videoId": "live1", "title": {"runs": [{"text": "Live now"}]},
            "ownerText": {"runs": [{"text": "A Channel"}]}}                    # no lengthText
    reply = {"contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {"contents": [
        {"itemSectionRenderer": {"contents": [{"videoRenderer": good}, {"videoRenderer": live},
                                              {"lockupViewModel": {}}]}}]}}}}}
    fake_youtube(monkeypatch, json=reply)
    with caplog.at_level(logging.WARNING, logger="music_backend.sources.youtube"):
        listings = await youtube.search("anything")
    assert [listing.id for listing in listings] == ["abc"]
    assert "skipped" in caplog.text


@pytest.mark.anyio
async def test_youtube_a_live_stream_title_without_views_still_yields_a_listing(monkeypatch):
    # no viewCountText: popularity unknown, but the row must survive (views_of returns None)
    row = {"videoId": "abc", "title": {"runs": [{"text": "A Song"}]},
           "ownerText": {"runs": [{"text": "A Channel"}]}, "lengthText": {"simpleText": "1:02:03"}}
    reply = {"contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {"contents": [
        {"itemSectionRenderer": {"contents": [{"videoRenderer": row}]}}]}}}}}
    fake_youtube(monkeypatch, json=reply)
    listings = await youtube.search("anything")
    assert listings[0].duration == 3723                           # h:m:s parsed too
    assert listings[0].popularity is None
    assert listings[0].image is None


# ---------- MUS-20: the per-source album/artist searches ----------

@pytest.mark.anyio
async def test_jiosaavn_album_search_parses_results(monkeypatch):
    fake_jiosaavn(monkeypatch, json={"results": [
        {"id": "al1", "title": "After Hours", "subtitle": "The Weeknd", "year": "2020",
         "image": "https://x/150x150/abc.jpg", "list_count": "0", "explicit_content": "1",
         "more_info": {"song_count": "14"}},                        # the real count is more_info.song_count
        {"id": "bad", "title": "No Subtitle"},                      # no subtitle/artists: still fine (empty list)
        {"id": "bad2"},                                             # no title at all: skipped
    ]})
    albums = await jiosaavn.search_albums("after hours")
    assert [a.id for a in albums] == ["al1", "bad"]
    first = albums[0]
    assert (first.source, first.title, first.artists, first.year) == ("jiosaavn", "After Hours", ["The Weeknd"], 2020)
    assert first.song_count == 14 and first.explicit is True
    assert "500x500" in first.image                                  # 150x150 cover rewritten to the large one
    assert albums[1].artists == [] and albums[1].year is None        # missing fields stay unknown, not fatal


@pytest.mark.anyio
async def test_jiosaavn_artist_search_parses_results(monkeypatch):
    fake_jiosaavn(monkeypatch, json={"results": [
        {"name": "Arijit Singh", "id": "459320", "ctr": 459320, "entity": "artist",
         "image": "https://x/150x150/a.jpg"},
        {"id": "broken"},                                           # no name: skipped
    ]})
    artists = await jiosaavn.search_artists("arijit singh")
    assert [a.id for a in artists] == ["459320"]
    assert artists[0].name == "Arijit Singh"
    assert "500x500" in artists[0].image


class FakeYTMusic:
    """Stands in for ytmusicapi's client: answers with canned rows/pages (no network).

    search() serves the album/artist searches; get_album/get_artist serve the detail pages,
    looked up by id (a missing id raises KeyError exactly like ytmusicapi's nav()).
    """
    def __init__(self, albums=None, artists=None, album_pages=None, artist_page=None):
        self.albums, self.artists = albums or [], artists or []
        self.album_pages, self.artist_page = album_pages or {}, artist_page
        self.calls = []

    def search(self, query, filter=None, limit=None):
        self.calls.append((query, filter, limit))
        return self.albums if filter == "albums" else self.artists

    def get_album(self, browse_id):
        self.calls.append(("get_album", browse_id))
        if browse_id not in self.album_pages:
            raise KeyError(browse_id)
        return self.album_pages[browse_id]

    def get_artist(self, artist_id):
        self.calls.append(("get_artist", artist_id))
        if self.artist_page is None:
            raise KeyError(artist_id)
        return self.artist_page


@pytest.mark.anyio
async def test_ytmusic_album_search_parses_results(monkeypatch):
    fake = FakeYTMusic(albums=[
        {"browseId": "MPREb_1", "title": "After Hours", "artists": [{"name": "The Weeknd", "id": "UC1"}],
         "year": 2020, "thumbnails": [{"url": "small"}, {"url": "big"}], "isExplicit": True},
        {"title": "No BrowseId"},                                    # cannot be opened: skipped
    ])
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    albums = await ytmusic.search_albums("after hours")
    assert [a.id for a in albums] == ["MPREb_1"]
    first = albums[0]
    assert (first.source, first.title, first.artists, first.year) == ("ytmusic", "After Hours", ["The Weeknd"], 2020)
    assert first.image == "big"                                      # largest thumbnail wins
    assert first.explicit is True and first.song_count is None       # the search reply has no track count
    assert fake.calls == [("after hours", "albums", 20)]


@pytest.mark.anyio
async def test_ytmusic_artist_search_parses_results(monkeypatch):
    fake = FakeYTMusic(artists=[
        {"browseId": "UC1", "artist": "The Weeknd", "thumbnails": [{"url": "a"}, {"url": "b"}]},
    ])
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    artists = await ytmusic.search_artists("the weeknd")
    assert [a.id for a in artists] == ["UC1"]
    assert artists[0].name == "The Weeknd" and artists[0].image == "b"
    assert fake.calls == [("the weeknd", "artists", 20)]


@pytest.mark.anyio
async def test_youtube_channel_search_parses_results(monkeypatch):
    channel = {"channelId": "UC1", "title": {"simpleText": "The Weeknd - Topic"},   # channel rows use simpleText
               "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/x/default.jpg"}]}}
    items = [
        {"channelRenderer": channel},
        {"videoRenderer": {"videoId": "v1"}},                        # wrong kind: ignored
        {"channelRenderer": {"title": {"runs": []}}},                # no channelId: skipped
    ]
    reply = {"contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {
        "contents": [{"itemSectionRenderer": {"contents": items}}]}}}}}
    fake_youtube(monkeypatch, json=reply)
    artists = await youtube.search_artists("the weeknd")
    assert [a.id for a in artists] == ["UC1"]                        # the broken one (no channelId) was skipped
    assert artists[0].name == "The Weeknd - Topic"
    assert artists[0].source == "youtube"


# ---------- MUS-20: one album, one artist, per source ----------

def jiosaavn_track(i, title, duration, explicit="0"):
    """One track row from content.getAlbumDetails / topSongs: the same shape as a search row."""
    return {"id": f"t{i}", "title": title, "image": "https://x/150x150/t.jpg",
            "explicit_content": explicit, "play_count": "1000",
            "more_info": {"artistMap": {"primary_artists": [{"name": "The Weeknd"}]},
                          "album": "After Hours", "duration": str(duration)}}


@pytest.mark.anyio
async def test_jiosaavn_album_page_parses_its_tracks_in_order(monkeypatch):
    fake_jiosaavn(monkeypatch, json={
        "title": "After Hours", "year": "2020", "subtitle": "The Weeknd",
        "image": "https://x/150x150/ah.jpg", "explicit_content": "0",
        "list": [jiosaavn_track(1, "Alone Again", 240),
                 jiosaavn_track(2, "Blinding Lights", 200, explicit="1"),
                 {"id": "bad", "title": "No More Info"}],              # one odd row must not lose the album
    })
    album = await jiosaavn.get_album("19531208")
    assert (album.source, album.id, album.title, album.artists, album.year) == (
        "jiosaavn", "19531208", "After Hours", ["The Weeknd"], 2020)
    assert "500x500" in album.image
    # track order preserved, and every song is an ordinary score-0 song with one listing
    assert [s.title for s in album.songs] == ["Alone Again", "Blinding Lights"]
    assert album.songs[0].duration == 240
    assert all(s.score == 0 and len(s.listings) == 1 for s in album.songs)
    # explicit from any track, even though the album-level flag said "0"
    assert album.explicit is True


@pytest.mark.anyio
async def test_jiosaavn_a_made_up_album_id_is_none(monkeypatch):
    # a bad id answers 200 with title:"" and list:"" (empty strings, measured 10 Oct)
    fake_jiosaavn(monkeypatch, json={"title": "", "list": ""})
    assert await jiosaavn.get_album("nonsense") is None


@pytest.mark.anyio
@pytest.mark.parametrize("status, expected", [(429, SourceBlocked), (503, SourceUnavailable)])
async def test_jiosaavn_album_page_failures_become_our_errors(monkeypatch, status, expected):
    fake_jiosaavn(monkeypatch, status, json={"msg": "nope"})
    with pytest.raises(expected):
        await jiosaavn.get_album("19531208")


@pytest.mark.anyio
async def test_jiosaavn_artist_page_parses_bio_songs_and_albums(monkeypatch):
    fake_jiosaavn(monkeypatch, json={
        "name": "The Weeknd", "image": "https://x/150x150/w.jpg",
        "bio": json.dumps([{"text": "Abel Tesfaye."}, {"text": "Born in Toronto."}]),
        "follower_count": "3260092",
        "topSongs": [jiosaavn_track(1, "Blinding Lights", 200)],
        "topAlbums": [{"id": "al1", "title": "After Hours", "subtitle": "The Weeknd", "year": "2020",
                       "image": "https://x/150x150/ah.jpg", "explicit_content": "1",
                       "more_info": {"song_count": "14"}}],
    })
    artist = await jiosaavn.get_artist("615155")
    assert (artist.source, artist.id, artist.name) == ("jiosaavn", "615155", "The Weeknd")
    assert artist.bio == "Abel Tesfaye.\nBorn in Toronto."             # JSON pieces joined
    assert artist.followers == 3260092                                 # arrives as a string
    assert "500x500" in artist.image
    assert [s.title for s in artist.songs] == ["Blinding Lights"]
    assert [a.id for a in artist.albums] == ["al1"]
    assert artist.albums[0].song_count == 14 and artist.albums[0].year == 2020


@pytest.mark.anyio
async def test_jiosaavn_artist_page_empty_bio_and_missing_name(monkeypatch):
    fake_jiosaavn(monkeypatch, json={"name": "The Weeknd", "bio": "[]"})
    artist = await jiosaavn.get_artist("615155")
    assert artist.bio is None and artist.followers is None             # '[]' means no bio, not the text "[]"
    fake_jiosaavn(monkeypatch, json={"name": ""})                      # a bad id answers name:""
    assert await jiosaavn.get_artist("nonsense") is None


@pytest.mark.anyio
async def test_jiosaavn_artist_page_failure_becomes_our_error(monkeypatch):
    fake_jiosaavn(monkeypatch, 503, json={"msg": "nope"})
    with pytest.raises(SourceUnavailable):
        await jiosaavn.get_artist("615155")


def ytmusic_album_page():
    """One get_album reply, shaped like ytmusicapi's (measured 10 Oct)."""
    return {
        "title": "After Hours", "year": "2020", "artists": [{"name": "The Weeknd", "id": "UC1"}],
        "trackCount": 14, "isExplicit": False, "audioPlaylistId": "OLAK5uy_x",
        "thumbnails": [{"url": "small"}, {"url": "big"}],
        "tracks": [
            {"trackNumber": 1, "title": "Alone Again", "videoId": "v1",
             "artists": [{"name": "The Weeknd"}], "duration": "4:00", "duration_seconds": 240,
             "isExplicit": True, "album": "After Hours", "views": "54M plays",
             "thumbnails": [{"url": "https://i.ytimg.com/vi/v1/w120.jpg"}]},
            {"trackNumber": 2, "title": "No Video Id", "videoId": None, "duration_seconds": None},
            {"trackNumber": 3, "title": "Blinding Lights", "videoId": "v3", "artists": [],   # no artists: album's win
             "duration": "3:20", "duration_seconds": 200, "isExplicit": False, "album": "After Hours",
             "views": "1000 plays", "thumbnails": [{"url": "https://i.ytimg.com/vi/v3/w120.jpg"}]},
        ],
    }


@pytest.mark.anyio
async def test_ytmusic_album_page_parses_its_tracks(monkeypatch):
    fake = FakeYTMusic(album_pages={"MPREb_1": ytmusic_album_page()})
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    album = await ytmusic.get_album("MPREb_1")
    assert (album.source, album.id, album.title, album.artists, album.year) == (
        "ytmusic", "MPREb_1", "After Hours", ["The Weeknd"], 2020)
    assert album.image == "big"
    # track order kept; the track without a videoId is skipped, not fatal
    assert [s.title for s in album.songs] == ["Alone Again", "Blinding Lights"]
    assert album.songs[0].duration == 240 and album.songs[0].score == 0
    assert album.songs[0].best.popularity == 54_000_000                # "54M plays"
    assert album.songs[1].best.artists == ["The Weeknd"]               # empty artists fall back to the album's
    assert album.explicit is True                                      # one explicit track beats album-level False


@pytest.mark.anyio
async def test_ytmusic_a_made_up_album_id_is_none(monkeypatch):
    monkeypatch.setattr(ytmusic, "client", lambda: FakeYTMusic())      # get_album raises KeyError, like nav()
    assert await ytmusic.get_album("MPREb_nope") is None


@pytest.mark.anyio
async def test_ytmusic_artist_page_fills_durations_from_its_own_albums(monkeypatch, caplog):
    artist_page = {
        "name": "The Weeknd", "description": "Canadian singer.", "subscribers": "40.1M",
        "monthlyListeners": "240M", "thumbnails": [{"url": "a"}, {"url": "b"}],
        "songs": {"results": [
            {"videoId": "RmY", "title": "Save Your Tears",
             "artists": [{"name": "The Weeknd", "id": "UC1"}],
             "album": {"name": "After Hours", "id": "MPREb_1"}, "isExplicit": False,
             "thumbnails": [{"url": "s"}], "duration": None, "duration_seconds": None, "views": None},
            {"videoId": "Loose", "title": "No Album", "artists": [{"name": "The Weeknd"}],
             "album": None, "isExplicit": False, "thumbnails": [{"url": "s"}]},   # nowhere to look: 0
        ]},
        "albums": {"results": [
            {"title": "After Hours", "browseId": "MPREb_1", "audioPlaylistId": "OLAK", "year": "2020",
             "isExplicit": False, "thumbnails": [{"url": "a"}], "artists": []},   # no artists: the name wins
        ]},
        "singles": {"results": [
            {"title": "Popular", "browseId": "MPREb_2", "year": None, "isExplicit": True,
             "thumbnails": [{"url": "b"}], "artists": [{"name": "The Weeknd"}]},
        ]},
    }
    album_with_match = {"title": "After Hours", "artists": [{"name": "The Weeknd"}], "year": "2020",
                        "isExplicit": False, "thumbnails": [{"url": "x"}],
                        "tracks": [{"title": "Save Your Tears", "videoId": "other-id", "artists": [{"name": "The Weeknd"}],
                                    "duration_seconds": 216, "isExplicit": False, "album": "After Hours"}]}
    fake = FakeYTMusic(artist_page=artist_page, album_pages={"MPREb_1": album_with_match})
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    with caplog.at_level(logging.WARNING, logger="music_backend.sources.ytmusic"):
        artist = await ytmusic.get_artist("UC0WP5P-ufpRfjbNrmOWwLBQ")
    assert (artist.name, artist.bio, artist.image) == ("The Weeknd", "Canadian singer.", "b")
    assert artist.followers == 40_100_000 and artist.monthly_listeners == 240_000_000
    # duration found by title match inside the song's own album (216 s, measured 10 Oct)
    assert artist.songs[0].duration == 216
    assert artist.songs[1].duration == 0 and artist.songs[1].score == 0
    assert "no duration" in caplog.text                                # the unfilled one is logged
    # albums + singles as one list; an album with no artists falls back to the artist's name
    assert [a.id for a in artist.albums] == ["MPREb_1", "MPREb_2"]
    assert artist.albums[0].artists == ["The Weeknd"]
    assert artist.albums[1].explicit is True


@pytest.mark.anyio
async def test_ytmusic_a_made_up_artist_id_is_none(monkeypatch):
    monkeypatch.setattr(ytmusic, "client", lambda: FakeYTMusic())
    assert await ytmusic.get_artist("UCnope") is None


def fake_ytdlp_returning(reply):
    """A stand-in for YoutubeDL that returns `reply` (or raises it if it is an exception)."""
    class FakeYoutubeDL:
        def __init__(self, options):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False
        def extract_info(self, url, download):
            if isinstance(reply, Exception):
                raise reply
            return reply
    return FakeYoutubeDL


@pytest.mark.anyio
async def test_youtube_artist_page_parses_channel_videos(monkeypatch):
    info = {"channel": "The Weeknd", "channel_follower_count": 40100000,
            "thumbnails": [{"url": "https://x/channel.jpg"}, {"url": "https://x/channel_big.jpg"}],
            "entries": [
                {"id": "v1", "title": "Blinding Lights", "duration": 263, "view_count": 1000,
                 "thumbnails": [{"url": "https://x/v1.jpg"}]},
                {"id": "live", "title": "Live now", "duration": None},   # live: not playable, skipped
                None, {"id": "x"},                                       # odd entries: skipped
            ]}
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_returning(info))
    artist = await youtube.get_artist("UC0WP5P-ufpRfjbNrmOWwLBQ")
    assert (artist.source, artist.id, artist.name) == ("youtube", "UC0WP5P-ufpRfjbNrmOWwLBQ", "The Weeknd")
    assert artist.followers == 40100000
    assert artist.image == "https://x/channel_big.jpg"
    assert artist.bio is None and artist.albums == []                  # plain YouTube has neither
    assert [s.title for s in artist.songs] == ["Blinding Lights"]      # RAW title (MUS-13)
    assert artist.songs[0].best.artists == ["The Weeknd"]
    assert artist.songs[0].duration == 263 and artist.songs[0].best.popularity == 1000


@pytest.mark.anyio
async def test_youtube_a_channel_that_does_not_exist_is_none(monkeypatch):
    gone = ExtractorError("[youtube:tab] UCxxx: YouTube said: This channel does not exist.", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(gone))
    assert await youtube.get_artist("UCxxx") is None


@pytest.mark.anyio
async def test_youtube_a_malformed_channel_id_is_none_not_502(monkeypatch):
    # a too-short id never reaches "does not exist": the API answers HTTP 400 (measured live)
    bad = ExtractorError("[youtube:tab] UCxxx: Unable to download API page: HTTP Error 400: Bad Request")
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(bad))
    assert await youtube.get_artist("UCxxx") is None


@pytest.mark.anyio
async def test_youtube_artist_page_failures_become_our_errors(monkeypatch):
    bot = ExtractorError("[youtube] UCxxx: Sign in to confirm you’re not a bot", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(bot))
    with pytest.raises(SourceBlocked):
        await youtube.get_artist("UCxxx")
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(TransportError("connection reset")))
    with pytest.raises(SourceUnavailable):
        await youtube.get_artist("UCxxx")


# ---------- MUS-3: radio per source ----------

def fake_jiosaavn_radio(monkeypatch, station_reply=None, songs_reply=None,
                        station_status=200, songs_status=200):
    """JioSaavn answers the two radio calls (createEntityStation, then getSong), without the internet."""
    def handler(request):
        call = request.url.params.get("__call")
        if call == "webradio.createEntityStation":
            return httpx.Response(station_status, json=station_reply or {})
        return httpx.Response(songs_status, json=songs_reply or {})
    monkeypatch.setattr(jiosaavn, "http", SharedClient(transport=httpx.MockTransport(handler)))


@pytest.mark.anyio
async def test_jiosaavn_radio_parses_station_songs(monkeypatch):
    song = jiosaavn_track(1, "Blinding Lights", 200)
    fake_jiosaavn_radio(monkeypatch, station_reply={"stationid": "st1"},
                        songs_reply={"0": {"song": song}, "1": {"song": jiosaavn_track(2, "Starboy", 230)},
                                     "2": {"no_song": True}, "extra": "ignored"})
    listings = await jiosaavn.radio("J7p4bzqLvCw", 25)
    assert [l.id for l in listings] == ["t1", "t2"]          # odd entries skipped, not fatal
    assert listings[0].title == "Blinding Lights" and listings[0].duration == 200


@pytest.mark.anyio
async def test_jiosaavn_radio_a_made_up_song_gives_no_station(monkeypatch):
    fake_jiosaavn_radio(monkeypatch, station_reply={})       # no stationid
    assert await jiosaavn.radio("nope", 25) == []


@pytest.mark.anyio
@pytest.mark.parametrize("status", [429, 503])
async def test_jiosaavn_radio_failures_become_our_errors(monkeypatch, status):
    expected = SourceBlocked if status == 429 else SourceUnavailable
    fake_jiosaavn_radio(monkeypatch, station_status=status)
    with pytest.raises(expected):
        await jiosaavn.radio("J7p4bzqLvCw", 25)


class FakeYTMusicRadio(FakeYTMusic):
    """FakeYTMusic that also answers get_watch_playlist; a None playlist_id_key means 'no such video'."""
    def __init__(self, watch_playlist=None, **kwargs):
        super().__init__(**kwargs)
        self.watch_playlist = watch_playlist

    def get_watch_playlist(self, videoId=None, playlistId=None, limit=25, radio=False, shuffle=False):
        self.calls.append(("get_watch_playlist", videoId, limit))
        if self.watch_playlist is None:
            raise KeyError(videoId)
        return self.watch_playlist


def watch_track(video_id, title, length, artists=("The Weeknd",), album="After Hours"):
    return {"videoId": video_id, "title": title, "length": length,
            "artists": [{"name": name} for name in artists],
            "album": {"name": album, "id": "MPREb_1"},
            "thumbnail": [{"url": "https://x/s.jpg"}, {"url": "https://x/b.jpg"}]}


@pytest.mark.anyio
async def test_ytmusic_radio_parses_the_watch_playlist(monkeypatch):
    fake = FakeYTMusicRadio(watch_playlist={"playlistId": "RDAMVMseed",
        "tracks": [watch_track("seed", "Blinding Lights", "3:22"),      # the seed itself: still returned
                   watch_track("syt", "Save Your Tears", "3:36"),
                   {"title": "no id"},                                   # odd row: skipped
                   watch_track("stay", "STAY", "2:22", artists=("The Kid LAROI",), album="F*ck Love 3")]})
    monkeypatch.setattr(ytmusic, "client", lambda: fake)
    listings = await ytmusic.radio("seed", 25)
    assert [l.id for l in listings] == ["seed", "syt", "stay"]           # seed kept here; the endpoint drops it
    assert listings[1].duration == 216 and listings[1].album == "After Hours"
    assert listings[1].image == "https://x/b.jpg"
    assert listings[1].explicit is None                                  # watch rows carry no badge
    assert fake.calls == [("get_watch_playlist", "seed", 25)]


@pytest.mark.anyio
async def test_ytmusic_radio_a_made_up_video_is_empty(monkeypatch):
    monkeypatch.setattr(ytmusic, "client", lambda: FakeYTMusicRadio())  # get_watch_playlist raises KeyError
    assert await ytmusic.radio("nope", 25) == []


@pytest.mark.anyio
async def test_ytmusic_radio_network_failure_is_unavailable(monkeypatch):
    class Broken:
        def get_watch_playlist(self, **kwargs):
            raise ConnectionError("boom")
    monkeypatch.setattr(ytmusic, "client", lambda: Broken())
    with pytest.raises(SourceUnavailable):
        await ytmusic.radio("seed", 25)


@pytest.mark.anyio
async def test_youtube_radio_parses_the_rd_mix(monkeypatch):
    asked = []

    def returning(reply):
        class FakeYoutubeDL:
            def __init__(self, options):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *exc):
                return False
            def extract_info(self, url, download):
                asked.append(url)
                return reply
        return FakeYoutubeDL

    info = {"channel": "The Weeknd", "entries": [
        {"id": "seed", "title": "Blinding Lights", "duration": 263, "view_count": 1000,
         "thumbnails": [{"url": "https://x/seed.jpg"}]},
        {"id": "v2", "title": "Starboy", "duration": 230, "view_count": 2000,
         "thumbnails": [{"url": "https://x/v2.jpg"}]},
        {"id": "live", "title": "Live", "duration": None},               # live: skipped
    ]}
    monkeypatch.setattr(youtube, "YoutubeDL", returning(info))
    listings = await youtube.radio("seed", 25)
    assert asked == ["https://www.youtube.com/watch?v=seed&list=RDseed"]
    assert [l.id for l in listings] == ["seed", "v2"]
    assert listings[1].title == "Starboy" and listings[1].duration == 230  # RAW title (MUS-13)
    assert listings[1].artists == ["The Weeknd"]


@pytest.mark.anyio
async def test_youtube_radio_a_video_that_does_not_exist_is_empty(monkeypatch):
    gone = ExtractorError("[youtube] seed: Video unavailable", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(gone))
    assert await youtube.radio("seed", 25) == []


@pytest.mark.anyio
async def test_youtube_radio_failures_become_our_errors(monkeypatch):
    bot = ExtractorError("[youtube] seed: Sign in to confirm you’re not a bot", expected=True)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(bot))
    with pytest.raises(SourceBlocked):
        await youtube.radio("seed", 25)
    monkeypatch.setattr(youtube, "YoutubeDL", fake_ytdlp_raising(TransportError("connection reset")))
    with pytest.raises(SourceUnavailable):
        await youtube.radio("seed", 25)
