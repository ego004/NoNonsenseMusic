// Jam: listening together. The rules, for this app, the Mac's Services/Jam.swift and the server: docs/jam.md.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'live_socket.dart';
import 'models.dart';

/// A person in a jam room.
@immutable
class JamMember {
  const JamMember(this.userId, this.username);
  final String userId, username;

  factory JamMember.fromJson(Map<String, dynamic> j) => JamMember(j['user_id'] as String, j['username'] as String);

  @override
  bool operator ==(Object other) => other is JamMember && other.userId == userId && other.username == username;
  @override
  int get hashCode => Object.hash(userId, username);
}

/// A song in the room, current or queued. [entryId] names the place in the queue: a song added twice is two entries.
@immutable
class JamEntry {
  const JamEntry(this.entryId, this.listing, [this.copies = const []]);
  final String entryId;
  final Listing listing;

  /// The song's other copies, best first (none from an app that sent none).
  final List<Listing> copies;

  factory JamEntry.fromJson(Map<String, dynamic> j) => JamEntry(
        j['entry_id'] as String,
        Listing.fromJson(j['listing'] as Map<String, dynamic>),
        [for (final c in (j['copies'] as List?) ?? const []) Listing.fromJson(c as Map<String, dynamic>)],
      );

  /// The song as this device's player plays it: [listing] first, then the other copies, which the player tries when
  /// [listing] will not play here (one member's copy failing left that member silent while the others heard it).
  Track get track => Track(listing, [listing, ...copies], choosingVersion: false);

  @override
  bool operator ==(Object other) => other is JamEntry && other.entryId == entryId;
  @override
  int get hashCode => entryId.hashCode;
}

/// A room as the server describes it (`JamState`), over HTTP and in the socket's `state` messages.
@immutable
class JamState {
  const JamState({
    required this.roomId,
    required this.code,
    required this.name,
    required this.hostId,
    required this.members,
    required this.current,
    required this.isPlaying,
    required this.positionSeconds,
    required this.queue,
    this.onlyHostPlays = false,
    this.onlyHostControls = false,
  });

  final String roomId, code, hostId;

  /// The host chose to play the room on their device alone: every other member's player follows without sound.
  final bool onlyHostPlays;

  /// The host chose to control the room alone: members may only add songs to the end of the queue.
  final bool onlyHostControls;
  final String? name;
  final List<JamMember> members;
  final JamEntry? current;
  final bool isPlaying;

  /// Where the current song is, as of the message.
  final double positionSeconds;
  final List<JamEntry> queue;

  factory JamState.fromJson(Map<String, dynamic> j) => JamState(
        roomId: j['room_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String?,
        hostId: j['host_id'] as String,
        members: [for (final m in j['members'] as List) JamMember.fromJson(m as Map<String, dynamic>)],
        current: j['current'] == null ? null : JamEntry.fromJson(j['current'] as Map<String, dynamic>),
        isPlaying: j['is_playing'] as bool? ?? false,
        positionSeconds: (j['position_seconds'] as num?)?.toDouble() ?? 0,
        queue: [for (final e in (j['queue'] as List?) ?? const []) JamEntry.fromJson(e as Map<String, dynamic>)],
        onlyHostPlays: j['only_host_plays'] as bool? ?? false,
        onlyHostControls: j['only_host_controls'] as bool? ?? false,
      );

  /// The name of the member with [userId], or "Someone" when they are not in the member list.
  String nameOf(String userId) => members.where((m) => m.userId == userId).firstOrNull?.username ?? 'Someone';

  /// The host's name, or "Someone" when the host is not in the member list.
  String get hostName => nameOf(hostId);

  /// What the room is called: the name it was given, else the host's name and "'s Jam".
  String get title => name ?? "$hostName's Jam";

  @override
  bool operator ==(Object other) =>
      other is JamState &&
      other.roomId == roomId &&
      other.code == code &&
      other.name == name &&
      other.hostId == hostId &&
      other.current == current &&
      other.isPlaying == isPlaying &&
      other.positionSeconds == positionSeconds &&
      other.onlyHostPlays == onlyHostPlays &&
      other.onlyHostControls == onlyHostControls &&
      listEquals(other.members, members) &&
      listEquals(other.queue, queue);
  @override
  int get hashCode => Object.hash(roomId, code, name, hostId, current, isPlaying, positionSeconds, onlyHostPlays, onlyHostControls);
}

/// One control message for the room (`JamCommand` on the server). Only the fields a command uses are sent.
@immutable
class JamCommand {
  const JamCommand._(this.type,
      {this.seconds, this.listings, this.copies, this.entryId, this.placement, this.toIndex, this.on});

