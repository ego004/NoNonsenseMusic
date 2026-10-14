"""GET /search through the real endpoint: which sources are asked, and where plain YouTube ranks (MUS-13).

No network: every source module's `search` is replaced, so a test can hand each source its own reply
or its own failure.
"""
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import AlbumRef, ArtistRef, Listing
from music_backend.sources import jiosaavn, ytmusic, youtube
from conftest import TEST_URL, sign_up



@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    # default: every source answers with nothing, so no test can accidentally reach the network
    for module in (jiosaavn, ytmusic, youtube):
        monkeypatch.setattr(module, "search", empty_search)
        monkeypatch.setattr(module, "search_artists", empty_artists)
    for module in (jiosaavn, ytmusic):                      # plain YouTube has no albums to stub
        monkeypatch.setattr(module, "search_albums", empty_albums)
    monkeypatch.setattr(ytmusic, "top_result", no_top_result)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        yield client


async def empty_search(query: str) -> list[Listing]:
    return []


async def empty_albums(query: str) -> list:
    return []


async def empty_artists(query: str) -> list:
    return []


async def no_top_result(query: str) -> None:
    return None


def set_search(monkeypatch, module, listings=None, error=None):
    async def fake(query: str) -> list[Listing]:
        if error is not None:
            raise error
        return listings or []
    monkeypatch.setattr(module, "search", fake)


def set_albums(monkeypatch, module, albums=None, error=None):
    async def fake(query: str) -> list:
        if error is not None:
            raise error
        return albums or []
    monkeypatch.setattr(module, "search_albums", fake)


def set_artists(monkeypatch, module, artists=None, error=None):
    async def fake(query: str) -> list:
        if error is not None:
            raise error
        return artists or []
    monkeypatch.setattr(module, "search_artists", fake)


def listing(source, id, title, artists, duration):
    return Listing(source=source, id=id, title=title, artists=artists, album=None, duration=duration,
                   popularity=None)


def album_ref(source, id, title, artists, year=None):
    return AlbumRef(source=source, id=id, title=title, artists=artists, year=year)


def artist_ref(source, id, name):
    return ArtistRef(source=source, id=id, name=name)


def test_search_without_the_flag_never_asks_youtube(client, monkeypatch):
    asked = []

    async def spy(query: str):
        asked.append(query)
        return []

    monkeypatch.setattr(youtube, "search", spy)
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])
    set_search(monkeypatch, ytmusic, [listing("ytmusic", "y1", "Starboy", ["The Weeknd"], 231)])

    r = client.get("/search", params={"q": "the weeknd"})
    assert r.status_code == 200
    body = r.json()
    assert [s["source"] for s in body["sources"]] == ["jiosaavn", "ytmusic"]   # no youtube entry at all
    assert asked == []                                                        # and zero requests to it
    # both first in their source: YouTube Music's first, as JioSaavn's order counts half (#25)
    assert [s["title"] for s in body["songs"]] == ["Starboy", "Blinding Lights"]


def test_search_with_the_flag_ranks_youtube_below_the_music_songs(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])
    set_search(monkeypatch, ytmusic, [listing("ytmusic", "y1", "Starboy", ["The Weeknd"], 231)])
    set_search(monkeypatch, youtube, [
        listing("youtube", "v1", "The Weeknd - Blinding Lights (Official Video)", ["The Weeknd"], 263),
        listing("youtube", "v2", "The Weeknd - After Hours (Official Video)", ["The Weeknd"], 250),
    ])

    r = client.get("/search", params={"q": "the weeknd", "youtube": "true"})
    assert r.status_code == 200
    body = r.json()
    # all three sources took part, each with its own health line
    assert [s["source"] for s in body["sources"]] == ["jiosaavn", "ytmusic", "youtube"]
    assert all(s["healthy"] for s in body["sources"])
    assert body["sources"][2]["num_results"] == 2
    # the matching video is a fallback listing on the existing song, not a second row;
    # the new video sits after every music song (YouTube Music's first before JioSaavn's: its order counts half, #25)
    assert [s["title"] for s in body["songs"]] == ["Starboy", "Blinding Lights",
                                                   "The Weeknd - After Hours (Official Video)"]
    assert [l["source"] for l in body["songs"][1]["listings"]] == ["jiosaavn", "youtube"]
    assert body["songs"][-1]["score"] == 0


def test_a_broken_youtube_still_returns_the_music_results(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])
    set_search(monkeypatch, ytmusic, [listing("ytmusic", "y1", "Starboy", ["The Weeknd"], 231)])
    set_search(monkeypatch, youtube, error=RuntimeError("boom"))

    r = client.get("/search", params={"q": "the weeknd", "youtube": "true"})
    assert r.status_code == 200
    body = r.json()
    youtube_info = next(s for s in body["sources"] if s["source"] == "youtube")
    assert youtube_info["healthy"] is False
    assert youtube_info["error"] == "RuntimeError"
    assert [s["title"] for s in body["songs"]] == ["Starboy", "Blinding Lights"]


