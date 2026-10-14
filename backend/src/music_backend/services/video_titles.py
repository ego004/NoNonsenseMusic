"""Read a song's title and artist out of a YouTube video's title and channel. No network.

A title is split only when the channel says which side is the artist: "MC STAN - Bitch (Official Audio) | INSAAN" by
MC STAN is "Bitch" by MC STAN. Anything else keeps the video's own title, by the channel. Reading without that
evidence named five MC STAN videos "MC STΔN" ("Song - Film | Cast" guessed the first part was the song, 14 Oct); every
guess of that kind was wrong for some upload. The lyrics lookup asks the music catalogues for a better name
(services/lyrics.py). tests/test_video_titles.py holds real titles, each with its expected reading.
"""
import re

from rapidfuzz import fuzz

from music_backend.services.matching import normalise

_FULLWIDTH = str.maketrans({"（": "(", "）": ")", "【": "[", "】": "]", "‒": "-", "–": "-", "—": "-", "―": "-", "－": "-"})
# a bracketed note about the video, not the song: "(Official Video)", "[4K]", "(Lyrics)". "(Eisu remix)", "(Live ...)"
# name another recording and stay
_LABEL = (r"official|\baudio\b|music\s+video|lyrics?\s+video|lyrical\s+video|lyrics?|letra|visuali[sz]er|\bm/?v\b|\bhd\b|"
          r"\b[48]k\b|full\s+(?:song|video)|performance\s+video|colou?r\s+coded")
_LABEL_GROUP = re.compile(rf"\s*[(\[][^)\]]*(?:{_LABEL})[^)\]]*[)\]]", re.IGNORECASE)
_SEPARATOR = re.compile(r"\s+-\s+|\s*:\s+")
_CHANNEL_SUFFIX = re.compile(r"\s*(?:VEVO|- Topic|Official)\s*$", re.IGNORECASE)
# how alike a side of the title and the channel must be to be the same artist. Measured on the 41 stored "A - B"
# titles (14 Oct): the artist's side scored 71-100 against its own channel ("MC STΔN" for MC STAN 86, "kudasai" for
# kudasaibeats 74), an artist on someone else's channel 46 at most, a song 36 at most
ARTIST_MATCH = 65


def channel_name(channel: str) -> str:
    """The channel as a name: "SonyMusicIndiaVEVO", "Queen - Topic" → without the suffix."""
    return _CHANNEL_SUFFIX.sub("", channel).strip()


def without_video_labels(title: str) -> str:
    """The title without its bracketed notes about the video ("Blinding Lights (Official Video)" → "Blinding Lights")."""
    return " ".join(_LABEL_GROUP.sub("", title.translate(_FULLWIDTH)).split()) or title


def _is_channel(side: str, owner: str) -> bool:
    return fuzz.ratio(normalise(side), normalise(owner)) >= ARTIST_MATCH


def parse_video_title(title: str, channel: str) -> tuple[str, list[str]]:
    """The song's title and artists for a video: split only where one side is the channel. Otherwise the video's own
    title (its labels removed), by the channel."""
    owner = channel_name(channel)
    artists = [owner] if owner else []
    plain = without_video_labels(title)
    if channel.endswith(" - Topic"):                  # an auto-made artist channel: its titles are the song's own
        return plain, artists
    first = without_video_labels(title.split("|")[0])  # "Artist - Song | Album | Year": the song is in the first part
    sides = _SEPARATOR.split(first)
    if owner and len(sides) == 2 and all(s.strip() for s in sides):
        artist_first, artist_last = _is_channel(sides[0], owner), _is_channel(sides[1], owner)
        if artist_first != artist_last:               # both alike ("Song - Song") says nothing
            song = (sides[1] if artist_first else sides[0]).strip()
            if len(song) > 2 and song[0] in "'\"“‘" and song[-1] in "'\"”’":     # 'Dynamite': quotes that wrap it
                song = song[1:-1].strip()
            return song, artists
    return plain, artists
