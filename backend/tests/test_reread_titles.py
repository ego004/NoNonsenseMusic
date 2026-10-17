"""The stored-titles re-read (core/reread_titles.py) on music_test, with the lookups faked."""
from uuid import uuid4

import pytest

from music_backend.core.reread_titles import reread
from music_backend.models import Listing
from music_backend.services import library


def video(source: str, title: str, channel: str) -> Listing:
    return Listing(source=source, id=uuid4().hex[:11], title=title, artists=[channel], album=None, duration=165,
                   popularity=None)


@pytest.mark.anyio
async def test_a_stored_upload_shows_its_song_and_keeps_its_identity(pool):
    upload = video("youtube", "slipfunc - until dawn", "Ikigai")
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [upload])

    def read(video_id):
        return ("until dawn", ["slipfunc"]) if video_id == upload.id else None

    readers = {"youtube": read}
    assert len(await reread(pool, apply=False, readers=readers, pause=0)) >= 1
    async with pool.connection() as conn:
        shown = await (await conn.execute("SELECT title, artists FROM listings WHERE source_id = %s", [upload.id])).fetchone()
        assert (shown["title"], shown["artists"]) == ("slipfunc - until dawn", ["Ikigai"])     # a dry run writes nothing

    changes = await reread(pool, apply=True, readers=readers, pause=0)
    assert any(upload.id in c and "'until dawn' by ['slipfunc']" in c for c in changes)
    async with pool.connection() as conn:
        shown = await (await conn.execute("SELECT title, artists, words FROM listings WHERE source_id = %s", [upload.id])).fetchone()
        identity = await (await conn.execute("SELECT title FROM songs WHERE id = %s", [song_id])).fetchone()
    assert (shown["title"], shown["artists"]) == ("until dawn", ["slipfunc"])
    assert shown["words"] == ["dawn", "slipfunc", "until"]  # what a search finds it by (#26) follows
    assert identity["title"] == "slipfunc - until dawn"     # what new copies are compared with: as first stored


@pytest.mark.anyio
async def test_a_video_that_cannot_be_looked_up_is_left_as_it_is(pool):
    gone = video("youtube", "someone - a removed video", "A Channel")
    async with pool.connection() as conn:
        await library.resolve_song(conn, [gone])

    def unreachable(_video_id):
        raise ConnectionError("down")

    assert not [c for c in await reread(pool, apply=True, readers={"youtube": unreachable}, pause=0) if gone.id in c]
