import pytest

import json
from pathlib import Path

from music_backend.matching import artists_match, group_listings, interleave, normalise, pick_best, rank_songs, same_recording, to_song
from music_backend.sources import jiosaavn, ytmusic
from music_backend.models import Listing


def make(title, artists, duration, source="jiosaavn", popularity=None):
    # a Listing with only the fields matching cares about; the rest filled with harmless values
    return Listing(source=source, id=f"{title}-{duration}", title=title, artists=artists, album=None, duration=duration, popularity=popularity)


def test_smoke():
    assert 1 == 1


# ---------- B1: normalise ----------

def test_normalise_removes_accents():
    assert normalise("ROSALÍA") == "rosalia"


def test_normalise_turns_punctuation_into_spaces():
    assert normalise('Tum Hi Ho (From "Aashiqui 2")') == "tum hi ho from aashiqui 2"


def test_normalise_collapses_spaces():
    assert normalise("  Blinding   Lights ") == "blinding lights"


def test_normalise_keeps_bracket_words():
    # the words inside brackets must survive: they are what tells a remix from the original
    assert normalise("Blinding Lights (Major Lazer Remix)") == "blinding lights major lazer remix"


# ---------- B2: artists_match ----------

def test_artists_match_subset_list():
    assert artists_match(["Mithoon", "Arijit Singh"], ["Arijit Singh"])


def test_artists_match_shorter_name_inside_longer():
    assert artists_match(["Pritam"], ["Pritam Chakraborty"])


def test_artists_match_longer_name_on_the_left():
    assert artists_match(["Pritam Chakraborty"], ["Pritam"])


def test_artists_match_typo():
    assert artists_match(["The Weeknd"], ["the weekend"])


def test_artists_match_accented_and_plain():
    assert artists_match(["ROSALÍA"], ["Rosalia"])


def test_artists_different_people():
    assert not artists_match(["The Weeknd"], ["Loi"])


def test_artists_empty_list():
    assert not artists_match([], ["Loi"])


def test_artists_blank_name_matches_nobody():
    # "" normalises to no words, and an empty set is a subset of every set
    assert not artists_match([""], ["Loi"])


# ---------- B3: same_recording ----------

def test_same_recording_across_sources():
    assert same_recording(make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 202, "ytmusic"))


def test_remix_is_not_the_original():
    assert not same_recording(make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights (Major Lazer Remix)", ["The Weeknd"], 198))


def test_cover_is_not_the_original():
    assert not same_recording(make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["Loi"], 148))


def test_artist_subset_still_same_recording():
    assert same_recording(make("Tum Hi Ho", ["Mithoon", "Arijit Singh"], 262), make("Tum Hi Ho", ["Arijit Singh"], 262, "ytmusic"))


def test_four_seconds_apart_is_same_recording():
    # seen live: JioSaavn has Blinding Lights at both 200 s and 204 s
    assert same_recording(make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 204))


def test_too_far_apart_in_duration():
    # the two Rosalia remix edits: same title and artists, 11 s apart
    assert not same_recording(make("Blinding Lights (Remix)", ["The Weeknd", "Rosalia"], 206), make("Blinding Lights (Remix)", ["The Weeknd", "Rosalia"], 217))


@pytest.mark.xfail(reason="known hole: a remix whose title has no marker looks identical; needs audio fingerprinting")
def test_unmarked_remix_known_limitation():
    assert not same_recording(make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd", "Major Lazer"], 198))


# ---------- B4: interleave ----------

def test_interleave_equal_lengths():
    assert interleave([["j1", "j2"], ["y1", "y2"]]) == ["j1", "y1", "j2", "y2"]


def test_interleave_first_longer():
    assert interleave([["j1", "j2", "j3"], ["y1"]]) == ["j1", "y1", "j2", "j3"]


def test_interleave_second_longer():
    assert interleave([["j1"], ["y1", "y2", "y3"]]) == ["j1", "y1", "y2", "y3"]


def test_interleave_one_empty():
    assert interleave([[], ["y1", "y2"]]) == ["y1", "y2"]


def test_interleave_both_empty():
    assert interleave([[], []]) == []


def test_interleave_three_sources():
    assert interleave([["j1", "j2"], ["y1"], ["t1", "t2"]]) == ["j1", "y1", "t1", "j2", "t2"]


def test_interleave_no_sources():
    assert interleave([]) == []


# ---------- B5: group_listings ----------

def test_group_listings_trace():
    w200, w202 = make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 202, "ytmusic")
    loi, w206 = make("Blinding Lights", ["Loi"], 148, "ytmusic"), make("Blinding Lights", ["The Weeknd"], 206)
    # w206 is 6 s from the group's first listing (w200), so it starts its own group
    assert group_listings([w200, w202, loi, w206]) == [[w200, w202], [loi], [w206]]


