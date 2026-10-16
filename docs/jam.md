# Jam: listening together

One room on the server; every member's app follows it. This page is the rule for all three: the server
(`backend/src/music_backend/services/jam.py`), the Mac (`mac/NoNonsense/Services/Jam.swift`) and Windows and Android
(`app/lib/core/jam.dart`). A change to how a jam behaves changes this page first, then the three, then the scenarios'
tests in all three (the list at the end).

The server is the source of truth. An app sends commands and plays what the room says; it decides nothing about the
room on its own. The only rules an app carries are the ones below that cannot run on the server (when to load, play,
pause or seek its own player), and they are the same in both apps.

## The room

| field | what it is |
|---|---|
| `code` | 8 characters (no l, 1, 0, o), what people type to join |
| `name` | optional; the apps show "<host>'s Jam" without one |
| `host_id` | the host: the room's clock (its position reports) and its Autoplay |
| `members` | in join order, which is the order the host's role passes on in |
| `current` | the song playing: an entry (`entry_id`, `listing`, `copies`, the song's other copies, best first) |
| `queue` | the entries after it |
| `is_playing`, `position_seconds` | the playhead (below) |
| `only_host_plays` | the host's device alone makes sound; the others follow silently |
| `only_host_controls` | members may only add songs to the end of the queue |

Rooms live in the server's memory. They are written to the database when the server stops and read back when it
starts (#31): a room that was playing plays on if the server is back within 60 s, else it waits, paused where it was.
A room closes when its last member leaves, or after 2 hours with no command and no connection.

**The playhead.** `position_seconds` plus the time since it was set while the room plays, never past the song's length;
still while paused. The server sends it in every `state` and `position` message, and each app counts on from the
moment the message arrived, the same way. The host's app reports its own place every 15 s while its player plays the
room's song (not while it loads or buffers: a loading song's place is 0, which pulled the room back), so the room
keeps time with the music rather than with the server's clock.

## Who may do what

| | any member | host only | members, with `only_host_controls` on |
|---|---|---|---|
| `add` (end of the queue) | yes | | yes |
| `add` with placement `next` or `now` | yes | | refused: the apps send it as `end` and say so |
| `play`, `pause`, `seek`, `skip`, `remove`, `move`, `jump` | yes | | refused: the apps do not send them and say so |
| `ended` | yes, near the song's end (see "The song ends") | yes, at any point | yes |
| `position` | | yes | |
| `only_host_plays`, `only_host_controls` | | yes | |
| give the host's role, remove a member, invite a friend | | yes | |

## Messages

HTTP (each needs a signed-in session):

| request | answer |
|---|---|
| `POST /jam` `{name?, song?}` | 201 and the room; you are its host. `song`: below |
| `POST /jam/join` `{code, song?}` | the room; 404 for a code no room has |
| `GET /jam/{id}` | the room; 404 when it is gone or you are not in it |
| `POST /jam/{id}/leave` | 204; the next member by join order becomes host; the last member closes the room |
| `POST /jam/{id}/host` `{member_id}` | 204; host only |
| `DELETE /jam/{id}/members/{member}` | 204; host only |
| `POST /jam/{id}/invites` `{username}` | 204; host only, friends only: a notification with the code |

`song` is the song on screen when you start or join: `{listing, copies, seconds, playing}`. A room with no song takes
it, from that second, playing or paused as it was; a room with a song ignores it. One request, so nothing can land
between the room opening and the song joining it.

The room's socket: `GET /ws/jam?ticket=…&room_id=…` (a ticket from `POST /ws-ticket`). From the server:

| message | when |
|---|---|
| `{"type":"state","data":{…}}` | on connecting, and after every change, to every member |
| `{"type":"position","seconds":…,"is_playing":true}` | the host's report, to every member but the host |
| `{"type":"error","detail":"…"}` | a command refused, to its sender alone |
| `{"type":"out","reason":"removed"\|"left"}` | the host removed you, or you left on another device; the socket then closes (4404) |
| `{"type":"pong"}` | the answer to `ping` |

From an app: the text `ping`, or a command `{"type": …}`: `play`, `pause`, `seek {seconds}`, `skip`,
`add {listings, copies, placement: end|next|now}`, `remove {entry_id}`, `move {entry_id, to_index}`, `jump {entry_id}`,
`ended {entry_id}`, `position {seconds}`, `only_host_plays {on}`, `only_host_controls {on}`. Each member may send 60
messages a minute. The server closes a socket that has said nothing for 30 s.

**Keeping the socket open.** An app sends `ping` when it has sent nothing for 25 s. The host's position reports, every
15 s while the room plays, keep its socket open on their own. No other timer.

## How an app follows the room

On every `state` and `position` message, in this order:

1. The room has no song: forget the entry loaded; pause the player if it plays.
2. A new entry (not the one loaded): when the player already plays that copy (the same listing), it keeps playing it,
   with no reload; otherwise it loads the entry (its listing first, its copies as fallbacks), playing or paused as the
   room is. The song starts at the playhead as it is when the song is ready, not as it was when the load began.
3. The same entry: play or pause to match the room. While the song loads, the load starts it or not.
4. Not loading, and more than 2.5 s from the playhead: seek to the playhead.

A member's player is muted while `only_host_plays` is on or the member turned Play here off; the host's never is.

## The song ends

Every app that plays the room's song to its end sends `ended` with the entry's id, once. The server moves the room on
(as Next) at the first one that counts, if that entry is still the current song, and ignores the rest:
- the host's counts whatever the playhead: the host's player is the room's clock, and when every copy is shorter than
  the listing says (a radio edit, YouTube Music copies of a JioSaavn listing), only the host's end comes, early;
- a member's counts only within 3 s of the song's end by the room's clock (or when its length is unknown), so a member
  whose copy is shorter cannot cut the song short for the others, and the room still moves on when the host's app is
  gone or hung (#28).

An end reported twice moves the room once. (Windows' player reports an end up to three times: sent as two skips, they
had the room jump over the next song, 17 Oct.)

A copy that will not play on one device is that device's alone: it tries the song's other copies, as outside a jam;
when none plays it says so and waits for the next song. The room is not skipped for everyone (a member's failing copy
did that until 12 Oct; the host's did until this spec).

## Autoplay

The host's app, with Autoplay on: when the room has one song or fewer queued, it asks the radio for songs like the last
one and adds them to the end, once per song asked about. One app asks, not every member's.

## Connections, restarts and the room going away

- A dropped socket is not a leave. The app connects again after 1 s, then twice as long each time, up to 30 s. After
  each drop it asks `GET /jam/{id}`: 404 means the room is gone or you are not in it any more, and the app leaves the
  jam and says so. A command while the socket is down is not sent (one sent late could pause the room long after the
  button was pressed); the app says it is not connected.
- The app remembers the room it is in. Opened again (quit, crashed, or closed by the system while in the background),
  it asks for that room: still a member, it is back in the jam and follows the room; 404, it says the jam ended.
  Signing out forgets it.
- One jam at a time: starting or joining another leaves the one you were in, on the server too.
- The server restarting does not end a jam (#31).

## What each control does

The same on the Mac, Windows and Android. "Member" is any member who is not the host.

| | in a jam |
|---|---|
| Play, Pause (bar, Now Playing, media keys, Space) | plays or pauses the room for everyone: what the button shows on this device. Play with the room empty starts it with the song on screen, from the start; with nothing on screen it says how to start |
| Next | the room's next song for everyone |
| Previous | the room's song from the start (a jam keeps no history) |
| Seek (the line, ← →) | the room's song, for everyone |
| Play on a song | that song now for everyone; the one playing is dropped |
| Play on a list, Shuffle | the list (up to 50 songs) for everyone, from that song |
| Play Next, Add to Queue | first in, or at the end of, the room's queue |
| Up Next | shows the room's queue; drag, remove and double-click act on the room |
| Start a jam with a song on screen | the room starts with it, where it is, playing or paused as it was; nothing restarts |
| Join a room with no song, with a song on screen | the same: the room takes your song |
| Join a room with a song | your song stops; the room's song loads and starts where the room is |
| Start or join another jam | you leave the one you were in |
| Leave | the song playing goes on, now yours; Up Next is empty until Autoplay fills it |
| The room's song is loading | its cover, title and the spinner at once; it starts where the room is when it is ready |
| A copy fails | the next copy, with the usual message; none: "Couldn't play “X”. The jam plays on." and this device waits for the next song |
| The song ends | the room moves on (above) |
| Members, with Only I control playback on | Play, Pause, Next, Previous and Seek say "The host controls this jam. You can add songs to the queue."; Play and Play Next add to the end |

What the user is told, once, wherever they are in the app:

| when | message |
|---|---|
| the host leaves | "“Kai” left the jam. “Sam” is the host now." (to Sam: "… You're the host now.") |
| the host hands over the role | "“Sam” is the host now." (to Sam: "You're the host now.") |
| the host removes you | "The host removed you from the jam." |
| you left on another device | "You left the jam on another device." |
| the room is gone, found on reconnecting or on opening the app | "You are no longer in the jam: it ended, or the host removed you." |
| the server restarts | nothing: the jam goes on |
| Play in an empty room with nothing on screen | "Nothing is playing in the jam. Play any song to start it." |
| a command while the socket is down | "Not connected to the jam right now. Trying again…" |
| Play, Play Next, Add to Queue | "Playing “X” in the jam", "“X” plays next in the jam", "Added “X” to the jam" (and ": the host controls this jam" when a member's Play became an add) |
| a command the server refused | its reason, as the server words it |

## Scenarios

Each is a test in all three: `backend/tests/test_jam.py` (the room), `app/test/jam_test.dart` (the Windows and Android
app against a fake server and socket) and the Mac's `NN_SELFTEST_JAM` (`mac/NoNonsense/Debug/JamSelfTest.swift`, on its
own test server on CI, with songs made on the runner: no internet).

1. Start with a song playing: the room's song is it, from where it was; the player keeps it, no reload, no jump.
2. Join with a song playing: an empty room takes it; a room with a song gives its own, at the room's playhead.
3. Play and pause, by the host and by a member: the room and every player follow.
4. Seek, by the host and by a member: every player moves to it; under 2.5 s apart nothing moves.
5. Next and Previous: the next song for everyone; Previous restarts the song.
6. The song ends: the host's `ended` moves the room on, and a member's near the end; a second, or a member's far from
   the end, does nothing.
7. The host leaves: the next member is host, and is told.
8. A slow load: the song starts at the playhead as it is when it is ready.
9. A failed copy: the next copy plays; when none does, the room is not skipped.
10. Reconnect: after a dropped socket the app follows the room as it is now.
11. The room gone: the app leaves the jam and says why; removed by the host: told at once.
12. Only I control playback: a member's controls are not sent and are explained; adds go to the end.

## Traffic at rest

A room playing a song, one host and one member, messages a minute (sent + received) before and after this spec:

| | host | member | timers a minute |
|---|---|---|---|
| Mac, before | 4 + 1.6 sent, 4 + 1.6 received | 2.4 sent, 2.4 + 4 received | 12 (a 5 s ticker) |
| Windows/Android, before | 4 + 2.4 sent, 4 + 2.4 received | 2.4 sent, 2.4 + 4 received | 6.4 (ping 25 s, report 15 s) |
| both, after | 4 sent, 0 received | 2.4 sent, 2.4 + 4 received | host 4, member 2.4 |

The host no longer pings while it reports, and no longer receives its own report back.
