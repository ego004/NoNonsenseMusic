-- Search lists the songs in your library that match first (#26). words: a copy's title and artists as search compares
-- them (matching.words_of: normalised, each word once), written with them; the server gives the copies stored before
-- this theirs at start (library.load_words). The GIN index finds the copies that hold a word without reading the rest:
-- a search asks it for the words it may mean, then keeps the user's own songs (library.matching_songs). fastupdate off:
-- a new copy goes into the index at once, not into a pending list every search would then read through (7 ms a search
-- after the first start's fill, against 0.02 ms once it was merged; 18 Oct). Copies are stored far less often than
-- searches run.
ALTER TABLE listings ADD COLUMN words text[];
CREATE INDEX listings_words_idx ON listings USING gin (words) WITH (fastupdate = off);