def test_youtube_alone_can_answer_when_the_music_sources_are_down(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, error=RuntimeError("down"))
    set_search(monkeypatch, ytmusic, error=RuntimeError("down"))
    set_search(monkeypatch, youtube, [listing("youtube", "v1", "Some Song", ["Some Channel"], 200)])

    r = client.get("/search", params={"q": "some song", "youtube": "true"})
    assert r.status_code == 200
    body = r.json()
    assert all(not s["healthy"] for s in body["sources"] if s["source"] in ("jiosaavn", "ytmusic"))
    assert [s["title"] for s in body["songs"]] == ["Some Song"]


def test_search_still_requires_an_account(client):
    client.headers.pop("Authorization")
    assert client.get("/search", params={"q": "x"}).status_code == 401


# ---------- MUS-20: albums and artists in the same search ----------

def test_default_search_returns_songs_albums_and_artists_together(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])
    set_albums(monkeypatch, jiosaavn, [album_ref("jiosaavn", "ja1", "After Hours", ["The Weeknd"], 2020)])
    set_albums(monkeypatch, ytmusic, [album_ref("ytmusic", "ya1", "After Hours", ["The Weeknd"], 2020)])
    set_artists(monkeypatch, jiosaavn, [artist_ref("jiosaavn", "jp1", "The Weeknd")])
    set_artists(monkeypatch, ytmusic, [artist_ref("ytmusic", "yp1", "The Weeknd")])

    body = client.get("/search", params={"q": "after hours"}).json()
    assert len(body["songs"]) == 1
    # the same album from both sources is ONE row with both copies, preferred source first
    assert len(body["albums"]) == 1
    assert body["albums"][0]["title"] == "After Hours"
    assert [l["source"] for l in body["albums"][0]["listings"]] == ["jiosaavn", "ytmusic"]
    assert body["albums"][0]["best"]["source"] == "jiosaavn"
    assert body["albums"][0]["year"] == 2020
    # same for artists
    assert len(body["artists"]) == 1
    assert [l["source"] for l in body["artists"][0]["listings"]] == ["jiosaavn", "ytmusic"]
    info = body["sources"][0]
    assert (info["num_results"], info["num_albums"], info["num_artists"]) == (1, 1, 1)


def test_filter_albums_searches_only_albums(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, listings=None, error=AssertionError("songs must not be searched"))
    set_artists(monkeypatch, jiosaavn, artists=None, error=AssertionError("artists must not be searched"))
    set_albums(monkeypatch, jiosaavn, [album_ref("jiosaavn", "ja1", "After Hours", ["The Weeknd"], 2020)])

    body = client.get("/search", params={"q": "after hours", "filter": "albums"}).json()
    assert [a["title"] for a in body["albums"]] == ["After Hours"]
    assert body["songs"] == [] and body["artists"] == []
    assert body["sources"][0]["num_results"] == 0                       # songs were never asked for
    assert body["sources"][0]["num_albums"] == 1


def test_filter_artists_searches_only_artists(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, listings=None, error=AssertionError("songs must not be searched"))
    set_albums(monkeypatch, jiosaavn, albums=None, error=AssertionError("albums must not be searched"))
    set_artists(monkeypatch, jiosaavn, [artist_ref("jiosaavn", "jp1", "Arijit Singh")])

    body = client.get("/search", params={"q": "arijit", "filter": "artists"}).json()
    assert [a["name"] for a in body["artists"]] == ["Arijit Singh"]
    assert body["songs"] == [] and body["albums"] == []


def test_filter_songs_leaves_albums_and_artists_empty(client, monkeypatch):
    set_albums(monkeypatch, jiosaavn, albums=None, error=AssertionError("albums must not be searched"))
    set_artists(monkeypatch, jiosaavn, artists=None, error=AssertionError("artists must not be searched"))
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])

    body = client.get("/search", params={"q": "blinding", "filter": "songs"}).json()
    assert len(body["songs"]) == 1
    assert body["albums"] == [] and body["artists"] == []


def test_an_unknown_filter_is_rejected(client):
    assert client.get("/search", params={"q": "x", "filter": "podcasts"}).status_code == 422


def test_youtube_channels_join_the_artists_but_never_the_albums(client, monkeypatch):
    set_artists(monkeypatch, jiosaavn, [artist_ref("jiosaavn", "jp1", "The Weeknd")])
    set_artists(monkeypatch, ytmusic, [artist_ref("ytmusic", "yp1", "The Weeknd")])
    set_artists(monkeypatch, youtube, [artist_ref("youtube", "UC1", "The Weeknd - Topic")])
    set_albums(monkeypatch, jiosaavn, [album_ref("jiosaavn", "ja1", "After Hours", ["The Weeknd"])])
    set_search(monkeypatch, youtube, [listing("youtube", "v1", "Some Video", ["Some Channel"], 200)])

    body = client.get("/search", params={"q": "the weeknd", "youtube": "true"}).json()
    # "The Weeknd - Topic" word-matches "The Weeknd": one artist row, three copies
    assert len(body["artists"]) == 1
    assert [l["source"] for l in body["artists"][0]["listings"]] == ["jiosaavn", "ytmusic", "youtube"]
    # youtube contributed no albums (no search_albums on that module)
    youtube_info = next(s for s in body["sources"] if s["source"] == "youtube")
    assert youtube_info["num_albums"] == 0
    assert youtube_info["num_artists"] == 1
    assert len(body["albums"]) == 1


