"""Exercise POST /radio through the real endpoint: what is asked, what is dropped, what fails.

No network access: each source module's `radio` function is replaced, so a test can give a source
its own reply or its own failure.
"""
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import Listing
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable, jiosaavn, ytmusic
from conftest import TEST_URL, sign_up

pytestmark = pytest.mark.usefixtures("trust_client_listings")



@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    # default: every station is empty and no song is found anywhere, so no test can accidentally reach the network
    for module in (jiosaavn, ytmusic):
        monkeypatch.setattr(module, "radio", empty_radio)
    monkeypatch.setattr(ytmusic, "search", no_results)
    monkeypatch.setattr(jiosaavn, "get_song", unknown_song)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        yield client


async def empty_radio(source_id: str, limit: int = 25) -> list[Listing]:
    return []


async def no_results(query: str) -> list[Listing]:
    return []


async def unknown_song(song_id: str) -> Listing:
    raise SongNotFound(song_id)


def set_radio(monkeypatch, module, listings=None, error=None):
    async def fake(source_id: str, limit: int = 25) -> list[Listing]:
        if error is not None:
            raise error
        return listings or []
    monkeypatch.setattr(module, "radio", fake)


def listing(id, title=None, duration=None):
    """Distinct per id: ranking/group_listings would otherwise merge same-title songs into one."""
    return Listing(source="jiosaavn", id=id, title=title or f"Song {id}", artists=["The Weeknd"],
                   album="After Hours", duration=duration if duration is not None else 200 + len(id),
                   popularity=None)


def radio(seed_source="jiosaavn", seed_id="seed", exclude=None, limit=25):
    body = {"seed": {"source": seed_source, "source_id": seed_id}, "limit": limit}
    if exclude is not None:
        body["exclude"] = exclude
    return body


def test_radio_keeps_the_station_order_and_drops_the_seed(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed", "Blinding Lights"), listing("s2", "Starboy"),
                                      listing("s3", "Save Your Tears")])
    r = client.post("/radio", json=radio())
    assert r.status_code == 200
    songs = r.json()["songs"]
    assert [s["best"]["id"] for s in songs] == ["s2", "s3"]        # the seed never comes back
    assert [s["title"] for s in songs] == ["Starboy", "Save Your Tears"]   # station order kept
    assert all(s["score"] > 0 for s in songs)                      # RRF ranked, not raw listings


def test_radio_drops_the_app_exclude_list(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed"), listing("s2"), listing("s3"), listing("s4")])
    r = client.post("/radio", json=radio(exclude=[
        {"source": "jiosaavn", "source_id": "s2"},
        {"source": "ytmusic", "source_id": "whatever"},            # other-source ids are fine to send
    ]))
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["s3", "s4"]


def test_radio_also_drops_your_last_plays_from_the_database(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed"), listing("played"), listing("fresh")])
    # one play event for "played": it is stored, then the radio must not repeat it
    stored = client.post("/events", json={"type": "play", "position": 0,
                                          "listings": [listing("played").model_dump()]})
    assert stored.status_code == 200
    r = client.post("/radio", json=radio())
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["fresh"]
    # Settings › Playback › Autoplay, "Skip songs played lately" off: it may come back
    r = client.post("/radio", json=radio() | {"skip_recent": False})
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["played", "fresh"]


def store(client, *listings):
    """Store a song with these copies, as a like does (the station uses a stored song's copies)."""
    client.post("/liked", json={"listings": [l.model_dump() for l in listings]})


def ytmusic_copy(id, title="Song jio-own", artists=("The Weeknd",)):
    return Listing(source="ytmusic", id=id, title=title, artists=list(artists), album=None, duration=207, popularity=None)


def asking(monkeypatch, module, reply):
    """Record the seeds the station is asked for."""
    asked = []

    async def station(source_id, limit=25):
        asked.append(source_id)
        return reply
    monkeypatch.setattr(module, "radio", station)
    return asked


def searching(monkeypatch, results):
    searched = []

    async def search(query):
        searched.append(query)
        return results
    monkeypatch.setattr(ytmusic, "search", search)
    return searched


def test_radio_asks_youtube_musics_station_from_the_songs_own_video(client, monkeypatch):
    asked = asking(monkeypatch, ytmusic, [listing("from-ytm")])
    store(client, listing("jio-own"), ytmusic_copy("ytmOwn00001"))
    r = client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="jio-own"))
    assert asked == ["ytmOwn00001"] and [s["best"]["id"] for s in r.json()["songs"]] == ["from-ytm"]


def test_radio_a_video_seed_starts_the_station_itself(client, monkeypatch):
    for source in ("ytmusic", "youtube"):                           # one id space: a plain video starts it too
        asked = asking(monkeypatch, ytmusic, [listing("from-ytm")])
        client.post("/radio", json=radio(seed_source=source, seed_id="J7p4bzqLvCw"))
        assert asked == ["J7p4bzqLvCw"]


def test_radio_finds_the_video_of_a_stored_song_only_jiosaavn_has(client, monkeypatch):
    searched = searching(monkeypatch, [ytmusic_copy("namesake001", "Song jio-only")])
    asked = asking(monkeypatch, ytmusic, [listing("from-ytm")])
    store(client, listing("jio-only"))
    client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="jio-only"))
    assert searched == ["Song jio-only The Weeknd"] and asked == ["namesake001"]


