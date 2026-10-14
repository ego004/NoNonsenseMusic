"""Read a song's title and artist out of a YouTube video's title and channel. Best effort, no network.

A video title is written for people: "The Weeknd - Blinding Lights (Official Video)", "BTS (방탄소년단) 'Dynamite' Official
MV", "YOASOBI「アイドル」Official Music Video", "JAWAN: Chaleya (Hindi) | Shah Rukh Khan | ...", "Taiko - Leaves" by a lofi
channel. The channel is the artist only on an artist's own channel. Some titles cannot be settled by reading alone
("LOVER: Diljit Dosanjh" beside "Diljit Dosanjh: LOVER", a cover's "Song - Singer" in Devanagari): the lyrics lookup
asks the music catalogues first (services/lyrics.py), and these rules are the fallback, and what the apps show for a
plain-YouTube result. tests/test_video_titles.py holds real titles, each with its expected reading.
"""
import re

from music_backend.services.matching import normalise

_FULLWIDTH = str.maketrans({"（": "(", "）": ")", "【": "[", "】": "]", "‒": "-", "–": "-", "—": "-", "―": "-", "－": "-"})
# words that describe the video, not the song. "(Eisu remix)", "(slowed)", "(Live ...)", "(Acoustic)" name another
# recording and stay
_LABEL = (r"official|\baudio\b|music\s+video|lyrics?\s+video|lyrical\s+video|lyrics?|letra|visuali[sz]er|\bm/?v\b|\bhd\b|"
          r"\b[48]k\b|full\s+(?:song|video)|performance\s+video|animated|colou?r\s+coded|\d+\s*(?:hrs?|hours?)\b|"
          r"beattape|kan/rom/eng")
_LABEL_GROUP = re.compile(rf"[(\[][^)\]]*(?:{_LABEL})[^)\]]*[)\]]", re.IGNORECASE)
_LABEL_BARE = re.compile(rf"(?:\b[48]k/[48]k\b|{_LABEL})", re.IGNORECASE)
# a pipe-separated segment about the upload, never the song: "Coke Studio", "Season 14", "Full Song", "Latest ... 2026"
_NOISE = re.compile(r"^(?:coke\s+studio(?:\s+season\s+\d+)?|season\s+\d+|full\s+song|lyrics?|.*\blatest\b.*)$", re.IGNORECASE)
_FEAT_IN_BRACKETS = re.compile(r"\s*[(\[]\s*(?:ft\.?|feat\.?|featuring|with)\s+[^)\]]*[)\]]", re.IGNORECASE)
_FEAT_TRAILING = re.compile(r"\s+(?:ft\.?|feat\.?|featuring)\s+[^()\[\]|]+", re.IGNORECASE)
_DASH = re.compile(r"\s+-\s+")
# "''KICK BACK" by Kenshi Yonezu": a quoted title, then its artist
_QUOTED_BY = re.compile(r"['\"“‘]{1,2}(?P<title>[^'\"”’]+)['\"”’]{1,2}\s+by\s+(?P<artist>[^()\[\]]+)", re.IGNORECASE)
# Artist 'Title' / Artist「Title」: K-pop and J-pop uploads
_QUOTED = re.compile(r"^(?P<artist>[^'\"“‘「『]+?)\s*['\"“‘「『]+(?P<title>[^'\"”’」』]+)['\"”’」』]+")
_JAPANESE_ASIDE = re.compile(r"\s*[「『][^」』]*[」』]")       # "Idol「アイドル」": the same title again, in Japanese
_HANGUL_ASIDE = re.compile(r"\s*\([가-힣\s]+\)")      # "BTS (방탄소년단)": the same name again, in Hangul
_BY = re.compile(r"^(?P<title>.+?)\s+by\s+(?P<artist>[^()\[\]]+?)$", re.IGNORECASE)
_CHANNEL_SUFFIX = re.compile(r"\s*(?:VEVO|- Topic|Official)\s*$", re.IGNORECASE)


def channel_name(channel: str) -> str:
    """The channel as a name: "SonyMusicIndiaVEVO", "Queen - Topic" → without the suffix."""
    return _CHANNEL_SUFFIX.sub("", channel).strip()


def _same(a: str, b: str) -> bool:
    """One name, written two ways: "AP DHILLON" and "APDHILLON", "Diljit Dosanjh" and "diljit dosanjh"."""
    x, y = normalise(a).replace(" ", ""), normalise(b).replace(" ", "")
    return bool(x) and x == y


