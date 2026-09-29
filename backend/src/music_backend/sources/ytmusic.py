import httpx

from music_backend.models import Listing

SEARCH_URL = "https://music.youtube.com/youtubei/v1/search"
# the same client identity music.youtube.com sends; an old version string is still accepted
CLIENT = {"clientName" : "WEB_REMIX", "clientVersion" : "1.20250101.01.00", "hl" : "en"}
# what the "Songs" filter chip on music.youtube.com adds to the request
SONGS_ONLY = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
SEPARATOR = " • "
ARTIST_JOINERS = (", ", " & ")
PLAYS_MULTIPLIER = {"K" : 1_000, "M" : 1_000_000, "B" : 1_000_000_000}


async def search(query: str) -> list[Listing]:
    """Search YouTube Music (songs only) and return a list of listings."""
    body = {"context" : {"client" : CLIENT}, "query" : query, "params" : SONGS_ONLY}
    async with httpx.AsyncClient() as client:
        r = await client.post(SEARCH_URL, params = {"prettyPrint" : "false"}, json = body)
        r = r.json()
        listings = []
        for item in song_rows(r):
            listings.append(to_listing(item))
        return listings


def song_rows(response: dict) -> list[dict]:
    """Find the song rows inside YouTube Music's deeply nested search reply."""
    tabs = response.get("contents", {}).get("tabbedSearchResultsRenderer", {}).get("tabs", [])
    if not tabs:
        return []
    sections = tabs[0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"]
    rows = []
    for section in sections:
        # "no results" and "did you mean" sections have no musicShelfRenderer
        if "musicShelfRenderer" in section:
            for row in section["musicShelfRenderer"]["contents"]:
                rows.append(row["musicResponsiveListItemRenderer"])
    return rows


def to_listing(item: dict) -> Listing:
    """Turn one YouTube Music song row into a Listing."""
    title = column(item, 0)[0]["text"]
    # column 1 reads like: Emily Dawn , Vive & Sandy Beach • Blinding Lights • 2:52
    # (artists • album • duration, and the album part can be missing)
    parts = split_on_separator(column(item, 1))
    artists = [run["text"] for run in parts[0] if run["text"] not in ARTIST_JOINERS]
    album = parts[1][0]["text"] if len(parts) == 3 else None
    plays = column(item, 2)
    return Listing(
        source = "ytmusic",
        id = item["playlistItemData"]["videoId"],
        title = title,
        artists = artists,
        album = album,
        duration = to_seconds(parts[-1][0]["text"]),
        popularity = to_count(plays[0]["text"]) if plays else None,
    )


def column(item: dict, index: int) -> list[dict]:
    """The text pieces ("runs") of one column in a song row; empty if the column is missing."""
    columns = item["flexColumns"]
    if index >= len(columns):
        return []
    return columns[index]["musicResponsiveListItemFlexColumnRenderer"]["text"].get("runs", [])


def split_on_separator(runs: list[dict]) -> list[list[dict]]:
    """Split runs into groups wherever the ' • ' separator appears."""
    groups = [[]]
    for run in runs:
        if run["text"] == SEPARATOR:
            groups.append([])
        else:
            groups[-1].append(run)
    return groups


def to_seconds(duration: str) -> int:
    """'3:22' -> 202, '1:02:03' -> 3723."""
    seconds = 0
    for part in duration.split(":"):
        seconds = seconds * 60 + int(part)
    return seconds


def to_count(plays: str) -> int:
    """'952 plays' -> 952, '2.6K plays' -> 2600, '9.5B plays' -> 9500000000."""
    number = plays.split()[0]
    if number[-1] in PLAYS_MULTIPLIER:
        return round(float(number[:-1]) * PLAYS_MULTIPLIER[number[-1]])
    return int(number.replace(",", ""))