  const JamCommand.play() : this._('play');
  const JamCommand.pause() : this._('pause');
  const JamCommand.skip() : this._('skip');
  const JamCommand.seek(double seconds) : this._('seek', seconds: seconds);

  /// The host's playhead, sent every 15 s while its player plays the room's song.
  const JamCommand.position(double seconds) : this._('position', seconds: seconds);

  /// The room's song [entryId] played to its end on this device: the server moves the room on at the first one.
  const JamCommand.ended(String entryId) : this._('ended', entryId: entryId);

  /// [placement]: 'end' (Add to Queue), 'next' (Play Next) or 'now' (Play: at once, the song playing dropped).
  /// [copies]: each song's other copies, in the order of [listings], for members whose device cannot play the first.
  const JamCommand.add(List<Listing> listings, {String placement = 'end', List<List<Listing>>? copies})
      : this._('add', listings: listings, copies: copies, placement: placement);

  /// The host plays the room on their device alone (true), or every member's device plays it (false, the default).
  const JamCommand.onlyHostPlays(bool on) : this._('only_host_plays', on: on);

  /// The host controls the room alone (true): members may only add songs to the end of the queue; or everyone does.
  const JamCommand.onlyHostControls(bool on) : this._('only_host_controls', on: on);
  const JamCommand.remove(String entryId) : this._('remove', entryId: entryId);
  const JamCommand.jump(String entryId) : this._('jump', entryId: entryId);
  const JamCommand.move(String entryId, int toIndex) : this._('move', entryId: entryId, toIndex: toIndex);

  final String type;
  final double? seconds;
  final List<Listing>? listings;
  final List<List<Listing>>? copies;
  final String? entryId;
  final String? placement;
  final int? toIndex;
  final bool? on;

  Map<String, dynamic> toJson() => {
        'type': type,
        'seconds': ?seconds,
        if (listings != null) 'listings': [for (final l in listings!) l.toJson()],
        if (copies != null) 'copies': [for (final c in copies!) [for (final l in c) l.toJson()]],
        'entry_id': ?entryId,
        'placement': ?placement,
        'to_index': ?toIndex,
        'on': ?on,
      };

  /// At most this many other copies go with a song (the server's MAX_JAM_COPIES).
  static const maxCopies = 4;

  /// [t]'s copies other than the one that plays, best first, as [JamCommand.add] sends them.
  static List<Listing> otherCopies(Track t, {Listing? playing}) {
    final first = playing ?? t.best;
    return t.listings.where((l) => l.key != first.key).take(maxCopies).toList();
  }

  String encode() => jsonEncode(toJson());
}

/// The song on screen when the user starts or joins a jam: a room with no song takes it, from [seconds], playing or
/// paused as it was (docs/jam.md). It goes with the request, so nothing lands between the room opening and the song
/// joining it.
@immutable
class JamSong {
  const JamSong(this.listing, this.seconds, {required this.playing, this.copies = const []});

  /// The copy that plays.
  final Listing listing;
  final double seconds;
  final bool playing;

  /// The song's other copies, so every member has one to fall back on.
  final List<Listing> copies;

  Map<String, dynamic> toJson() =>
      {'listing': listing.toJson(), 'copies': [for (final c in copies) c.toJson()], 'seconds': seconds, 'playing': playing};
}

/// What the jam needs from the player. The player implements it; tests use a fake.
abstract interface class JamPlayer {
  /// The jam this player takes its commands from, or null when it plays for itself.
  JamSession? get jam;
  set jam(JamSession? session);

  bool get isPlaying;

  /// A song is being loaded: its position says nothing yet.
  bool get jamLoading;

  /// Where the song is now, in seconds.
  double get position;

  /// The copy loaded now (its listing's key), or null.
  String? get jamPlayingKey;

  /// The song on screen, with the copy that plays and where it is; null when the player has none.
  JamSong? get jamSong;

  /// Tells the user something about the room ("Added to the jam", the server's refusal).
  void jamSay(String text);

  /// Loads the room's current song at [at] seconds, playing or paused as the room is.
  void jamLoad(Track track, double at, {required bool playing});

  /// Plays or pauses to match the room, without telling the room.
  void jamFollowPlaying(bool playing);

  /// Moves to the room's playhead, without telling the room.
  void jamFollowSeek(double seconds);

