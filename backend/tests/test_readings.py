"""A re-uploaded video's song, confirmed by a catalogue (services/readings.py): titles and catalogue songs as they were
on 14 Oct, ids made up."""
import asyncio
import time

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import Listing
from music_backend.services import library, readings
from conftest import TEST_URL, sign_up


def song(title, artists, source="ytmusic"):
    return Listing(source=source, id=f"c-{title}", title=title, artists=artists, album=None, duration=200, popularity=None)


def catalogue(*songs, delay=0.0, fails=False):
    """A catalogue module: search answers [songs] for any query, after [delay] seconds, or raises."""
    asked = []

    class Catalogue:
        @staticmethod
        async def search(query):
            asked.append(query)
            await asyncio.sleep(delay)
            if fails:
                raise TimeoutError("stalled")
            return list(songs)
    Catalogue.asked = asked
    return Catalogue


@pytest.mark.parametrize("title,expected", [
    ("slipfunc - until dawn", ("slipfunc", "until dawn")),
    ("Iam6teen - Im sorry{}4K{}Sad Lofi{}", ("Iam6teen", "Im sorry{}4K{}Sad Lofi{}")),
    ("MC STΔN - NUMBERKARI | TADIPAAR | 2K20", ("MC STΔN", "NUMBERKARI")),
    ("The Weeknd - Blinding Lights (Lyrics)", ("The Weeknd", "Blinding Lights")),
    ("Eisu - Peacock Affect - Who Cares If You Exist", None),       # three parts: which two?
    ("until dawn", None),
])
def test_sides_of_a_title(title, expected):
    assert readings.sides(title) == expected


@pytest.mark.anyio
@pytest.mark.parametrize("title,found,expected", [
    ("slipfunc - until dawn", [song("until dawn", ["slipfunc"])], ("until dawn", ["slipfunc"])),
    # Song - Artist: the order reading by position gets wrong
    ("Udaarian - Satinder Sartaaj", [song("Udaarian", ["Satinder Sartaaj"])], ("Udaarian", ["Satinder Sartaaj"])),
    # the catalogue adds a bracket: its name
    ("chief. - until you're home", [song("until you're home (feat. X)", ["chief."])], ("until you're home (feat. X)", ["chief."])),
    # the catalogue's title is shorter: another recording, the remix is not the original (14 Oct)
    ("Peacock Affect - Who Cares If You Exist (Eisu remix)", [song("Who Cares If You Exist", ["Peacock Affect"])], None),
    ("Iam6teen - Im sorry{}4K{}Sad Lofi{}", [song("Im sorry", ["Iam6teen"])], None),
    # a song of the same name by someone else is no confirmation ("Leaves" by PROVIDENCE144 for "Taiko - Leaves")
    ("Taiko - Leaves", [song("Leaves", ["PROVIDENCE144"])], None),
    # a word that only starts the same is not the title
    ("frrb - lose", [song("loser", ["frrb"])], None),
    # both readings are catalogue songs: nothing says which
    ("A - B", [song("B", ["A"]), song("A", ["B"])], None),
])
async def test_a_title_is_confirmed_only_by_a_catalogue_song(monkeypatch, title, found, expected):
    monkeypatch.setattr(readings, "CATALOGUES", (catalogue(*found),))
    assert await readings.confirmed(title) == expected


@pytest.mark.anyio
async def test_one_catalogue_failing_leaves_the_other(monkeypatch):
    monkeypatch.setattr(readings, "CATALOGUES", (catalogue(fails=True), catalogue(song("until dawn", ["slipfunc"]))))
    assert await readings.confirmed("slipfunc - until dawn") == ("until dawn", ["slipfunc"])


def upload(title="slipfunc - until dawn", id="vidUntilDawn"):
    return Listing(source="youtube", id=id, title=title, artists=["Ikigai"], album=None, duration=165, popularity=None)


@pytest.mark.usefixtures("trust_client_listings")
def test_liking_an_upload_answers_at_once_and_its_title_is_confirmed_after(monkeypatch):
    slow = catalogue(song("until dawn", ["slipfunc"]), delay=1.5)
    monkeypatch.setattr(readings, "CATALOGUES", (slow,))
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        started = time.perf_counter()
        r = client.post("/liked", json={"listings": [upload().model_dump()]})
        took = time.perf_counter() - started
        assert r.status_code == 200 and took < 0.5, f"the like waited {took:.2f} s for the catalogue"

        def stored():
            liked = client.get("/liked").json()
            return [(l["title"], l["artists"]) for s in liked for l in s["listings"] if l["id"] == "vidUntilDawn"]
        assert stored() == [("slipfunc - until dawn", ["Ikigai"])]
        deadline = time.monotonic() + 5
        while stored() != [("until dawn", ["slipfunc"])] and time.monotonic() < deadline:
            time.sleep(0.1)
        assert stored() == [("until dawn", ["slipfunc"])]
        assert slow.asked == ["slipfunc until dawn"]
        # a search finds it by what it now shows, a typo of it too (#26)
        with psycopg.connect(TEST_URL) as conn:
            assert conn.execute("SELECT words FROM listings WHERE source_id = 'vidUntilDawn'").fetchone()[0] == ["dawn", "slipfunc", "until"]
        assert "slipfunc" in library.vocabulary.alike("slipfnc")


@pytest.mark.usefixtures("trust_client_listings")
def test_a_copy_is_searched_once_however_often_it_is_played(monkeypatch):
    nothing = catalogue()
    monkeypatch.setattr(readings, "CATALOGUES", (nothing,))
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        body = {"listings": [upload("Taiko - Leaves", "vidLeaves01").model_dump()]}
        for _ in range(5):
            client.post("/events", json=body | {"type": "play", "position": 0})
        time.sleep(0.3)
    assert nothing.asked == ["Taiko Leaves"]