def test_group_listings_empty():
    assert group_listings([]) == []


def test_group_listings_on_real_samples():
    samples = Path(__file__).parent.parent / "samples"
    js = [jiosaavn.to_listing(r) for r in json.loads((samples / "jiosaavn_search.json").read_text())["results"]]
    yt = [ytmusic.to_listing(r) for r in ytmusic.song_rows(json.loads((samples / "ytmusic_search.json").read_text()))]
    groups = group_listings(interleave([js, yt]))
    weeknd_group = next(g for g in groups if any(l.id == "fW-Mxsnu" for l in g))
    assert any(l.id == "J7p4bzqLvCw" for l in weeknd_group), "The Weeknd's JioSaavn 200 s and YouTube Music 202 s listings should share a group"


# ---------- B6: pick_best ----------

def test_pick_best_prefers_jiosaavn():
    js, yt = make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 202, "ytmusic", popularity=3_600_000_000)
    assert pick_best([yt, js]) is js


def test_pick_best_higher_popularity_within_source():
    low, high = make("Blinding Lights", ["The Weeknd"], 200, popularity=10), make("Blinding Lights", ["The Weeknd"], 201, popularity=20)
    assert pick_best([low, high]) is high


def test_pick_best_missing_popularity_counts_as_zero():
    unknown, known = make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 201, popularity=5)
    assert pick_best([unknown, known]) is known


def test_pick_best_closest_to_median_breaks_ties():
    a, b, c = (make("Blinding Lights", ["The Weeknd"], d, popularity=7) for d in (200, 204, 201))
    assert pick_best([a, b, c]) is c


def test_pick_best_returns_one_listing():
    group = [make("Blinding Lights", ["The Weeknd"], 200)]
    assert pick_best(group) is group[0]


# ---------- C2: to_song ----------

def test_to_song_takes_details_from_best_and_keeps_all_listings():
    js, yt = make("Blinding Lights", ["The Weeknd"], 200), make("Blinding Lights", ["The Weeknd"], 202, "ytmusic")
    song = to_song([yt, js])
    assert song.best is js and song.duration == 200 and song.listings == [yt, js]


# ---------- RRF ranking ----------

def test_song_found_by_both_sources_outranks_one_offs():
    js = [make("Blinding Lights", ["The Weeknd"], 200), make("Starboy", ["The Weeknd"], 230)]
    yt = [make("Blinded by the Lights", ["The Streets"], 406, "ytmusic"), make("Blinding Lights", ["The Weeknd"], 202, "ytmusic")]
    songs = rank_songs([js, yt])
    assert [s.title for s in songs][0] == "Blinding Lights"
    assert len(songs[0].listings) == 2


def test_many_copies_collect_more_votes():
    copies = [make("Blinding Lights", ["The Weeknd"], 204) for _ in range(5)]
    for i, c in enumerate(copies):
        c.id = f"copy-{i}"
    js = copies + [make("Starboy", ["The Weeknd"], 230)]
    yt = [make("Starboy", ["The Weeknd"], 231, "ytmusic")]
    songs = rank_songs([js, yt])
    assert songs[0].title == "Blinding Lights"


def test_both_sources_report_the_explicit_version():
    samples = Path(__file__).parent.parent / "samples"
    raw_js = json.loads((samples / "jiosaavn_search.json").read_text())["results"]
    js = [jiosaavn.to_listing(r) for r in raw_js]
    assert [l.explicit for l in js] == [r["explicit_content"] == "1" for r in raw_js]   # "1" / "0" on every result
    assert any(l.explicit for l in js) and not all(l.explicit for l in js)
    rows = ytmusic.song_rows(json.loads((samples / "ytmusic_search.json").read_text()))
    yt = [ytmusic.to_listing(r) for r in rows]
    assert sum(l.explicit for l in yt) == 1                                 # the one row with the E badge
    assert all(l.explicit is not None for l in yt)                        # no badge: the clean (or only) version
