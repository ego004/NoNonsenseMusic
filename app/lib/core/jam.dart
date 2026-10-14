// Jam: listening together. The rules match the Mac app's Services/Jam.swift and the jam hooks of its Player.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  /// This room with the playhead the host last reported (a `position` push), the rest unchanged.
  JamState withPosition(double seconds, {required bool playing}) => JamState(
      roomId: roomId,
      code: code,
      name: name,
      hostId: hostId,
      members: members,
      current: current,
      isPlaying: playing,
      positionSeconds: seconds,
      queue: queue,
      onlyHostPlays: onlyHostPlays,
      onlyHostControls: onlyHostControls);

  /// The host's name, or "Someone" when the host is not in the member list.
  String get hostName => members.where((m) => m.userId == hostId).firstOrNull?.username ?? 'Someone';

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

  /// The host's playhead, sent every 15 s while its song plays.
  const JamCommand.position(double seconds) : this._('position', seconds: seconds);
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

/// The song a player is playing when a jam starts, so the room can take it over.
@immutable
class JamCarry {
  const JamCarry(this.listing, this.position, [this.copies = const []]);

  /// The copy that plays.
  final Listing listing;
  final double position;

  /// The song's other copies, sent with it so every member has one to fall back on.
  final List<Listing> copies;
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

  /// The song playing right now, or null when nothing plays.
  JamCarry? get jamCarry;

  /// The song on screen, playing or not; null when the player has none.
  Track? get jamOnScreen;

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
}

/// What the host's player does when a new room state arrives. All fields are empty when nothing needs doing.
@immutable
class JamPlan {
  const JamPlan({this.load, this.playing, this.seek, this.loadedEntry});

  /// A song to load (the room moved on); when set, [playing] and [seek] are not used.
  final JamEntry? load;

  /// Play (true) or pause (false) to match the room.
  final bool? playing;

  /// Seek to this many seconds.
  final double? seek;

  /// The entry this player now has loaded, null when it follows nothing.
  final String? loadedEntry;
}

/// Decides what a player does for a room state. Every member's player plays the room's song in step (a member that only
/// controlled the room showed its own last song while the room played another, 12 Oct); only the host moves the room
/// on, sends its position and asks for Autoplay.
///
/// [adoptKey] is the key of a song the player already plays because the jam started with it: when the room's current
/// song is that one, the player keeps playing it instead of loading it again.
JamPlan planJamFollow(
  JamState room, {
  required String? me,
  required String? loadedEntry,
  String? adoptKey,
  required bool playerPlaying,
  required bool playerLoading,
  required double playerPosition,
}) {
  final entry = room.current;
  if (entry == null) {
    return JamPlan(playing: playerPlaying ? false : null);
  }
  if (entry.entryId != loadedEntry && entry.listing.key != adoptKey) return JamPlan(load: entry, loadedEntry: entry.entryId);
  return JamPlan(
    loadedEntry: entry.entryId,
    playing: room.isPlaying != playerPlaying ? room.isPlaying : null,
    // a seek by anyone: the room's playhead and the player's differ by more than a moment
    seek: !playerLoading && (playerPosition - room.positionSeconds).abs() > 2.5 ? room.positionSeconds : null,
  );
}

/// A jam: listening together. Every member's device plays the room's song in step and every member controls it; the
/// host may choose to play the room on their device alone ([JamState.onlyHostPlays]) or to control it alone
/// ([JamState.onlyHostControls]: members then only add songs).
///
/// While in one, the room decides what plays: the player's play/pause, next, previous and seek become the room's
/// commands, playing a song adds it to the room, and every member's player follows the room's state as it arrives. One
/// WebSocket carries the commands and the state (LiveSocket pings it); the host also reports its playhead every 15 s
/// while playing, and every member moves to it when it has drifted. An idle jam costs no CPU.
class JamSession extends ChangeNotifier {
  JamSession({this._connect, this.reportEvery = const Duration(seconds: 15)});

