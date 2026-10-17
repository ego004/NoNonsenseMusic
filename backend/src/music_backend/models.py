"""Pydantic models for the music backend's endpoints.

Request and response shapes for search, playback, playlists, lyrics, authentication,
friends, notifications and jam rooms.
"""

import math
from datetime import datetime
from typing import Annotated, Any, Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from music_backend.services.images import Image

# The one list of source IDs, used by every model, SOURCES in main.py, and the /play URL.
# Lowercase, no spaces: they appear in URLs (/play/ytmusic/...) and must never drift between files.
# Display names like "YouTube Music" belong to a UI, not here.
SourceName = Literal["jiosaavn", "ytmusic", "youtube"]

class Listing(BaseModel):
    source : SourceName
    id : str
    title : str
    artists : list[str]
    album: str | None
    duration: int
    popularity : int | None
    # artwork URL, at its host's largest size (services/images.py)
    image : Image = None
    # the explicit version (JioSaavn's explicit_content, YouTube Music's E badge); None: not known (older rows)
    explicit : bool | None = None

# Limits on what a client may send. Real values are far inside them (the longest title seen is ~120 characters); they
# only stop one request from filling the database or the memory of a server on the internet.
MAX_DURATION = 86_400                       # seconds: a day. Also keeps the value inside Postgres' integer
MAX_LISTINGS = 50                           # one song's copies, or one batch of songs
MAX_JAM_COPIES = 4                          # a jam song's other copies: enough fallbacks, and a command stays small
NAME_MAX = 100                              # a playlist's name


class ListingIn(Listing):
    """A listing as a client sends it: the same fields as Listing, with limits.

    Listing itself stays lenient because it also carries what the sources return, and a source's odd row (a song whose
    duration is unknown is 0) must not vanish. Requests use this class; the server's own copy of the listing is what
    gets stored (library.trusted_listings), so these limits bound the request's size more than they vouch for its text.
    """
    id : str = Field(max_length = 100)
    title : str = Field(max_length = 300)
    artists : list[Annotated[str, Field(max_length = 200)]] = Field(max_length = 20)
    album : str | None = Field(max_length = 300)
    duration : int = Field(gt = 0, le = MAX_DURATION)
    popularity : int | None = Field(ge = 0, le = 10**13)
    image : Image = Field(default = None, max_length = 1000)


class BaseSong(BaseModel):
    # search sets a stored song's cover after building it: that goes through Image too
    model_config = ConfigDict(validate_assignment = True)

    title: str
    artists: list[str] | None
    duration: int
    best: Listing
    listings: list[Listing]
    # the song's cover, the same whichever copy plays: songs.image for a stored song, else pick_cover
    image: Image = None

class LibrarySong(BaseSong):
    """A stored song as the app shows it: identity from the database, display from its best listing."""
    id : UUID
    liked : bool
    at : datetime | None = None   # liked_at for /liked, last played for /recent

class Song(BaseSong):
    score: float
    # a search's song from the user's own library (liked, or in one of their playlists): listed first (#26). Sent only
    # when true, so every other reply that carries songs stays as it was
    in_library: bool = Field(default = False, exclude_if = lambda in_library: not in_library)

class SearchSourceInfo(BaseModel):
    source : SourceName
    healthy : bool
    num_results : int          # songs found
    ms : int
    # album and artist searches run in the same round; 0 when that filter was not asked for
    num_albums : int = 0
    num_artists : int = 0
    error : str | None = Field(default = None, exclude_if = lambda error: error is None)


class AlbumRef(BaseModel):
    """One source's copy of an album: enough to open it via GET /album/{source}/{id}."""
    source : SourceName
    id : str
    title : str
    artists : list[str]
    year : int | None = None
    image : Image = None
    song_count : int | None = None
    explicit : bool | None = None


class Album(BaseModel):
    """The same album found on one or more sources: shown with the preferred copy's details."""
    title : str
    artists : list[str]
    year : int | None = None
    image : Image = None
    song_count : int | None = None
    explicit : bool | None = None
    score : float
    best : AlbumRef
    listings : list[AlbumRef]


class ArtistRef(BaseModel):
    """One source's copy of an artist: enough to open it via GET /artist/{source}/{id}."""
    source : SourceName
    id : str
    name : str
    image : Image = None


class Artist(BaseModel):
    """The same artist found on one or more sources (a channel on plain YouTube counts)."""
    name : str
    image : Image = None
    score : float
    best : ArtistRef
    listings : list[ArtistRef]


