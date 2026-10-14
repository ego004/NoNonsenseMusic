"""Reading a song out of a YouTube video's title: real titles (searched 13 Oct), each with its expected reading."""
import pytest

from music_backend.services.video_titles import parse_video_title, without_video_labels

REAL = [
    # a fullwidth hyphen (U+FF0D) between artist and title, as a dash
    ("Sad Slowed Down", "peacock affect － who cares if you exist (eisu remix)", "who cares if you exist (eisu remix)", "peacock affect"),
    ("ElFamosoDemon", "SHAG - Know The Feelin'", "Know The Feelin'", "SHAG"),     # an apostrophe at the end stays
    # Artist - Title, with labels about the video
    ("The Weeknd", "The Weeknd - Blinding Lights (Official Video)", "Blinding Lights", "The Weeknd"),
    ("7clouds", "The Weeknd - Blinding Lights (Lyrics)", "Blinding Lights", "The Weeknd"),
    ("Latin City", "Ed Sheeran – Shape of You (Lyrics)", "Shape of You", "Ed Sheeran"),
    ("Billie Eilish", "Billie Eilish - bad guy (with Justin Bieber) [Audio]", "bad guy", "Billie Eilish"),
    ("Luis Fonsi", "Luis Fonsi - Despacito ft. Daddy Yankee", "Despacito", "Luis Fonsi"),
    ("Taz Network", "Luis Fonsi ‒ Despacito (Lyrics / Lyric Video) ft. Daddy Yankee", "Despacito", "Luis Fonsi"),
    ("The Weeknd", "The Weeknd - Starboy ft. Daft Punk (Official Video) ft. Daft Punk", "Starboy", "The Weeknd"),
    ("Dua Lipa", "Dua Lipa - Levitating Featuring DaBaby (Official Music Video)", "Levitating", "Dua Lipa"),
    ("Sia", "Sia - Unstoppable (Official Video - Live from the Nostalgic For The Present Tour)", "Unstoppable", "Sia"),
    ("Capital", "Ed Sheeran - ‘Perfect’ - (Live At Capital’s Jingle Bell Ball 2017)", "Perfect", "Ed Sheeran"),
    # a remix or a live take is another recording: its label stays
    ("Ikigai", "Peacock Affect - Who Cares If You Exist (Eisu remix)", "Who Cares If You Exist (Eisu remix)", "Peacock Affect"),
    ("Lofi Shelter", "Eisu - Peacock Affect - Who Cares If You Exist [eisu remix]", "Who Cares If You Exist [eisu remix]",
     "Peacock Affect"),
    # lofi channels: the artist is in the title, not the channel
    ("Ikigai", "Taiko - Leaves", "Leaves", "Taiko"),
    ("Ikigai", "the sleep tape (1hr lofi chillout mix 2022)", "the sleep tape", "Ikigai"),
    # K-pop and J-pop
    ("HYBE LABELS", "BTS (방탄소년단) 'Dynamite' Official MV", "Dynamite", "BTS"),
    ("NewJeans", "NewJeans 'Ditto' Lyrics (뉴진스 Ditto 가사) (Color Coded Lyrics)", "Ditto", "NewJeans"),
    ("YOASOBI", "YOASOBI「アイドル」 Official Music Video", "アイドル", "YOASOBI"),
    ("mimanimi", "YOASOBI - Idol「アイドル」Lyrics Video [Kan/Rom/Eng] Oshi no Ko (推しの子) OP", "Idol", "YOASOBI"),
    ("Jamong", "Chainsaw Man - Opening FULL ''KICK BACK\" by Kenshi Yonezu (Lyrics)", "KICK BACK", "Kenshi Yonezu"),
    # colon: the channel tells which side is the artist; otherwise a film's song
    ("Diljit Dosanjh", "Diljit Dosanjh: LOVER (Official Music Video) Intense | Raj Ranjodh | MoonChild Era", "LOVER", "Diljit Dosanjh"),
    ("Diljit Dosanjh", "LOVER: Diljit Dosanjh (Official Audio) Intense | Raj Ranjodh | MoonChild Era | Latest Song 2021", "LOVER", "Diljit Dosanjh"),
    ("T-Series", "Jawan: Chaleya (Lyrical Video) | Shah Rukh Khan | Nayanthara | Atlee | Anirudh", "Chaleya", "T-Series"),
    ("T-Series", "Aashiqui 2: Tum Hi Ho 8K Full Song | Aditya Roy Kapur | Shraddha Kapoor | Arijit Singh | Mithoon", "Tum Hi Ho", "T-Series"),
    ("T-Series Telugu", "Full Video: Naatu Naatu Song (Telugu) | RRR Songs | NTR,Ram Charan | MM Keeravaani", "Naatu Naatu (Telugu)", "T-Series Telugu"),
    # a label's metadata line: the song first; the artist only when the channel names it
    ("Sony Music India", "Kesariya - Brahmāstra | Ranbir Kapoor, Alia Bhatt | Pritam | Arijit Singh | Amitabh Bhattacharya| 4K",
     "Kesariya", "Sony Music India"),
    ("Sony Music India", "Kesariya 8K/4K Music Video | Arijit Singh | Ranbir Kapoor | Alia Bhatt | Pritam | Brahmāstra", "Kesariya", "Sony Music India"),
    ("APDHILLON", "BROWN MUNDE - AP DHILLON | GURINDER GILL | SHINDA KAHLON (Official Music Video)", "BROWN MUNDE", "AP DHILLON"),
    ("Coke Studio Pakistan", "Coke Studio | Season 14 | Pasoori | Ali Sethi x Shae Gill", "Pasoori", "Coke Studio Pakistan"),
    ("Coke Studio Pakistan", "Coke Studio Season 9| Afreen Afreen| Rahat Fateh Ali Khan & Momina Mustehsan", "Afreen Afreen", "Coke Studio Pakistan"),
    # an artist's auto-made channel: its titles are the song's own
    ("Queen - Topic", "Bohemian Rhapsody - Remastered 2011", "Bohemian Rhapsody - Remastered 2011", "Queen"),
]


@pytest.mark.parametrize("channel,title,song,artist", REAL)
def test_a_real_video_title_reads_as_its_song(channel, title, song, artist):
    assert parse_video_title(title, channel) == (song, [artist])


def test_a_music_videos_title_loses_only_its_labels():
    # YouTube Music's music videos name the artist themselves: only the labels go, and a dash is not split
    assert without_video_labels("Blinding Lights (Official Video)") == "Blinding Lights"
    assert without_video_labels("Kesariya - Brahmāstra") == "Kesariya - Brahmāstra"
