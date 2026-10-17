-- Open jam rooms across a restart (#31). Rooms live in the server's memory; every deploy restarted it and ended every
-- jam. The server writes its rooms here when it stops and reads them back (and empties the table) when it starts.
CREATE TABLE jam_rooms (
    id       uuid        PRIMARY KEY,
    state    jsonb       NOT NULL,
    saved_at timestamptz NOT NULL DEFAULT now()
);
