"""Reading a song out of a YouTube video's title: real titles (13-14 Oct), each with its expected reading."""
import pytest

from music_backend.services.video_titles import parse_video_title, without_video_labels

REAL = [
    # one side is the channel: the other side is the song
    ("MC STAN", "MC STAN - Bitch (Official Audio) | INSAAN | 2022", "Bitch", "MC STAN"),
    ("MC STAN", "MC STΔN - NUMBERKARI | TADIPAAR | 2K20", "NUMBERKARI", "MC STAN"),     # was "MC STΔN" (14 Oct)
    ("MC STAN", "MC STΔN - SNAKE  (Official Music Video)", "SNAKE", "MC STAN"),
    ("kudasaibeats", "kudasai - technicolor", "technicolor", "kudasaibeats"),
    ("Seedhe Maut", "Khatta Flow - Seedhe Maut ft KR$NA", "Khatta Flow", "Seedhe Maut"),
    ("APDHILLON", "BROWN MUNDE - AP DHILLON | GURINDER GILL | SHINDA KAHLON (Official Music Video)", "BROWN MUNDE", "APDHILLON"),
    ("Diljit Dosanjh", "Diljit Dosanjh: LOVER (Official Music Video) Intense | Raj Ranjodh | MoonChild Era", "LOVER Intense", "Diljit Dosanjh"),
    ("The Weeknd", "The Weeknd - Blinding Lights (Official Video)", "Blinding Lights", "The Weeknd"),
    ("Billie Eilish", "Billie Eilish - bad guy (with Justin Bieber) [Audio]", "bad guy (with Justin Bieber)", "Billie Eilish"),
    ("Seedhe Maut", "Seedhe Maut - 'Nanchaku' ft MC STΔN | Azadi Records", "'Nanchaku' ft MC STΔN", "Seedhe Maut"),
    # neither side is the channel: the video's own title. "Taiko - Leaves" re-uploaded by Ikigai may be "Leaves" by
    # Taiko, and "Kesariya - Brahmāstra" a song from a film; nothing in the video says so
    ("Ikigai", "Taiko - Leaves", "Taiko - Leaves", "Ikigai"),
    ("7clouds", "The Weeknd - Blinding Lights (Lyrics)", "The Weeknd - Blinding Lights", "7clouds"),
    ("Sony Music India", "Kesariya - Brahmāstra | Ranbir Kapoor, Alia Bhatt | Pritam", "Kesariya - Brahmāstra | Ranbir Kapoor, Alia Bhatt | Pritam", "Sony Music India"),
    ("YRF", "Lyrical | Tum Ho Toh Song | Saiyaara | Ahaan, Aneet", "Lyrical | Tum Ho Toh Song | Saiyaara | Ahaan, Aneet", "YRF"),   # was "al"
    ("T-Series", "\"Kabira Full Song\" Yeh Jawaani Hai Deewani | Pritam", "\"Kabira Full Song\" Yeh Jawaani Hai Deewani | Pritam", "T-Series"),
    ("HYBE LABELS", "BTS (방탄소년단) 'Dynamite' Official MV", "BTS (방탄소년단) 'Dynamite' Official MV", "HYBE LABELS"),
    ("Sad Slowed Down", "peacock affect － who cares if you exist (eisu remix)", "peacock affect - who cares if you exist (eisu remix)", "Sad Slowed Down"),
    # an artist's auto-made channel: its titles are the song's own
    ("Queen - Topic", "Bohemian Rhapsody - Remastered 2011", "Bohemian Rhapsody - Remastered 2011", "Queen"),
]


@pytest.mark.parametrize("channel,title,song,artist", REAL)
def test_a_real_video_title_reads_as_its_song(channel, title, song, artist):
    assert parse_video_title(title, channel) == (song, [artist])


def test_a_title_naming_the_channel_on_both_sides_is_not_split():
    assert parse_video_title("MC STAN - MC STΔN", "MC STAN") == ("MC STAN - MC STΔN", ["MC STAN"])


def test_only_bracketed_notes_about_the_video_go():
    assert without_video_labels("Blinding Lights (Official Video)") == "Blinding Lights"
    assert without_video_labels("Kesariya - Brahmāstra") == "Kesariya - Brahmāstra"
    assert without_video_labels("Who Cares If You Exist (Eisu remix)") == "Who Cares If You Exist (Eisu remix)"
    assert without_video_labels("Lyrics") == "Lyrics"                 # a song may be called that
