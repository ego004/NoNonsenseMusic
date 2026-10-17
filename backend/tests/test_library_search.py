"""#26: a search lists the songs of your own library that match first (liked, or in your playlists or ones shared with
you), marked in_library, each song once; the same typo rule as the ranking (matching.found).

The rule's parts on their own, then GET /search through the real endpoint on music_test, with the sources replaced.
"""
import random
from uuid import uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import Listing, Song
from music_backend.services import library
from music_backend.services.matching import Vocabulary, found, library_first, normalise, to_song
from music_backend.sources import jiosaavn, ytmusic, youtube
from conftest import TEST_URL, sign_up

pytestmark = pytest.mark.usefixtures("trust_client_listings")


def listing(source, id, title, artists, duration=200, popularity=None, image=None):
    return Listing(source=source, id=id, title=title, artists=artists, album=None, duration=duration,
                   popularity=popularity, image=image)


# ---------- the rule ----------

def test_alike_takes_the_words_found_takes():
    """For any typed word, the vocabulary gives exactly the known words found() would take for it: the database is then
    asked for those, so the library is searched with found()'s rule without comparing each song (#26)."""
    rng = random.Random(26)
    known = ["kesariya", "tadipaar", "lights", "light", "shape", "black", "block", "money", "honey", "hi", "ho",
             "arijit", "singh", "blinding", "weeknd", "besame", "mucho", "abcdefghijklmnopqrst", "abcdefghijklmnopqxyz"]

    def mutate(word):
        i = rng.randrange(len(word) + 1)
        return rng.choice([word[:i] + rng.choice("aeiouxyz") + word[i:], word[:i] + word[i + 1:],
                           word[:i] + rng.choice("aeiouxyz") + word[i + 1:]])

    known += [mutate(rng.choice(known)) for _ in range(300)]
    vocabulary = Vocabulary()
    vocabulary.add(known)
    for typed in ["kesriya", "tadipar", "light", "shap", "black", "money", "hi", "abcdefghijklmnopqrst",
                  *(mutate(rng.choice(known)) for _ in range(300))]:
        alike = vocabulary.alike(typed)
        assert alike[0] == typed and len(alike) == len(set(alike))
        assert set(alike) - {typed} == {word for word in set(known) if word != typed and found(typed, {word})}, typed


def test_one_song_once_its_copies_joined_and_the_users_first():
    mine = [Song(title="Kesariya", artists=["Pritam", "Arijit Singh"], duration=268, score=0, image="https://img/stored.jpg",
                 best=listing("ytmusic", "y-kes", "Kesariya", ["Pritam", "Arijit Singh"], 268),
                 listings=[listing("ytmusic", "y-kes", "Kesariya", ["Pritam", "Arijit Singh"], 268)]),
            Song(title="Wake Up in the Sky", artists=["Gucci Mane", "Kodak Black"], duration=200, score=0,
                 best=listing("ytmusic", "y-wake", "Wake Up in the Sky", ["Gucci Mane", "Kodak Black"]),
                 listings=[listing("ytmusic", "y-wake", "Wake Up in the Sky", ["Gucci Mane", "Kodak Black"])])]
    # the sources found the same Kesariya (one copy in common) with a JioSaavn copy too, and another song
    theirs = [to_song([listing("jiosaavn", "j-kes", "Kesariya", ["Arijit Singh"], 268, 900, "https://img/j.jpg"),
                       listing("ytmusic", "y-kes", "Kesariya", ["Pritam", "Arijit Singh"], 268)], 0.03),
              to_song([listing("jiosaavn", "j-other", "Kesariya Rang", ["Someone"])], 0.02)]
    songs = library_first(theirs, mine, "kesariya")
    assert [s.title for s in songs] == ["Kesariya", "Wake Up in the Sky", "Kesariya Rang"]
    assert [s.in_library for s in songs] == [True, True, False]
    kesariya = songs[0]
    assert {(l.source, l.id) for l in kesariya.listings} == {("ytmusic", "y-kes"), ("jiosaavn", "j-kes")}
    assert kesariya.best.id == "j-kes"                       # JioSaavn's copy plays, as pick_best picks for any song
    assert kesariya.image == "https://img/stored.jpg"         # the cover your library shows
    assert kesariya.score == 0.03
    # among your songs, one the query names by title or first artist before one that only features it (by_relevance)
    assert [s.title for s in library_first([], mine[::-1], "kodak black")][0] == "Wake Up in the Sky"