  /// The app's one jam session; the screens read this unless a test gives them another.
  static final shared = JamSession();

  final SocketConnector? _connect;
  final Duration reportEvery;

  JamState? state;

  /// The server's last refusal ("Queue is full (200).") or a connection problem, shown in the jam panel.
  String? problem;

  JamPlayer? player;

  /// The signed-in user's id.
  String? me;

  LiveSocket? _socket;
  Timer? _reporter;

  /// The entry the host's player last loaded: a new state with another entry loads that one.
  String? _loadedEntry;

  /// The song that was playing when this jam started: sent to the room with the first state, and kept playing
  /// without a reload when the room makes it current ([planJamFollow]'s adoptKey).
  JamCarry? _carry;
  String? _adoptKey;

  /// While the room catches up with the carried song's place, its playhead (0 after the add) must not pull the
  /// player back: the place the song had, and how many states may still pass before the player follows again.
  double? _holdAt;
  int _holdFor = 0;

  bool get inJam => state != null;
  bool get isHost => state != null && state!.hostId == me;

  // MARK: joining and leaving

  /// Starts a jam. Returns null when it worked, else why not.
  ///
  /// A song that is playing comes in with its place: the room starts with it and the player does not restart it.
  Future<String?> start({String? name}) {
    final trimmed = name?.trim();
    return _enter(() => Api.sendJson('POST', 'jam', {'name': trimmed == null || trimmed.isEmpty ? null : trimmed}),
        carry: player?.jamCarry);
  }

  /// Joins the jam with [code]. Returns null when it worked, else why not.
  Future<String?> join(String code) {
    final typed = code.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (typed.isEmpty) return Future.value("Enter the jam's code.");
    return _enter(() => Api.sendJson('POST', 'jam/join', {'code': typed}));
  }