def _before_labels(text: str) -> str:
    """The text up to the first label about the video ("LOVER (Official Music Video) Intense" → "LOVER"); a label that
    opens the text ("Full Video: Naatu Naatu") is dropped instead."""
    text = _FEAT_IN_BRACKETS.sub("", text)
    text = _FEAT_TRAILING.sub("", text)
    for pattern in (_LABEL_GROUP, _LABEL_BARE):
        found = pattern.search(text)
        while found and not text[:found.start()].strip(" :-|"):
            text = text[found.end():]
            found = pattern.search(text)
        if found:
            text = text[:found.start()]
    return text.strip(" :-|")


def _clean(title: str) -> str:
    title = _JAPANESE_ASIDE.sub("", title) if re.search(r"[A-Za-z]", title) else title
    title = re.sub(r"\s+song(?=\s*(?:\(|$))", "", title.strip(), flags=re.IGNORECASE)   # "Naatu Naatu Song (Telugu)"
    title = re.sub(r"(?<=\S)\(", " (", title)                          # "KICK BACK(Live" once （ became (
    title = re.sub(r"\s+", " ", title).strip()
    # quotes that wrap the whole title go ('"e l u s i v e"'); one at an end is part of it ("Know The Feelin'", 13 Oct)
    while len(title) > 1 and title[0] in "'\"“‘" and title[-1] in "'\"”’":
        title = title[1:-1].strip()
    return title


def _artist(name: str) -> str:
    return _HANGUL_ASIDE.sub("", name).strip(" -:'\"“”‘’")


def without_video_labels(title: str) -> str:
    """The title without what describes the video ("Blinding Lights (Official Video)" → "Blinding Lights"), for a title
    that names the song alone: a Topic channel's, a YouTube Music music video's."""
    return _clean(_before_labels(title.translate(_FULLWIDTH))) or title


def parse_video_title(title: str, channel: str) -> tuple[str, list[str]]:
    """The song's title and artists for a video, best effort. Without a better reading: the title, by the channel."""
    owner = channel_name(channel)
    fallback = [owner] if owner else []
    text = title.translate(_FULLWIDTH)
    if channel.endswith(" - Topic"):                  # an auto-made artist channel: its titles are the song's own
        return without_video_labels(title), fallback

    quoted_by = _QUOTED_BY.search(text)
    if quoted_by:
        return _clean(quoted_by["title"]), [quoted_by["artist"].strip()]

    segments = [s.strip() for s in text.split("|")]
    # a label's metadata line ("Song - Film | Cast | Composer | Singer"): three segments or more, the song first
    piped = len(segments) >= 3
    if "|" in text:
        text = next((s for s in segments if s and not _NOISE.match(s) and _before_labels(s)), segments[0])

    quoted = _QUOTED.match(text)
    if quoted and not _DASH.search(quoted["artist"]):
        return _clean(quoted["title"]), [_artist(quoted["artist"])]

    text = _before_labels(text)
    parts = [p for p in _DASH.split(text) if p.strip() and not re.fullmatch(r"\s*[(\[].*[)\]]\s*", p)]
    if len(parts) >= 2:
        if piped:                                     # "Kesariya - Brahmāstra | ...", "BROWN MUNDE - AP DHILLON | ..."
            if _same(parts[0], owner) and not _same(parts[1], owner):
                # "Artist - Song | Album | Year" on the artist's own channel: "MC STAN - Bitch (Official Audio) | INSAAN |
                # 2022" read as a song called "MC STAN" (14 Oct)
                return _clean(parts[1]), [_artist(parts[0])]
            artist = parts[1] if _same(parts[1], owner) else (fallback[0] if fallback else parts[1])
            return _clean(parts[0]), [artist]
        artist, name = parts[-2], parts[-1]           # "Artist - Title"; with more dashes, the last two
        if _same(name, owner) and not _same(artist, owner):
            artist, name = name, artist               # "Title - Artist" on the artist's own channel
        return _clean(name), [_artist(artist)]
    if ":" in text:
        left, right = (s.strip() for s in text.split(":", 1))
        if _same(left, owner):                        # "Diljit Dosanjh: LOVER" by Diljit Dosanjh
            return _clean(right), [left]
        if _same(right, owner):                       # "LOVER: Diljit Dosanjh" by Diljit Dosanjh
            return _clean(left), [right]
        return _clean(right), fallback                # "JAWAN: Chaleya": a film's song, its artist not written here
    by = _BY.match(text)
    if by:
        return _clean(by["title"]), [by["artist"].strip()]
    return _clean(text) or title, fallback
