from datetime import datetime
from typing import Any, Literal
from uuid import UUID
from pydantic import BaseModel, Field

# The one list of source IDs, used by every model, SOURCES in main.py, and the /play URL.
# Lowercase, no spaces: they appear in URLs (/play/ytmusic/...) and must never drift between files.
# Display names like "YouTube Music" belong to a UI, not here.
SourceName = Literal["jiosaavn", "ytmusic"]

class Listing(BaseModel):
    source : SourceName
    id : str
    title : str
    artists : list[str]
    album: str | None
    duration: int
    popularity : int | None
    # artwork URL, already rewritten to a large size by the source adapter
    image : str | None = None
    # the explicit version (JioSaavn's explicit_content, YouTube Music's E badge); None: not known (older rows)
    explicit : bool | None = None

class BaseSong(BaseModel):
    title: str
    artists: list[str] | None
    duration: int
    best: Listing
    listings: list[Listing]

class LibrarySong(BaseSong):
    """A stored song as the app shows it: identity from the database, display from its best listing."""
    id : UUID
    liked : bool
    at : datetime | None = None   # liked_at for /liked, last played for /recent

class Song(BaseSong):
    score: float

class SearchSourceInfo(BaseModel):
    source : SourceName
    healthy : bool
    num_results : int
    ms : int
    error : str | None = Field(default = None, exclude_if = lambda error: error is None)


class SearchResponse(BaseModel):
    query : str
    sources : list[SearchSourceInfo]
    songs : list[Song]


EventType = Literal["play", "skip", "finish"]


class ListingsRequest(BaseModel):
    # IDs are assigned lazily: the app sends the song's listings, the server finds or creates the song
    listings : list[Listing] = Field(min_length = 1)


class EventRequest(ListingsRequest):
    type : EventType
    position : int = Field(ge = 0)


class SongRef(BaseModel):
    song_id : UUID

class PlaylistRequest(BaseModel):
    name : str = Field(min_length=1)

# AUTH-1: the limits, in one place. schema.sql's CHECK on users.username repeats the 3 and 32 as a last guard
USERNAME_MIN, USERNAME_MAX = 3, 32
PASSWORD_MIN = 8
# a maximum too: Argon2 hashes any length, slowly, so a 10 MB "password" per sign-up would burn the server's CPU.
# 64 is the least NIST asks a service to allow
PASSWORD_MAX = 64
DEVICE_NAME_MAX = 64

class PlaylistUpdate(BaseModel):
    """PATCH /playlists/{id}: change the name, the public flag, or both (the owner only). Missing = unchanged."""
    name : str | None = Field(default=None, min_length=1)
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
    # sharing (AUTH-3): anyone signed in can view a public one; your role says what the app may offer you
    # (owner: everything; editor: add, remove, reorder songs; viewer: look and play)
    public : bool = False
    role : Literal["owner", "editor", "viewer"] = "owner"

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
    source_id : str

class PrefetchRequest(BaseModel):
    # the app sends 5 to 10; the maximum stops one request from queueing thousands of lookups
    listings : list[PrefetchListing] = Field(min_length = 1, max_length = 50)

class LyricsRequest(BaseModel):
    song_name : str
    artist_name : str                       # LRCLIB answers 400 without one
    song_duration : int                     # seconds
    youtube_id : str | None = None          # the song's ytmusic listing, if any (even when JioSaavn's copy plays)

class LyricLine(BaseModel):
    start_ms : int | None                   # None: plain lyrics, no times. A line ends where the next one starts
    text : str

class LyricsResponse(BaseModel):
    lyrics_source : Literal["lrclib", "ytmusic"] | None   # None: nobody had lyrics (lines is [])
    synced : bool
    lines : list[LyricLine]


class GeniusRequest(BaseModel):
    song_name : str
    artist_name : str

class GeniusNote(BaseModel):
    fragment : str                          # the words of the song it is about, as Genius quotes them
    text : str                              # the note, plain text
    verified : bool = False                 # written or confirmed by the artist

class GeniusAbout(BaseModel):
    description : str | None
    produced_by : list[str]
    samples : list[str]                     # "Song by Someone"

class GeniusResponse(BaseModel):
    """Always 200 when Genius was asked: no such song there is `url` None and no notes."""
    url : str | None                        # the song's page on Genius: the notes are credited to it
    notes : list[GeniusNote]
    about : GeniusAbout | None


class SignUpRequest(BaseModel):
    username : str = Field(min_length=USERNAME_MIN, max_length=USERNAME_MAX)
    password : str = Field(min_length=PASSWORD_MIN, max_length=PASSWORD_MAX)
    device_name : str = Field(default="Unknown Device", max_length=DEVICE_NAME_MAX)

class SignInRequest(BaseModel):
    """Its own rules, not sign-up's: only the maximums. Raise PASSWORD_MIN later and an older account's shorter password
    must still reach the password check, not stop at a 422."""
    username : str = Field(max_length=USERNAME_MAX)
    password : str = Field(max_length=PASSWORD_MAX)
    device_name : str = Field(default="Unknown Device", max_length=DEVICE_NAME_MAX)

class User(BaseModel):
    """Who is signed in: what current_user gives routes and /auth/me answers. Only these fields ever reach a reply,
    so a password hash cannot leak through a careless `return user`."""
    id : UUID
    username : str

class DeviceNameRequest(BaseModel):
    """PATCH /auth/me/device: what this device is called in your list of devices."""
    device_name : str = Field(min_length=1, max_length=DEVICE_NAME_MAX)

class Session(BaseModel):
    """The reply to sign-up, sign-in and a recovery: the only time the token itself is sent. `recovery_codes`: at
    sign-up only, the one time they are shown."""
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
    """One person in a friends list or a request list: who they are, and when the relationship began (or was asked for)."""
    user_id: UUID
    username: str
    since: datetime                            # friends_since for friends, created_at for requests


class FriendRequests(BaseModel):
    """GET /friends/requests: the requests waiting on you, and the ones you are waiting on."""
    incoming: list[FriendUser]
    outgoing: list[FriendUser]


class FriendRequest(BaseModel):
    """POST /friends/request: ask someone to be your friend. Just their username."""
    username: str = Field(max_length=USERNAME_MAX)


class RespondRequest(BaseModel):
    """POST /friends/respond: accept or decline someone's request. The username identifies which one."""
    username: str = Field(max_length=USERNAME_MAX)
    action: Literal["accept", "decline"]


# ---------- notifications (FRIENDS-1 Phase 2) ----------

NotificationType = Literal["friend_request", "friend_accepted", "playlist_invite"]


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


# one place mapping type -> payload model: services/notifications.py validates before INSERT,
# so a typo in a caller's dict never reaches the database
NOTIFICATION_PAYLOAD_MODELS: dict[str, type[BaseModel]] = {
    "friend_request": FriendRequestPayload,
    "friend_accepted": FriendAcceptedPayload,
    "playlist_invite": PlaylistInvitePayload,
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
    """POST /ws-ticket reply: a single-use short-lived token for the WebSocket handshake.
    The JWT itself never appears in a URL query string (access logs, proxies, history)."""
    ticket: str
    expires_in: int                  # seconds (30)


class MarkReadResponse(BaseModel):
    unread_count: int