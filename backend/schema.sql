-- Music library schema. Applied automatically when the server starts (every statement is
-- IF NOT EXISTS, so running it again is harmless). By hand:  psql music -f schema.sql
--
--   songs ──< listings      one song, many copies (JioSaavn, YouTube Music)
--     ├────< likes          liked at most once
--     └────< events         play / skip / finish, many per song
--
-- Single user for now: no user_id yet. Adding it is the first step of Jam/Blend.

CREATE TABLE IF NOT EXISTS songs (
    id               uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- identity: copied from the listing that created the song, NEVER updated,
    -- because resolve_song compares new listings against these (a fixed centre stops chaining).
    -- What the app DISPLAYS comes from the best linked listing, computed when read.
    title            text        NOT NULL,
    artists          text[]      NOT NULL,
    duration         integer     NOT NULL CHECK (duration > 0),
    -- normalise() lives in Python, so Postgres cannot index it; store its result instead
    normalised_title text        NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS songs_normalised_title_idx ON songs (normalised_title);


CREATE TABLE IF NOT EXISTS listings (
    -- the same id string could exist on two sources, so a listing is identified by BOTH columns
    source     text        NOT NULL CHECK (source IN ('jiosaavn', 'ytmusic')),
    source_id  text        NOT NULL,
    -- deleting a song deletes its listings too: a listing means nothing without its song
    song_id    uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    title      text        NOT NULL,
    artists    text[]      NOT NULL,
    album      text,
    duration   integer     NOT NULL,
    -- bigint, not integer: YouTube Music reports 3.6 billion plays, and integer stops at ~2.1 billion
    popularity bigint,
    image      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, source_id)
);

-- explicit version or not (MUS-19): NULL = not known yet (rows from before 7 Oct, filled in as they are seen again)
ALTER TABLE listings ADD COLUMN IF NOT EXISTS explicit boolean;

-- "all listings of song S" is a common question; without this it scans the whole table
CREATE INDEX IF NOT EXISTS listings_song_id_idx ON listings (song_id);


-- AUTH-1: accounts and sessions. A session is one signed-in device: sign-in makes one, sign-out deletes it, and
-- AUTH-4's device list is these rows. Sessions, not JWTs, so a device can be signed out at once (a JWT stays valid
-- until it expires).
CREATE TABLE IF NOT EXISTS users (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- 3 to 32 characters (decided 8 Oct; models.py USERNAME_MIN/MAX check it first, with a friendly message)
    username      text        NOT NULL CHECK (length(username) BETWEEN 3 AND 32),
    -- Argon2id's own string: the algorithm, its settings, the salt and the hash in one ("$argon2id$v=19$m=…").
    -- Never the password, in any form
    password_hash text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- one name regardless of capitals: a plain UNIQUE (username) would let "Alex" and "alex" be two accounts.
-- An index on an expression: the uniqueness is checked on lower(username), and sign-in looks names up the same way
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_idx ON users (lower(username));

CREATE TABLE IF NOT EXISTS sessions (
    -- the SHA-256 of the token (32 bytes), never the token: a leaked table lets no one in. SHA-256 is enough
    -- because the token is 256 random bits, impossible to guess; slow hashing is for passwords, which people choose
    token_hash   bytea       PRIMARY KEY,
    -- a deleted user's sessions go with them (as a deleted song takes its listings)
    user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_name  text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL
);

-- every request finds its session by token_hash (the primary key: indexed already); "my devices" and "sign out
-- everywhere" ask by user, which without this would read the whole table
CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON sessions (user_id);
-- the cleanup (auth.delete_expired_sessions, every few hours) reads only the expired rows through this, not the table
CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at);


CREATE TABLE IF NOT EXISTS likes (
    -- whose like (AUTH-3): a deleted user's likes go with them
    user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    song_id  uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    liked_at timestamptz NOT NULL DEFAULT now(),
    -- the key IS the "each person likes a song at most once" rule; led by user_id, it also serves "my likes"
    PRIMARY KEY (user_id, song_id)
);
-- Liked Songs: one user's likes, newest first, read in order from the index (no sort)
CREATE INDEX IF NOT EXISTS likes_user_liked_at_idx ON likes (user_id, liked_at DESC);