def test_old_apps_see_no_new_field_on_other_songs():
    song = to_song([listing("jiosaavn", "j1", "Song", ["Artist"])])
    assert "in_library" not in song.model_dump(mode="json")
    song.in_library = True
    assert song.model_dump(mode="json")["in_library"] is True


# ---------- GET /search ----------

class Person:
    """One signed-in account: its calls send its own token."""

    def __init__(self, client):
        self.client = client
        session = sign_up(client)
        del client.headers["Authorization"]
        self.token, self.username = session["token"], session["user"]["username"]

    def __call__(self, method, path, **kw):
        return self.client.request(method, path, headers={"Authorization": f"Bearer {self.token}"}, **kw)

    def search(self, q, **params):
        r = self("GET", "/search", params={"q": q, **params})
        assert r.status_code == 200, r.text
        return r.json()["songs"]

    def like(self, *copies):
        assert self("POST", "/liked", json={"listings": [c.model_dump() for c in copies]}).status_code == 200

    def playlist(self, name, *copies):
        playlist = self("POST", "/playlists", json={"name": name}).json()["id"]
        for c in copies:
            assert self("POST", f"/playlists/{playlist}/items", json={"listings": [c.model_dump()]}).status_code == 201
        return playlist


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    for module in (jiosaavn, ytmusic, youtube):
        monkeypatch.setattr(module, "search", nothing)
        monkeypatch.setattr(module, "search_artists", nothing)
    for module in (jiosaavn, ytmusic):
        monkeypatch.setattr(module, "search_albums", nothing)
    monkeypatch.setattr(ytmusic, "top_result", no_top_result)
    from music_backend.main import app
    with TestClient(app) as client:
        yield client


async def nothing(query):
    return []


async def no_top_result(query):
    return None


def sources_find(monkeypatch, *copies):
    async def found(query):
        return list(copies)
    monkeypatch.setattr(jiosaavn, "search", found)


def tag():
    """A word no other test's songs have: each test's songs are its own, in a database every test shares."""
    return "t" + uuid4().hex[:8]


def test_a_liked_song_comes_first_even_when_no_source_finds_it(client, monkeypatch):
    me, t = Person(client), tag()
    me.like(listing("jiosaavn", f"j-{t}", "Kesariya", [f"Arijit {t}"]))
    sources_find(monkeypatch, listing("jiosaavn", f"j2-{t}", "Kesariya Lofi", [f"Arijit {t}"]))
    songs = me.search(f"kesariya {t}")
    assert [(s["title"], s.get("in_library", False)) for s in songs] == [("Kesariya", True), ("Kesariya Lofi", False)]


def test_typos_as_the_ranking_allows_and_every_word_needed(client):
    me, t = Person(client), tag()
    me.like(listing("jiosaavn", f"j-{t}", "Tadipaar", [f"Stan {t}"]))
    assert [s["title"] for s in me.search(f"tadipar {t}")] == ["Tadipaar"]       # 93 alike: found
    assert me.search(f"tadipaar remix {t}") == []                               # "remix" is not in it
    me.like(listing("jiosaavn", f"h-{t}", "Hi", [f"Band {t}"]))
    assert me.search(f"ho {t}") == []                                           # short words only as typed