  /// A member whose device follows without sound (Play here off, or the host playing the room alone): the room's song
  /// follows along silently, apart from the user's own volume.
  void jamSetSilent(bool silent);

  /// Songs like [seed] for the room's Autoplay, none when Autoplay is off (Settings › Playback).
  Future<List<Track>> jamRadio(Listing seed, List<Listing> exclude);
}

/// What a member is told when the room turns them away: the server says only that it has no such room for them.
const jamEndedNotice = 'You are no longer in the jam: it ended, or the host removed you.';

/// A jam: listening together. Every member's device plays the room's song in step and every member controls it; the
/// host may choose to play the room on their device alone ([JamState.onlyHostPlays]) or to control it alone
/// ([JamState.onlyHostControls]: members then only add songs). The rules are docs/jam.md's, as on the Mac.
///
/// While in one, the room decides what plays: the player's play/pause, next, previous and seek become the room's
/// commands, playing a song adds it to the room, and every member's player follows the room's state as it arrives. One
/// WebSocket carries the commands and the state; the host's app also reports its playhead every 15 s while the room
/// plays, and that report keeps its socket open, so it sends no ping meanwhile. An idle jam costs no CPU.
class JamSession extends ChangeNotifier {
  JamSession({this._connect, this.reportEvery = const Duration(seconds: 15)});

  /// The app's one jam session; the screens read this unless a test gives them another.
  static final shared = JamSession();

  final SocketConnector? _connect;
  final Duration reportEvery;

  /// More than this far from the room's playhead, a player moves to it (docs/jam.md: the same in every app).
  static const seekBeyond = 2.5;

  JamState? state;

  /// The server's last refusal ("Queue is full (200).") or a connection problem, shown in the jam panel.
  String? problem;

  /// Why this device is out of a jam it did not leave itself, until the shell has said it once (#31). It used to leave
  /// without a word, which looked random.
  String? ended;

  JamPlayer? player;

  /// The signed-in user's id.
  String? me;

  LiveSocket? _socket;
  Timer? _reporter;

  /// The entry this device's player last loaded: a state with another entry loads that one.
  String? _loadedEntry;

  /// The room's last known place: its position, whether it played, and when that arrived.
  ({double seconds, bool playing, DateTime at}) _mark = (seconds: 0, playing: false, at: DateTime.now());

  bool get inJam => state != null;
  bool get isHost => state != null && state!.hostId == me;

  // MARK: joining and leaving

  /// Starts a jam. Returns null when it worked, else why not. The song on screen comes in with its place: the room
  /// starts with it and the player does not restart it.
  Future<String?> start({String? name}) {
    final trimmed = name?.trim();
    return _enter(() => Api.sendJson('POST', 'jam', {
          'name': trimmed == null || trimmed.isEmpty ? null : trimmed,
          'song': ?player?.jamSong?.toJson(),
        }));
  }

  /// Joins the jam with [code]. Returns null when it worked, else why not. A room with no song takes the one on
  /// screen; a room with a song plays its own here.
  Future<String?> join(String code) {
    final typed = code.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (typed.isEmpty) return Future.value("Enter the jam's code.");
    return _enter(() => Api.sendJson('POST', 'jam/join', {'code': typed, 'song': ?player?.jamSong?.toJson()}));
  }

  Future<String?> _enter(Future<dynamic> Function() request) async {
    final JamState room;
    try {
      room = JamState.fromJson(await request() as Map<String, dynamic>);
    } catch (e) {
      return e is ApiError ? e.toString() : "Can't connect to the server.";
    }
    final before = state?.roomId;
    _open(room);
    // one jam at a time: the one this device was in is left on the server too, not kept with it as a silent member
    if (before != null && before != room.roomId) Api.sendJson('POST', 'jam/$before/leave').ignore();
    return null;
  }

  /// The jam this device was in when the app last ran (docs/jam.md): back in it when the room still has this user,
  /// told otherwise. An app closed by the system in the background, or quit, forgot its jam while the room still
  /// listed it as a member. Called once signed in.
  Future<void> resume() async {
    final id = await _remembered();
    if (id == null || inJam) return;
    try {
      _open(JamState.fromJson(await Api.getJson('jam/$id') as Map<String, dynamic>));
    } on ApiError catch (e) {
      if (e.status != 404) return;
      _remember(null);
      ended = jamEndedNotice;
      notifyListeners();
    } catch (_) {} // offline: asked again at the next launch
  }