CREATE TABLE IF NOT EXISTS events (
    -- a song is played many times, so events need their own id; the database counts it up for us
    id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    song_id  uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    type     text        NOT NULL CHECK (type IN ('play', 'skip', 'finish')),
    -- seconds into the song when it happened: a skip at 12 s means something different from one at 180 s
    position integer     NOT NULL CHECK (position >= 0),
    at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS events_song_id_at_idx ON events (song_id, at);
-- Recently Played: one user's plays, newest first
CREATE INDEX IF NOT EXISTS events_user_id_at_idx ON events (user_id, at);


CREATE TABLE IF NOT EXISTS playlists (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- whose playlist (AUTH-3); its items follow it, so playlist_items needs no user_id of its own
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text        NOT NULL CHECK (name <> ''),
    -- path of an uploaded cover (MUS-2, cover image part 2); empty means "build a 2x2 grid from the first songs"
    image      text,
    position   text        COLLATE "C" NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- a name is taken per person: two people can each have "Gym"
    CONSTRAINT playlists_user_id_name_key UNIQUE (user_id, name)
);

-- "my playlists, in my order"
CREATE INDEX IF NOT EXISTS playlists_user_order_idx ON playlists (user_id, position);

CREATE TABLE IF NOT EXISTS playlist_items (
    -- its own id: the same song may appear twice in one playlist
    id          uuid        PRIMARY KEY DEFAULT uuidv7(),
    playlist_id uuid        NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    song_id     uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    -- fractional index (fractional-indexing library); "C" sorts by plain byte value, which the keys need
    position    text        COLLATE "C" NOT NULL,
    added_at    timestamptz NOT NULL DEFAULT now()
);

-- "one playlist's items, in order"
CREATE INDEX IF NOT EXISTS playlist_items_order_idx ON playlist_items (playlist_id, position);

-- sharing (AUTH-3). The owner is playlists.user_id; everyone else's access is a row here. Public: anyone signed in
-- can view it (with its id, e.g. from a link). Roles: viewer (see, play), editor (also add, remove, reorder songs);
-- only the owner renames, deletes, changes public, or invites
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS public boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS playlist_members (
    playlist_id uuid        NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role        text        NOT NULL CHECK (role IN ('viewer', 'editor')),
    added_at    timestamptz NOT NULL DEFAULT now(),
    -- one role per person per playlist; led by playlist_id, it also serves "who is in this playlist"
    PRIMARY KEY (playlist_id, user_id)
);
-- "playlists shared with me"
CREATE INDEX IF NOT EXISTS playlist_members_user_idx ON playlist_members (user_id);
-- who added each song (a shared playlist shows it); kept when they leave or are deleted: the song stays, unnamed
ALTER TABLE playlist_items ADD COLUMN IF NOT EXISTS added_by uuid REFERENCES users (id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS listing_urls (
    source     text        NOT NULL,
    source_id  text        NOT NULL,
    url        text        NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),   -- when this URL came from the source
    hit_at     timestamptz NOT NULL DEFAULT now(),   -- when it was last used: the trim drops the oldest first
    PRIMARY KEY (source, source_id)
);
-- CREATE TABLE IF NOT EXISTS skips an existing table entirely, so a column added later needs its own line
ALTER TABLE listing_urls ADD COLUMN IF NOT EXISTS hit_at timestamptz NOT NULL DEFAULT now();


-- MUS-12: lyrics replies, one per song as the app asks for it (LyricsCache in cache.py). Timed lyrics are kept
-- for good; plain and empty replies are asked again after LYRICS_RECHECK_DAYS (a source may add them later).
CREATE TABLE IF NOT EXISTS lyrics (
    song_name     text        NOT NULL,
    artist_name   text        NOT NULL,
    song_duration integer     NOT NULL,
    youtube_id    text        NOT NULL DEFAULT '',   -- '': asked without a YouTube copy (key columns cannot be NULL)
    reply         jsonb       NOT NULL,              -- the LyricsResponse, exactly as the app gets it
    fetched_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (song_name, artist_name, song_duration, youtube_id)
);


-- Genius notes (experimental, 8 Oct): one reply per song as the app asks for it (GeniusCache in cache.py), for every
-- user. Asked again after GENIUS_RECHECK_DAYS: people keep adding notes. Notes only: Genius's lyrics are never kept.
CREATE TABLE IF NOT EXISTS genius (
    song_name   text        NOT NULL,
    artist_name text        NOT NULL,
    reply       jsonb       NOT NULL,                -- the GeniusResponse, exactly as the app gets it
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (song_name, artist_name)
);