def test_your_playlists_and_ones_shared_with_you_count_and_no_one_elses(client):
    me, friend, stranger, t = Person(client), Person(client), Person(client), tag()
    me.playlist(f"Mine {t}", listing("jiosaavn", f"a-{t}", "Song A", [f"Singer {t}"]))
    shared = friend.playlist(f"Ours {t}", listing("jiosaavn", f"b-{t}", "Song B", [f"Singer {t}"]))
    assert friend("PUT", f"/playlists/{shared}/members", json={"username": me.username, "role": "viewer"}).status_code == 204
    stranger.like(listing("jiosaavn", f"c-{t}", "Song C", [f"Singer {t}"]))
    assert sorted(s["title"] for s in me.search(f"singer {t}")) == ["Song A", "Song B"]
    assert [s["title"] for s in stranger.search(f"singer {t}")] == ["Song C"]


def test_a_song_the_sources_also_find_is_listed_once_with_their_copies(client, monkeypatch):
    me, t = Person(client), tag()
    me.like(listing("ytmusic", f"y-{t}", "Blinding Lights", [f"Weeknd {t}"]))
    sources_find(monkeypatch, listing("jiosaavn", f"other-{t}", "Save Your Tears", [f"Weeknd {t}"]),
                 listing("jiosaavn", f"j-{t}", "Blinding Lights", [f"Weeknd {t}"]))
    # YouTube Music's copy is the one you liked; JioSaavn's is the same song (resolve_song links it when it is stored)
    with psycopg.connect(TEST_URL) as conn:
        song_id = conn.execute("SELECT song_id FROM listings WHERE source_id = %s", [f"y-{t}"]).fetchone()[0]
        conn.execute("INSERT INTO listings (source, source_id, song_id, title, artists, duration, words)"
                     " VALUES ('jiosaavn', %s, %s, 'Blinding Lights', %s, 200, %s)",
                     [f"j-{t}", song_id, [f"Weeknd {t}"], library.stored_words("Blinding Lights", [f"Weeknd {t}"])])
    songs = me.search(f"weeknd {t}")
    assert [(s["title"], s.get("in_library", False)) for s in songs] == [("Blinding Lights", True), ("Save Your Tears", False)]
    assert {l["source"] for l in songs[0]["listings"]} == {"jiosaavn", "ytmusic"}


def test_the_sources_order_then_the_newest_and_a_bound(client, monkeypatch):
    me, t = Person(client), tag()
    copies = [listing("jiosaavn", f"{i}-{t}", f"Song {i}", [f"Singer {t}"]) for i in range(library.LIBRARY_SONGS + 5)]
    for c in copies:
        me.like(c)
    sources_find(monkeypatch, copies[3])
    songs = me.search(f"singer {t}")
    assert len(songs) == library.LIBRARY_SONGS and all(s["in_library"] for s in songs)
    # the one the sources found, then the most recently liked
    assert [s["title"] for s in songs[:3]] == ["Song 3", f"Song {len(copies) - 1}", f"Song {len(copies) - 2}"]


def test_albums_or_artists_alone_have_no_songs(client):
    me, t = Person(client), tag()
    me.like(listing("jiosaavn", f"j-{t}", "Song", [f"Singer {t}"]))
    assert me.search(f"singer {t}", filter="artists") == []
    assert [s["title"] for s in me.search(f"singer {t}", filter="songs")] == ["Song"]
    assert me.search("!!!") == []                                               # no words: nothing of yours


@pytest.mark.anyio
async def test_copies_stored_before_get_their_words_at_start(pool):
    t = tag()
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", f"j-{t}", "Old Song", [f"Zayn{t}"])])
        await conn.execute("UPDATE listings SET words = NULL WHERE song_id = %s", [song_id])
        assert await library.load_words(conn) >= 1
        words = (await (await conn.execute("SELECT words FROM listings WHERE song_id = %s", [song_id])).fetchone())["words"]
    assert words == sorted(normalise(f"Old Song Zayn{t}").split())
    assert f"zayn{t}" in library.vocabulary.alike(f"zayn{t}x")                  # a typo of it is found too