class AlbumDetail(BaseModel):
    """One source's album page: metadata plus its tracks, in track order.

    Songs are single-listing groups with score 0: ordinary playable songs, so an album's tracks
    play exactly like search results. Nothing here is stored in the database.
    """
    source : SourceName
    id : str
    title : str
    artists : list[str]
    year : int | None = None
    image : Image = None
    explicit : bool | None = None
    songs : list[Song] = []


class ArtistDetail(BaseModel):
    """One source's artist page: info plus top songs (best-first) and albums."""
    source : SourceName
    id : str
    name : str
    image : Image = None
    bio : str | None = None
    followers : int | None = None
    monthly_listeners : int | None = None
    songs : list[Song] = []
    albums : list[AlbumRef] = []


class SearchResponse(BaseModel):
    query : str
    sources : list[SearchSourceInfo]
    songs : list[Song]
    albums : list[Album] = []
    artists : list[Artist] = []


EventType = Literal["play", "skip", "finish"]


class ListingsRequest(BaseModel):
    # IDs are assigned lazily: the app sends the song's listings, the server finds or creates the song
    listings : list[ListingIn] = Field(min_length = 1, max_length = MAX_LISTINGS)


class EventRequest(ListingsRequest):
    type : EventType
    position : int = Field(ge = 0, le = MAX_DURATION)


class SongRef(BaseModel):
    song_id : UUID

class PlaylistRequest(BaseModel):
    name : str = Field(min_length=1, max_length=NAME_MAX)

class PinAlbumRequest(BaseModel):
    """POST /albums/pin: copy a source's album into the user's playlists as a pinned album."""
    source : SourceName
    source_id : str = Field(min_length=1, max_length=100)

# The credential limits, in one place. the users table's CHECK on username (migrations/0001) repeats the 3 and 32 as a last guard
USERNAME_MIN, USERNAME_MAX = 3, 32
PASSWORD_MIN = 8
# a maximum too: Argon2 hashes any length, slowly, so a 10 MB "password" per sign-up would burn the server's CPU.
# 64 is the least NIST asks a service to allow
PASSWORD_MAX = 64
DEVICE_NAME_MAX = 64

class PlaylistUpdate(BaseModel):
    """PATCH /playlists/{id}: change the name, the public flag, or both; owner role only. Missing = unchanged."""
    name : str | None = Field(default=None, min_length=1, max_length=NAME_MAX)
    public : bool | None = None

class ShareRequest(BaseModel):
    """PUT /playlists/{id}/members: invite someone by username, or change their role."""
    username : str = Field(max_length=USERNAME_MAX)
    role : Literal["viewer", "editor"]

class Member(BaseModel):
    """GET /playlists/{id}/members: one person on a playlist: its owner, or someone it is shared with."""
    user_id : UUID
    username : str
    role : Literal["owner", "editor", "viewer"]

class PlaylistMetadata(BaseModel):
    id : UUID
    name : str
    song_count : int
    thumbnail : str | None = None
    duration : int
    # sharing: anyone signed in can view a public playlist; the user's role states what the app
    # may offer (owner: everything; editor: add, remove, reorder songs; viewer: look and play)
    public : bool = False
    role : Literal["owner", "editor", "viewer"] = "owner"
    # a pinned album is playlist-shaped but read-only: its tracks are a snapshot taken when it was pinned.
    # source/source_id say which album on which source; both null for a normal playlist
    kind : Literal["playlist", "album"] = "playlist"
    source : SourceName | None = None
    source_id : str | None = None

class PlaylistsResponse(BaseModel):
    playlists : list[PlaylistMetadata]

class MoveRequest(BaseModel):
    top_neighbour_id : UUID | None = None
    bottom_neighbour_id : UUID | None = None

class PlaylistItem(BaseModel):
    item_id : UUID
    song: LibrarySong

class PlaylistItems(PlaylistMetadata):
    items : list[PlaylistItem]

class PlaylistItemRef(BaseModel):
    item_id : UUID
    song_id : UUID

class PrefetchListing(BaseModel):
    source: SourceName
    source_id : str = Field(max_length = 100)

class PrefetchRequest(BaseModel):
    # the app sends 5 to 10; the maximum stops one request from queueing thousands of lookups
    listings : list[PrefetchListing] = Field(min_length = 1, max_length = MAX_LISTINGS)