def test_radio_finds_the_video_of_a_song_not_stored_yet(client, monkeypatch):
    # the app asks when the song starts; its first "play" is stored once the audio is ready, after this request
    async def nanchaku(song_id):
        return Listing(source="jiosaavn", id=song_id, title="Nanchaku", artists=["Seedhe Maut", "MC STAN"], album=None,
                       duration=193, popularity=None)
    monkeypatch.setattr(jiosaavn, "get_song", nanchaku)
    searched = searching(monkeypatch, [ytmusic_copy("nanchaku001", "Nanchaku", ["Seedhe Maut"])])
    asked = asking(monkeypatch, ytmusic, [listing("from-ytm")])
    client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="sh7ohPun"))
    assert searched == ["Nanchaku Seedhe Maut"] and asked == ["nanchaku001"]


def test_radio_never_starts_from_another_songs_video(client, monkeypatch):
    # YouTube Music's first result for a title is not always the song ("Pasoori" gave "Jhol" first, 14 Oct)
    searching(monkeypatch, [ytmusic_copy("other000001", "Jhol", ["Maanu"])])
    ytm = asking(monkeypatch, ytmusic, [listing("from-ytm")])
    jio = asking(monkeypatch, jiosaavn, [listing("from-jio")])
    store(client, listing("jio-only"))
    r = client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="jio-only"))
    assert ytm == [] and jio == ["jio-only"] and [s["best"]["id"] for s in r.json()["songs"]] == ["from-jio"]


def test_radio_keeps_youtube_musics_order_with_no_cap_per_artist(client, monkeypatch):
    # its station spreads artists itself; a cap of 3 cut the seed artist's songs it placed on purpose
    station = [ytmusic_copy("seed", "Seed")] + [Listing(source="ytmusic", id=f"v{i}", title=f"Song {i}", artists=["MC STAN" if i % 4 == 0 else f"A{i}"],
                                           album=None, duration=200, popularity=None) for i in range(12)]
    set_radio(monkeypatch, ytmusic, station)
    r = client.post("/radio", json=radio(seed_source="ytmusic", seed_id="seed", limit=12))
    assert [s["best"]["id"] for s in r.json()["songs"]] == [f"v{i}" for i in range(12)]


def test_radio_drops_a_song_played_as_its_plain_youtube_copy(client, monkeypatch):
    set_radio(monkeypatch, ytmusic, [ytmusic_copy("seed", "Seed"), ytmusic_copy("vidPlayed01", "Played"), ytmusic_copy("vidFresh001", "Fresh")])
    r = client.post("/radio", json=radio(seed_source="ytmusic", seed_id="seed",
                                         exclude=[{"source": "youtube", "source_id": "vidPlayed01"}]))
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["vidFresh001"]


def test_radio_reads_the_station_past_what_it_drops(client, monkeypatch):
    # the next refill asks for the same song's station: its next songs lie past the 30 already queued (17 Oct)
    from music_backend.main import STATION_DEPTH
    station = [ytmusic_copy("seed", "Seed")] + [Listing(source="ytmusic", id=f"v{i:02}", title=f"Song {i}", artists=[f"A{i}"],
                                                        album=None, duration=200, popularity=None) for i in range(60)]
    asked = []

    async def deep(source_id, limit=25):
        asked.append(limit)
        return station[:limit]
    monkeypatch.setattr(ytmusic, "radio", deep)
    queued = [{"source": "ytmusic", "source_id": f"v{i:02}"} for i in range(30)]
    r = client.post("/radio", json=radio(seed_source="ytmusic", seed_id="seed", exclude=queued, limit=20))
    assert [s["best"]["id"] for s in r.json()["songs"]] == [f"v{i:02}" for i in range(30, 50)]
    many = [{"source": "jiosaavn", "source_id": str(i)} for i in range(100)]
    client.post("/radio", json=radio(seed_source="ytmusic", seed_id="seed", exclude=many, limit=50))
    assert asked == [20 + 1 + 31, STATION_DEPTH]                     # the queued songs and the seed; then at most 150


def test_radio_respects_the_limit(client, monkeypatch):
    # limit=3 counts the songs kept after the seed is dropped: 1 seed + 3 candidates -> 3 back
    set_radio(monkeypatch, jiosaavn, [listing("seed")] + [listing(f"s{i}") for i in range(4)])
    r = client.post("/radio", json=radio(limit=3))
    assert len(r.json()["songs"]) == 3


def test_radio_an_empty_station_is_a_normal_answer(client, monkeypatch):
    r = client.post("/radio", json=radio())                         # default stub returns []
    assert r.status_code == 200 and r.json()["songs"] == []


@pytest.mark.parametrize("error", [SourceUnavailable("down"), SourceBlocked("bot check")])
def test_radio_source_down_is_502(client, monkeypatch, error):
    set_radio(monkeypatch, jiosaavn, error=error)
    r = client.post("/radio", json=radio())
    assert r.status_code == 502
    assert r.json()["detail"] == "jiosaavn is unavailable right now"


def test_radio_needs_a_session(client):
    client.headers.pop("Authorization")
    assert client.post("/radio", json=radio()).status_code == 401


def test_radio_rejects_a_bad_body(client):
    assert client.post("/radio", json={"seed": {"source": "jiosaavn"}}).status_code == 422      # no source_id
    assert client.post("/radio", json=radio(seed_source="deezer")).status_code == 422           # not a source
    assert client.post("/radio", json=radio(limit=0)).status_code == 422                        # below 1
    assert client.post("/radio", json=radio(limit=51)).status_code == 422                       # above 50
    too_many = [{"source": "jiosaavn", "source_id": str(i)} for i in range(101)]
    assert client.post("/radio", json=radio(exclude=too_many)).status_code == 422               # above 100


def test_radio_rate_limit(client, monkeypatch):
    for _ in range(30):
        assert client.post("/radio", json=radio()).status_code == 200
    r = client.post("/radio", json=radio())
    assert r.status_code == 429
    assert "Retry-After" in r.headers