  void _open(JamState room) {
    leaveLocally();
    ended = null;
    _remember(room.roomId);
    _socket = LiveSocket(
      path: 'ws/jam',
      query: {'room_id': room.roomId},
      onMessage: handle,
      onDropped: () => _checkRoom(room.roomId),
      connect: _connect,
      longestWait: const Duration(seconds: 30),
    )..start();
    _apply(room);
  }

  /// Leaves the room on the server and here.
  Future<void> leave() async {
    final room = state?.roomId;
    if (room == null) return;
    leaveLocally();
    try {
      await Api.sendJson('POST', 'jam/$room/leave');
    } catch (_) {}
  }

  /// Signed out, or another jam: the socket closes and the player is the user's again (not stopped: the song plays
  /// on).
  void leaveLocally() {
    _socket?.stop();
    _socket = null;
    _reporter?.cancel();
    _reporter = null;
    final was = state;
    state = null;
    problem = null;
    _loadedEntry = _radioSeed = null;
    _playHere = true;
    player?.jamSetSilent(false);
    player?.jam = null;
    _remember(null); // signed out too: the next account must not come back into this one's jam
    if (was != null) notifyListeners();
  }

  static const _roomKey = 'jamRoom';

  /// Keeps (or with null forgets) the room this device is in, for [resume]. One write after another: a leave and the
  /// next room's write, side by side, could land in either order.
  void _remember(String? room) {
    _saved = _saved.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await (room == null ? prefs.remove(_roomKey) : prefs.setString(_roomKey, room));
    }).catchError((Object _) {});
  }

  Future<void> _saved = Future.value();

  Future<String?> _remembered() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_roomKey);
    } catch (_) {
      return null;
    }
  }

  /// The current host chooses which member's device plays. A member cannot take over somebody else's speakers.
  Future<void> giveSpeakers(JamMember member) =>
      _hostCall('POST', 'host', {'member_id': member.userId});

  /// The host removes a member from the room.
  Future<void> removeMember(JamMember member) => _hostCall('DELETE', 'members/${member.userId}');

  Future<void> _hostCall(String method, String tail, [Object body = const {}]) async {
    final room = state;
    if (room == null || !isHost) return;
    try {
      await Api.sendJson(method, 'jam/${room.roomId}/$tail', body);
    } catch (e) {
      problem = e is ApiError ? e.toString() : "Can't connect to the server.";
      notifyListeners();
    }
  }

  /// The host invites a friend: they get a notification with the jam's code. Returns null when it went out, else why
  /// not.
  Future<String?> invite(String username) async {
    final room = state?.roomId;
    if (room == null) return null;
    try {
      await Api.sendJson('POST', 'jam/$room/invites', {'username': username});
      return null;
    } catch (e) {
      return e is ApiError ? e.toString() : "Can't connect to the server.";
    }
  }

  // MARK: commands (the player calls these while in a jam)

  /// Play ([play] true) or pause the room: what the button pressed shows, so a device still loading the room's song
  /// (its button on Play) cannot pause the room for everyone. Play with the room empty starts it with the song on
  /// screen, from the start; without one the user is told how to start.
  void setPlaying(bool play) {
    final room = state;
    if (room == null) return;
    if (play && room.current == null) {
      final song = player?.jamSong;
      if (song == null) return player?.jamSay('Nothing is playing in the jam. Play any song to start it.');
      return add([Track(song.listing, [song.listing, ...song.copies], choosingVersion: false)], placement: 'now');
    }
    if (!_locked()) _send(play ? const JamCommand.play() : const JamCommand.pause());
  }

  void skip() {
    if (!_locked()) _send(const JamCommand.skip());
  }

  void seek(double seconds) {
    if (!_locked()) _send(JamCommand.seek(seconds < 0 ? 0 : seconds));
  }

  /// Whether this member may control the room: everyone may, unless the host chose to control it alone.
  bool get canControl => isHost || state?.onlyHostControls != true;

  /// A control this member may not use while the host controls the room: the user is told, and nothing is sent (the
  /// server would refuse it).
  bool _locked() {
    if (canControl) return false;
    player?.jamSay(lockedNotice);
    return true;
  }

  static const lockedNotice = 'The host controls this jam. You can add songs to the queue.';

  /// Play ('now'), Play Next ('next') and Add to Queue ('end') in a jam: one command each, placed by the server, and
  /// the user told what happened. While the host controls the room, a member's Play and Play Next add to the end.
  void add(List<Track> tracks, {String placement = 'end'}) {
    if (tracks.isEmpty) return;
    final asked = placement;
    if (placement != 'end' && !canControl) placement = 'end';
    if (!_send(JamCommand.add([for (final t in tracks) t.best],
        placement: placement, copies: [for (final t in tracks) JamCommand.otherCopies(t)]))) {
      return;
    }
    final what = tracks.length == 1 ? '“${tracks.first.title}”' : '${tracks.length} songs';
    final notice = switch (placement) {
      'now' => 'Playing $what in the jam',
      'next' => '$what plays next in the jam',
      _ => 'Added $what to the jam',
    };
    player?.jamSay(placement == asked ? notice : '$notice: the host controls this jam');
  }

  /// The host plays the room on this device alone (on), or on every member's device (off, the default).
  void setOnlyHostPlays(bool on) {
    if (isHost) _send(JamCommand.onlyHostPlays(on));
  }

  /// The host controls the room alone (on), or every member does (off, the default).
  void setOnlyHostControls(bool on) {
    if (isHost) _send(JamCommand.onlyHostControls(on));
  }

  void remove(JamEntry entry) {
    if (!_locked()) _send(JamCommand.remove(entry.entryId));
  }

  void jump(JamEntry entry) {
    if (!_locked()) _send(JamCommand.jump(entry.entryId));
  }

  /// A drag in the room's Up Next: the move goes to the room, so everyone sees it.
  void move(JamEntry entry, int toIndex) {
    if (!_locked()) _send(JamCommand.move(entry.entryId, toIndex));
  }

  /// The room's song played to its end on this device. Every member's app says so; the server moves the room on at the
  /// host's, or at a member's near the end (docs/jam.md), so the room no longer waits for the host's app. A copy that
  /// would not play is not an end: it is this device's alone.
  void songEnded() {
    final entry = _loadedEntry;
    // once per entry: Windows' player reports a song's end up to three times (17 Oct); as two skips, they had the room
    // jump over the next song
    if (entry == null || entry == _endedEntry) return;
    _endedEntry = entry;
    _send(JamCommand.ended(entry), quietly: true);
  }

  String? _endedEntry;

  /// Sends [command] over the room's socket. While it is not connected (just joined, or connecting again) nothing is
  /// sent and the user is told: a command sent late could pause the room long after the button was pressed.
  bool _send(JamCommand command, {bool quietly = false}) {
    if (_socket?.send(command.encode()) != true) {
      if (!quietly) player?.jamSay(notConnected);
      return false;
    }
    if (problem != null) {
      problem = null;
      notifyListeners();
    }
    return true;
  }

  static const notConnected = 'Not connected to the jam right now. Trying again…';

  // MARK: the room's state

  /// Off: this device follows the room without sound (friends in one room would hear an echo). The host always plays.
  bool get playHere => _playHere;
  bool _playHere = true;
  set playHere(bool on) {
    _playHere = on;
    final room = state;
    if (room != null) player?.jamSetSilent(_silentHere(room));
    notifyListeners();
  }

  /// Whether this device follows [room] without sound: a member's, when the host plays the room alone or the member
  /// turned Play here off. The host's always plays.
  bool _silentHere(JamState room) => room.hostId != me && (room.onlyHostPlays || !_playHere);

  /// Where the room's song is now: the last position the room gave, plus the time since while it plays (the server's
  /// playhead). A song loaded for the room starts here once it is ready: the position from when its state arrived was
  /// as old as the load was long, and a member started that far behind until the host's next report, 15 s later (#28).
  double? get playhead {
    if (state?.current == null) return null;
    final since = _mark.playing ? DateTime.now().difference(_mark.at).inMilliseconds / 1000 : 0;
    return _mark.seconds + since;
  }

  /// A new state: kept, told, and this device's player made to match it.
  void _apply(JamState room) {
    final was = state;
    _mark = (seconds: room.positionSeconds, playing: room.isPlaying, at: DateTime.now());
    if (room != state) {
      state = room;
      notifyListeners();
    }
    if (was != null && was.hostId != room.hostId) _sayNewHost(was, room);
    // the host's app reports its place while the room plays, and only then: no timer for anyone else
    final reporting = room.hostId == me && room.isPlaying && room.current != null;
    if (reporting != (_reporter != null)) {
      _reporter?.cancel();
      _reporter = reporting ? Timer.periodic(reportEvery, (_) => _report()) : null;
    }
    _follow();
    _refill(room);
  }

  void _report() {
    final p = player;
    // not while the song loads or has not started here: a loading song's place is 0, and it pulled the room back
    if (p != null && p.isPlaying && !p.jamLoading) _socket?.send(JamCommand.position(p.position).encode());
  }

  /// "“Kai” left the jam. You're the host now.": the host left, or handed the role on (docs/jam.md).
  void _sayNewHost(JamState was, JamState room) {
    final left = !room.members.any((m) => m.userId == was.hostId);
    final now = room.hostId == me ? "You're the host now." : '“${room.hostName}” is the host now.';
    player?.jamSay(left ? '“${was.hostName}” left the jam. $now' : now);
  }

  /// Makes this device's player match the room: docs/jam.md, "How an app follows the room", step by step.
  void _follow() {
    final room = state, p = player;
    if (room == null || p == null) return;
    p.jam = this;
    p.jamSetSilent(_silentHere(room));
    final entry = room.current;
    if (entry == null) {
      _loadedEntry = null;
      if (p.isPlaying) p.jamFollowPlaying(false);
      return;
    }
    final at = playhead!;
    if (entry.entryId != _loadedEntry) {
      _loadedEntry = entry.entryId;
      // the room's song is the copy already playing here (it came in with a start or a join): kept, not loaded again
      if (entry.listing.key != p.jamPlayingKey) return p.jamLoad(entry.track, at, playing: room.isPlaying);
    }
    if (room.isPlaying != p.isPlaying) p.jamFollowPlaying(room.isPlaying);
    if (!p.jamLoading && (p.position - at).abs() > seekBeyond) p.jamFollowSeek(at);
  }

  String? _radioSeed;
  bool _radioAsking = false;

  /// The room's Autoplay, run by the host's app alone (one app asks, not every member's): with one song or fewer
  /// queued, songs like the last one are added at the end, once per song asked about, and only after an answer, so a
  /// failure is asked again at the next change. As on the Mac; a room hosted here used to run dry.
  Future<void> _refill(JamState room) async {
    final last = (room.queue.lastOrNull ?? room.current)?.listing;
    final p = player;
    if (room.hostId != me || p == null || room.queue.length > 1 || _radioAsking || last == null || _radioSeed == last.key) {
      return;
    }
    _radioAsking = true;
    try {
      final songs = await p.jamRadio(last, [?room.current?.listing, for (final e in room.queue) e.listing]);
      if (songs.isEmpty || state?.roomId != room.roomId) return;
      _radioSeed = last.key;
      _send(JamCommand.add([for (final t in songs) t.best], copies: [for (final t in songs) JamCommand.otherCopies(t)]),
          quietly: true);
    } catch (_) {
      // asked again at the room's next change
    } finally {
      _radioAsking = false;
    }
  }

  /// When the socket drops: GET /jam/{id}. A 404 means the room is gone (its last member left, it sat idle, or the
  /// server lost it) or this user is no longer in it (left on another device, or removed), so the user is out of the
  /// jam here too, and is told.
  Future<void> _checkRoom(String room) async {
    try {
      await Api.getJson('jam/$room');
    } on ApiError catch (e) {
      if (e.status == 404 && state?.roomId == room) _out(jamEndedNotice);
    } catch (_) {}
  }

  /// Out of the jam without leaving it here: said once, wherever the user is (the shell shows [ended]).
  void _out(String why) {
    ended = why;
    leaveLocally();
  }

  /// Acts on one message from the room's socket: `state` replaces the room, `position` (the host's playhead, every
  /// 15 s while it plays) moves a player that has drifted to it, `error` shows the server's refusal, `out` says why
  /// this device is out. "pong" is ignored.
  @visibleForTesting
  void handle(String text) {
    final Object? message;
    try {
      message = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (message is! Map<String, dynamic>) return;
    switch (message['type']) {
      case 'state':
        final data = message['data'];
        if (data is Map<String, dynamic>) _apply(JamState.fromJson(data));
      case 'position':
        // Without this a member caught up only when the room's state next changed: one that started late (a song still
        // arriving on a slow connection) stayed behind, or silent at 0:00, while the others played
        final seconds = message['seconds'];
        if (state != null && seconds is num) {
          _mark = (seconds: seconds.toDouble(), playing: message['is_playing'] as bool? ?? true, at: DateTime.now());
          _follow();
        }
      case 'error':
        problem = message['detail'] as String?;
        if (problem != null) player?.jamSay(problem!);
        notifyListeners();
      case 'out':
        _out(message['reason'] == 'left' ? 'You left the jam on another device.' : 'The host removed you from the jam.');
    }
  }

  @override
  void dispose() {
    _socket?.stop();
    _reporter?.cancel();
    super.dispose();
  }
}