class RadioRequest(BaseModel):
    """Body of POST /radio: more songs after the queue runs low, seeded from its last song.

    exclude holds the ids already in the queue or recently played, so the station does not
    repeat them. The server also excludes the account's last 50 played songs (a skipped song was
    played first), unless skip_recent is off (Settings › Playback › Autoplay).
    """
    seed : PrefetchListing
    exclude : list[PrefetchListing] = Field(default = [], max_length = 100)
    limit : int = Field(default = 25, ge = 1, le = 50)
    skip_recent : bool = True

class RadioResponse(BaseModel):
    songs : list[Song]

class LyricsRequest(BaseModel):
    song_name : str = Field(max_length = 300)
    artist_name : str = Field(max_length = 300)     # LRCLIB answers 400 without one
    song_duration : int = Field(ge = 0, le = MAX_DURATION)      # seconds
    # the song's ytmusic listing, if any (even when JioSaavn's copy plays)
    youtube_id : str | None = Field(default = None, max_length = 300)

class LyricLine(BaseModel):
    start_ms : int | None                   # None: plain lyrics, no times. A line ends where the next one starts
    text : str
    # some LRCLIB uploads carry a translation on each line as "original^translation": the original is the line, the
    # rest is kept here. Split whenever a line is built, so lyrics cached before this was known come out split too
    translation : str | None = Field(default = None, exclude_if = lambda translation: translation is None)

    @model_validator(mode="before")
    @classmethod
    def _split_translation(cls, data: Any) -> Any:
        if isinstance(data, dict) and "^" in (data.get("text") or "") and not data.get("translation"):
            original, _, translated = data["text"].partition("^")
            data = {**data, "text": original.strip(), "translation": translated.strip() or None}
        return data

class LyricsResponse(BaseModel):
    lyrics_source : Literal["lrclib", "ytmusic"] | None   # None: nobody had lyrics (lines is [])
    synced : bool
    lines : list[LyricLine]


class GeniusRequest(BaseModel):
    song_name : str = Field(max_length = 300)
    artist_name : str = Field(max_length = 300)

class GeniusNote(BaseModel):
    fragment : str                          # the words of the song it is about, as Genius quotes them
    text : str                              # the note, plain text
    verified : bool = False                 # written or confirmed by the artist

class GeniusAbout(BaseModel):
    description : str | None
    produced_by : list[str]
    samples : list[str]                     # "Song by Someone"

class GeniusResponse(BaseModel):
    """Reply to a Genius lookup: always HTTP 200, even when the song is absent (`url` None, no notes)."""
    url : str | None                        # the song's page on Genius: the notes are credited to it
    notes : list[GeniusNote]
    about : GeniusAbout | None


class SignUpRequest(BaseModel):
    username : str = Field(min_length=USERNAME_MIN, max_length=USERNAME_MAX)
    password : str = Field(min_length=PASSWORD_MIN, max_length=PASSWORD_MAX)
    device_name : str = Field(default="Unknown Device", max_length=DEVICE_NAME_MAX)

class SignInRequest(BaseModel):
    """Validation for sign-in: unlike sign-up, only the maximum lengths apply.

    PASSWORD_MIN may rise, and an older account's shorter password must still reach the password
    check rather than stop at a 422.
    """
    username : str = Field(max_length=USERNAME_MAX)
    password : str = Field(max_length=PASSWORD_MAX)
    device_name : str = Field(default="Unknown Device", max_length=DEVICE_NAME_MAX)

class User(BaseModel):
    """The signed-in user: what current_user gives routes and what /auth/me returns.

    Only these fields ever reach a reply, so a password hash cannot leak through a careless
    `return user`.
    """
    id : UUID
    username : str

class DeviceNameRequest(BaseModel):
    """PATCH /auth/me/device: what this device is called in the user's device list."""
    device_name : str = Field(min_length=1, max_length=DEVICE_NAME_MAX)

class Session(BaseModel):
    """Reply to sign-up, sign-in and recovery: the only time the token itself is sent.

    `recovery_codes` appears at sign-up only, the one time the codes are shown.
    """
    token : str
    user : User
    recovery_codes : list[str] | None = None

class RecoverRequest(BaseModel):
    """POST /auth/recover: the way back in with a recovery code: a new password, and this device signed in."""
    username : str = Field(max_length=USERNAME_MAX)
    code : str = Field(max_length=40)
    new_password : str = Field(min_length=PASSWORD_MIN, max_length=PASSWORD_MAX)
    device_name : str = Field(default="Unknown Device", max_length=DEVICE_NAME_MAX)