def test_a_broken_album_search_keeps_the_source_healthy_and_the_others(client, monkeypatch):
    # the apps name an unhealthy source above the results; its songs all came, so it is not named (14 Oct: a timed-out
    # artist search showed "JioSaavn unavailable" above JioSaavn's songs)
    set_albums(monkeypatch, jiosaavn, error=RuntimeError("boom"))
    set_albums(monkeypatch, ytmusic, [album_ref("ytmusic", "ya1", "After Hours", ["The Weeknd"])])
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])

    body = client.get("/search", params={"q": "after hours"}).json()
    js = next(s for s in body["sources"] if s["source"] == "jiosaavn")
    assert js["healthy"] is True and js["error"] == "RuntimeError"         # still recorded
    assert js["num_results"] == 1                                          # its song search still answered
    assert len(body["albums"]) == 1 and body["albums"][0]["best"]["source"] == "ytmusic"
    assert len(body["songs"]) == 1                                         # one broken kind never loses the rest


def test_a_broken_song_search_marks_the_source_unhealthy(client, monkeypatch):
    set_search(monkeypatch, jiosaavn, error=RuntimeError("boom"))
    body = client.get("/search", params={"q": "after hours"}).json()
    js = next(s for s in body["sources"] if s["source"] == "jiosaavn")
    assert js["healthy"] is False and js["error"] == "RuntimeError"


def test_a_result_with_more_of_the_words_typed_ranks_first():
    from music_backend.services.matching import by_relevance, coverage, to_song
    def s(title, artists):
        return to_song([Listing(source="jiosaavn", id=title, title=title, artists=artists, album=None, duration=200, popularity=None)])
    popular, asked = s("Who Cares", ["Maninder Buttar"]), s("Peacock Affect - Who Cares If You Exist (Eisu remix)", ["Ikigai"])
    q = "who cares if you exist eisu remix"
    assert coverage(q, asked) == 1 and coverage(q, popular) < 0.3
    assert by_relevance([popular, asked], q) == [asked, popular]
    # a query every result contains keeps the sources' order
    first, second = s("Tum Hi Ho", ["Arijit Singh"]), s("Tum Hi Ho (From Aashiqui 2)", ["Arijit Singh"])
    assert by_relevance([first, second], "tum hi ho") == [first, second]


def test_youtube_musics_top_result_comes_first(client, monkeypatch):
    # "pasoori" (15 Oct): Ali Sethi and Shae Gill's song is on YouTube Music only as Coke Studio's video, its top result;
    # the songs-only searches answer with namesakes and covers
    video = Listing(source="ytmusic", id="5Eqb_-j3FDA", title="Pasoori", artists=["Shae Gill", "Ali Sethi"], album=None,
                    duration=277, popularity=1_000_000_000)
    async def top(query: str) -> Listing:
        return video
    monkeypatch.setattr(ytmusic, "top_result", top)
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Pasoori (Reprise)", ["JalRaj"], 181),
                                       listing("jiosaavn", "j2", "Pasoori", ["Zed70"], 153)])
    set_search(monkeypatch, ytmusic, [listing("ytmusic", "y1", "Pasoori", ["Marla Malvins"], 225)])
    body = client.get("/search", params={"q": "pasoori"}).json()
    assert body["songs"][0]["best"]["id"] == "5Eqb_-j3FDA"
    assert len(body["songs"]) == 4


def test_a_failing_top_result_leaves_the_search_as_it_was(client, monkeypatch):
    async def broken(query: str) -> Listing:
        raise RuntimeError("boom")
    monkeypatch.setattr(ytmusic, "top_result", broken)
    set_search(monkeypatch, jiosaavn, [listing("jiosaavn", "j1", "Blinding Lights", ["The Weeknd"], 200)])
    r = client.get("/search", params={"q": "blinding lights"})
    assert r.status_code == 200
    assert [s["title"] for s in r.json()["songs"]] == ["Blinding Lights"]


def test_a_search_for_albums_only_never_asks_for_the_top_result(client, monkeypatch):
    asked = []
    async def spy(query: str) -> None:
        asked.append(query)
    monkeypatch.setattr(ytmusic, "top_result", spy)
    assert client.get("/search", params={"q": "after hours", "filter": "albums"}).status_code == 200
    assert asked == []