  Future<String?> _enter(Future<dynamic> Function() request, {JamCarry? carry}) async {
    final JamState room;
    try {
      room = JamState.fromJson(await request() as Map<String, dynamic>);
    } catch (e) {
      return e is ApiError ? e.toString() : "Can't connect to the server.";
    }
    leaveLocally();
    _carry = carry;
    _adoptKey = carry?.listing.key;
    _apply(room);
    _socket = LiveSocket(
      path: 'ws/jam',
      query: {'room_id': room.roomId},
      onMessage: handle,
      onDropped: () => _checkRoom(room.roomId),
      connect: _connect,
    )..start();
    _reporter = Timer.periodic(reportEvery, (_) => _report());
    return null;
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
    _loadedEntry = null;
    _carry = _adoptKey = _holdAt = null;
    _playHere = true;
    player?.jamSetSilent(false);
    player?.jam = null;
    if (was != null) notifyListeners();
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

  /// Play or pause the room. A room with nothing playing starts with the song on screen; without one the user is
  /// told, since a command the room cannot act on would do nothing at all.
  void togglePlay() {
    if (state?.current == null) {
      final onScreen = player?.jamOnScreen;
      if (onScreen != null) {
        add([onScreen]);
      } else {
        player?.jamSay('Nothing is playing in the jam. Play any song to start it.');
      }
      return;
    }
    if (_locked()) return; // starting an empty room above is an add, open to everyone
    _send(state?.isPlaying == true ? const JamCommand.pause() : const JamCommand.play());
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
  /// Play ('now'), Play Next ('next') and Add to Queue ('end') in a jam: one command each, placed by the server.
  /// While the host controls the room, a member's Play and Play Next add to the end instead (the user is told).
  void add(List<Track> tracks, {String placement = 'end'}) {
    if (tracks.isEmpty) return;
    if (placement != 'end' && !canControl) {
      placement = 'end';
      player?.jamSay('Added to the end of the queue: the host controls this jam.');
    }
    _send(JamCommand.add([for (final t in tracks) t.best],
        placement: placement, copies: [for (final t in tracks) JamCommand.otherCopies(t)]));
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

  /// The song ended, or would not play, on this device: the room moves on when it is the host's. Every member's player
  /// plays it, so only one (the host's) speaks for the room; a member's song that would not play stays that member's.
  void songEnded() {
    if (isHost) skip();
  }

  void _send(JamCommand command) {
    if (_socket?.send(command.encode()) != true) return;
    if (problem != null) {
      problem = null;
      notifyListeners();
    }
  }

  void _report() {
    final p = player;
    if (isHost && p != null && p.isPlaying) _socket?.send(JamCommand.position(p.position).encode());
  }

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
    final s = state;
    if (s == null || s.current == null) return null;
    final since = s.isPlaying ? DateTime.now().difference(_stateAt).inMilliseconds / 1000 : 0;
    return s.positionSeconds + since;
  }

  DateTime _stateAt = DateTime.now();

  /// A new state: kept, and this device's player made to match it.
  void _apply(JamState room) {
    _stateAt = DateTime.now();
    if (room != state) {
      state = room;
      notifyListeners();
    }
    final p = player;
    if (p == null) return;
    p.jam = this;
    p.jamSetSilent(_silentHere(room));
    if (room.current == null && _adoptKey != null) {
      // the room is still empty while the song that started it joins: the song plays on, it is not paused
      _sendCarry(room);
      return;
    }
    var at = p.position;
    if (_holdAt != null) {
      if (room.current != null && (room.positionSeconds - _holdAt!).abs() <= 2.5 || --_holdFor <= 0) {
        _holdAt = null;
      } else {
        at = room.positionSeconds;
      }
    }
    final plan = planJamFollow(room,
        me: me,
        loadedEntry: _loadedEntry,
        adoptKey: _adoptKey,
        playerPlaying: p.isPlaying,
        playerLoading: p.jamLoading,
        playerPosition: at);
    _loadedEntry = plan.loadedEntry;
    if (room.current != null) _adoptKey = null;
    _sendCarry(room);
    final entry = plan.load;
    if (entry != null) {
      p.jamLoad(entry.track, room.positionSeconds, playing: room.isPlaying);
      return;
    }
    if (plan.playing != null) p.jamFollowPlaying(plan.playing!);
    if (plan.seek != null) p.jamFollowSeek(plan.seek!);
  }

  /// The first state of a jam that started with a song playing: the room is empty, so the song joins it and the room
  /// is moved to the place the song had.
  void _sendCarry(JamState room) {
    final carry = _carry;
    if (carry == null || room.current != null || _socket?.isOpen != true) return;
    _carry = null;
    _send(JamCommand.add([carry.listing], copies: [carry.copies]));
    if (carry.position > 1) {
      _holdAt = carry.position;
      _holdFor = 3;
      _send(JamCommand.seek(carry.position));
    }
  }

  /// When the socket drops: GET /jam/{id}. A 404 means the room is gone or the user left on another device, so the
  /// user is out of the jam here too.
  Future<void> _checkRoom(String room) async {
    try {
      await Api.getJson('jam/$room');
    } on ApiError catch (e) {
      if (e.status == 404 && state?.roomId == room) leaveLocally();
    } catch (_) {}
  }

  /// Acts on one message from the room's socket: `state` replaces the room, `position` (the host's playhead, every
  /// 15 s while it plays) moves a player that has drifted to it, `error` shows the server's refusal. "pong" is ignored.
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
        final room = state;
        if (room != null && seconds is num) {
          _apply(room.withPosition(seconds.toDouble(), playing: message['is_playing'] as bool? ?? room.isPlaying));
        }
      case 'error':
        problem = message['detail'] as String?;
        if (problem != null) player?.jamSay(problem!);
        _carry = _adoptKey = _holdAt = null; // the room refused the song that started it: follow the room
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _socket?.stop();
    _reporter?.cancel();
    super.dispose();
  }
}