class PasswordRequest(BaseModel):
    """POST /auth/recovery-codes: a new set needs the password again (a session alone is not enough)."""
    password : str = Field(max_length=PASSWORD_MAX)

class RecoveryCodes(BaseModel):
    codes : list[str]

class RecoveryCodesLeft(BaseModel):
    left : int


class FriendUser(BaseModel):
    """One person in a friends list or a request list: who they are, and when the relationship
    began (or was asked for).
    """
    user_id: UUID
    username: str
    since: datetime                            # friends_since for friends, created_at for requests


class FriendRequests(BaseModel):
    """GET /friends/requests: the requests waiting on the user, and the ones the user is waiting on."""
    incoming: list[FriendUser]
    outgoing: list[FriendUser]


class FriendRequest(BaseModel):
    """POST /friends/request: ask someone to become a friend. Only their username is needed."""
    username: str = Field(max_length=USERNAME_MAX)


class RespondRequest(BaseModel):
    """POST /friends/respond: accept or decline someone's request. The username identifies which one."""
    username: str = Field(max_length=USERNAME_MAX)
    action: Literal["accept", "decline"]


# ---------- notifications ----------

NotificationType = Literal["friend_request", "friend_accepted", "playlist_invite", "jam_invite"]


class FriendRequestPayload(BaseModel):
    from_user_id: UUID
    from_username: str


class FriendAcceptedPayload(BaseModel):
    by_user_id: UUID
    by_username: str


class PlaylistInvitePayload(BaseModel):
    playlist_id: UUID
    playlist_name: str
    from_user_id: UUID
    from_username: str


class JamInvitePayload(BaseModel):
    room_id: UUID
    code: str
    room_name: str | None
    from_user_id: UUID
    from_username: str


# one place mapping type -> payload model: services/notifications.py validates before INSERT,
# so a typo in a caller's dict never reaches the database
NOTIFICATION_PAYLOAD_MODELS: dict[str, type[BaseModel]] = {
    "friend_request": FriendRequestPayload,
    "friend_accepted": FriendAcceptedPayload,
    "playlist_invite": PlaylistInvitePayload,
    "jam_invite": JamInvitePayload,
}


class Notification(BaseModel):
    id: UUID
    user_id: UUID                      # who it is for (push target; excluded from client-facing JSON below)
    type: NotificationType
    payload: dict[str, Any]            # already validated on the way in; read back as-is
    seq: int                           # monotonically increasing (catch-up cursor)
    read: bool
    created_at: datetime


class NotificationsResponse(BaseModel):
    notifications: list[Notification]
    unread_count: int


class WSTicket(BaseModel):
    """Reply to POST /ws-ticket: a single-use, short-lived token for the WebSocket handshake.

    The JWT itself never appears in a URL query string, where access logs, proxies and browser
    history would record it.
    """
    ticket: str
    expires_in: int                  # seconds (30)


class MarkReadResponse(BaseModel):
    unread_count: int

# ---- jam: one room, one host plays, everyone else holds the remote ----

class JamQueueEntry(BaseModel):
    """One song waiting in a jam room's queue.

    The listing is the app's own search result, sent as-is: the room never writes to the
    database, and every member's player plays it through /play like any other song. `copies` are the song's other
    copies, best first: a member whose device cannot play `listing` (a copy that will not load there) plays one of
    those instead of going silent. Apps from before copies send none.
    """
    entry_id: UUID
    listing: Listing
    copies: list[Listing] = []


class JamMember(BaseModel):
    user_id: UUID
    username: str


class JamState(BaseModel):
    """Everything a client needs to render the room.

    position_seconds is the playhead at the moment this state was built: add the time since
    receipt when displaying it, or use the lighter {"type":"position"} pushes that arrive while
    a song plays.
    """
    room_id: UUID
    code: str
    name: str | None
    host_id: UUID
    members: list[JamMember]
    current: JamQueueEntry | None
    is_playing: bool
    position_seconds: float
    queue: list[JamQueueEntry]
    # Two host settings, off by default: every member hears the room's song, in step, and controls it.
    # only_host_plays: the room plays on the host's device alone (friends in one room); every other member's player
    # follows without sound. only_host_controls: members may only add songs to the end of the queue.
    only_host_plays: bool = False
    only_host_controls: bool = False


