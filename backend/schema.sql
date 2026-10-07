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


CREATE TABLE IF NOT EXISTS likes (
    -- song_id as the primary key IS the "liked at most once" rule, enforced by the database
    song_id  uuid        PRIMARY KEY REFERENCES songs (id) ON DELETE CASCADE,
    liked_at timestamptz NOT NULL DEFAULT now()
);


CREATE TABLE IF NOT EXISTS events (
    -- a song is played many times, so events need their own id; the database counts it up for us
    id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    song_id  uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    type     text        NOT NULL CHECK (type IN ('play', 'skip', 'finish')),
    -- seconds into the song when it happened: a skip at 12 s means something different from one at 180 s
    position integer     NOT NULL CHECK (position >= 0),
    at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS events_song_id_at_idx ON events (song_id, at);


CREATE TABLE IF NOT EXISTS playlists (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    name       text        UNIQUE NOT NULL CHECK (name <> ''),
    -- path of an uploaded cover (MUS-2, cover image part 2); empty means "build a 2x2 grid from the first songs"
    image      text,
    position   text        COLLATE "C" NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

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