class JamSong(BaseModel):
    """The song on screen when someone starts or joins a jam: a room with no song takes it, from that second, playing or
    paused as it was (docs/jam.md). It comes with the request, so nothing lands between the room opening and the song
    joining it: the apps used to add it, then seek it, after the room's first state, which was empty."""
    listing: ListingIn
    copies: list[ListingIn] = Field(default=[], max_length=MAX_JAM_COPIES)     # its other copies, best first
    seconds: float = Field(default=0, ge=0)
    playing: bool = True

    @field_validator("seconds")
    @classmethod
    def _finite_seconds(cls, v: float) -> float:
        if not math.isfinite(v):                         # as JamCommand's: NaN would poison every broadcast
            raise ValueError("seconds must be a finite number")
        return v


class JamCreateRequest(BaseModel):
    name: str | None = Field(default=None, max_length=40)
    song: JamSong | None = None


class JamJoinRequest(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    song: JamSong | None = None


class JamInviteRequest(BaseModel):
    username: str = Field(max_length=USERNAME_MAX)


class JamHostRequest(BaseModel):
    """POST /jam/{room_id}/host: the current host gives the speakers to this member."""
    member_id: UUID


# One shape for every control message over /ws/jam; the handler checks which fields the type needs.
class JamCommand(BaseModel):
    type: Literal["play", "pause", "seek", "skip", "add", "remove", "move", "jump", "ended", "position",
                  "only_host_plays", "only_host_controls"]
    seconds: float | None = None                 # seek, position
    listings: list[ListingIn] | None = Field(default=None, max_length=MAX_LISTINGS)    # add
    # add: each song's other copies, in the order of `listings` (the same length when sent); best first
    copies: list[Annotated[list[ListingIn], Field(max_length=MAX_JAM_COPIES)]] | None = Field(
        default=None, max_length=MAX_LISTINGS)
    on: bool | None = None                       # only_host_plays, only_host_controls: the setting's new value
    entry_id: UUID | None = None                 # remove, move, jump, ended
    to_index: int | None = None                  # move: 0-based index in the queue
    # add: "end" queues the songs last; "next" puts them first in the queue; "now" plays the first at once (the song
    # playing is dropped, as jump does) with the rest next. One command, so no other member's change lands in between
    placement: Literal["end", "next", "now"] = "end"

    @field_validator("seconds")
    @classmethod
    def _finite_seconds(cls, v: float | None) -> float | None:
        # NaN/Infinity survive a "< 0" check and then poison the room's position and every
        # JSON broadcast of it; reject them here before they reach the room
        if v is not None and not math.isfinite(v):
            raise ValueError("seconds must be a finite number")
        return v


# ---------- Spotify import ----------
# The app reads Spotify's file on the device and sends only these fields; the server finds each song on its sources.
IMPORT_MAX_SONGS = 10_000

class SpotifyImportSong(BaseModel):
    """A song from Spotify (title and artists) or from YouTube (its video id; the title, when the file has it)."""
    title : str = Field(default="", max_length=300)
    artists : list[Annotated[str, Field(max_length=200)]] = Field(default_factory=list, max_length=20)
    duration_ms : int | None = Field(default=None, ge=0, le=6 * 3600 * 1000)
    youtube_id : str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{11}$")

    @model_validator(mode="after")
    def _named(self):
        if not self.title and not self.youtube_id:
            raise ValueError("a song needs a title or a YouTube video id")
        return self

class SpotifyImportGroup(BaseModel):
    """One list to import, and where it goes: playlist_id = an existing playlist you can edit; else name = a new
    playlist; else Liked Songs. youtube_playlist (a link or an id) is read by the server, and a new playlist for it is
    named after it unless name says otherwise."""
    name : str | None = Field(default=None, min_length=1, max_length=NAME_MAX)
    playlist_id : UUID | None = None
    youtube_playlist : str | None = Field(default=None, min_length=2, max_length=300)
    songs : list[SpotifyImportSong] = Field(default_factory=list, max_length=IMPORT_MAX_SONGS)

    @model_validator(mode="after")
    def _something(self):
        if not self.songs and not self.youtube_playlist:
            raise ValueError("a list needs songs or a YouTube playlist")
        return self

class SpotifyImportRequest(BaseModel):
    groups : list[SpotifyImportGroup] = Field(min_length=1, max_length=500)

class SpotifyImportStatus(BaseModel):
    id : UUID
    total : int
    done : int
    added : int
    missing : list[str]          # the first 200 songs not found, "Title — Artist"
    finished : bool
    failed : str | None = None
