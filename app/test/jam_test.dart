// Jam: the commands sent to the room, what the host's player does for each state, and a whole session against a fake
// server and a fake socket.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/models.dart';

import 'fake_http.dart';

Listing listing(String id, {String title = 'Song'}) =>
    Listing(source: 'jiosaavn', id: id, title: title, artists: const ['Alex'], duration: 200);

Map<String, dynamic> entry(String entryId, Listing l) => {'entry_id': entryId, 'listing': l.toJson()};

Map<String, dynamic> roomJson({
  String host = 'me',
  Map<String, dynamic>? current,
  List<Map<String, dynamic>> queue = const [],
  bool playing = true,
  double position = 0,
  String? name,
}) =>
    {
      'room_id': 'room1',
      'code': 'abc12',
      'name': name,
      'host_id': host,
      'members': [
        {'user_id': 'me', 'username': 'kai'},
        {'user_id': 'u2', 'username': 'sam'},
      ],
      'current': current,
      'is_playing': playing,
      'position_seconds': position,
      'queue': queue,
    };

String stateMessage(Map<String, dynamic> room) => jsonEncode({'type': 'state', 'data': room});

class FakePlayer implements JamPlayer {
  @override
  JamSession? jam;
  @override
  bool isPlaying = false;
  @override
  bool jamLoading = false;
  @override
  double position = 0;
  @override
  JamCarry? jamCarry;
  @override
  Track? jamOnScreen;
  final calls = <String>[];

  @override
  void jamLoad(Track track, double at, {required bool playing}) => calls.add('load ${track.best.id} at $at playing $playing');
  @override
  void jamFollowPlaying(bool playing) => calls.add('playing $playing');
  @override
  void jamFollowSeek(double seconds) => calls.add('seek $seconds');
  @override
  void jamSay(String text) => calls.add('say $text');
  bool silent = false;
  @override
  void jamSetSilent(bool s) => silent = s;
}

JamState state(Map<String, dynamic> json) => JamState.fromJson(json);

void main() {
  tearDown(() {
    Api.client = http.Client();
    Api.token = null;
  });

  test('commands carry only the fields they use', () {
    Map<String, dynamic> m(JamCommand c) => jsonDecode(c.encode()) as Map<String, dynamic>;
    expect(m(const JamCommand.play()), {'type': 'play'});
    expect(m(const JamCommand.pause()), {'type': 'pause'});
    expect(m(const JamCommand.skip()), {'type': 'skip'});
    expect(m(const JamCommand.seek(42.5)), {'type': 'seek', 'seconds': 42.5});
    expect(m(const JamCommand.position(7)), {'type': 'position', 'seconds': 7});
    expect(m(const JamCommand.remove('e1')), {'type': 'remove', 'entry_id': 'e1'});
    expect(m(const JamCommand.jump('e2')), {'type': 'jump', 'entry_id': 'e2'});
    expect(m(const JamCommand.move('e3', 0)), {'type': 'move', 'entry_id': 'e3', 'to_index': 0});
    final add = m(JamCommand.add([listing('a')]));
    expect(add.keys, ['type', 'listings', 'placement']);
    expect(add['placement'], 'end');
    expect(m(JamCommand.add([listing('a')], placement: 'now'))['placement'], 'now', reason: 'Play in a jam plays at once');
    expect(add['listings'][0], containsPair('album', null), reason: 'the server answers 422 when album or popularity is absent');
    expect(add['listings'][0], containsPair('popularity', null));
  });

  group('what the host player does for a state', () {
    JamPlan plan(Map<String, dynamic> room,
            {String? me = 'me', String? loaded, String? adopt, bool playing = true, bool loading = false, double at = 0}) =>
        planJamFollow(state(room), me: me, loadedEntry: loaded, adoptKey: adopt, playerPlaying: playing, playerLoading: loading, playerPosition: at);
    final current = entry('e1', listing('a'));

    test('a new entry is loaded at the room playhead', () {
      final p = plan(roomJson(current: current, position: 12), loaded: 'older', playing: false);
      expect(p.load?.entryId, 'e1');
      expect(p.loadedEntry, 'e1');
    });

    test('the same entry follows the room: play or pause', () {
      expect(plan(roomJson(current: current, playing: false), loaded: 'e1', playing: true).playing, false);
      expect(plan(roomJson(current: current, playing: true), loaded: 'e1', playing: false).playing, true);
      final same = plan(roomJson(current: current, playing: true), loaded: 'e1', playing: true);
      expect((same.playing, same.seek, same.load), (null, null, null));
    });

    test('a seek: only a difference over 2.5 s moves the player', () {
      expect(plan(roomJson(current: current, position: 40), loaded: 'e1', at: 37.6).seek, isNull);
      expect(plan(roomJson(current: current, position: 40), loaded: 'e1', at: 42.4).seek, isNull);
      expect(plan(roomJson(current: current, position: 40), loaded: 'e1', at: 37.4).seek, 40);
      expect(plan(roomJson(current: current, position: 40), loaded: 'e1', at: 43).seek, 40);
      expect(plan(roomJson(current: current, position: 40), loaded: 'e1', at: 3, loading: true).seek, isNull,
          reason: 'a song still loading has no place yet');
    });

    test("not the host: the room's song plays here too, in step", () {
      final room = roomJson(host: 'u2', current: current);
      final p = plan(room);
      expect((p.load?.entryId, p.loadedEntry), ('e1', 'e1'));
    });

    test('no current song: the player pauses and forgets the entry', () {
      final p = plan(roomJson(), loaded: 'e1', playing: true);
      expect((p.load, p.playing, p.loadedEntry), (null, false, null));
    });

    test('a jam that started with this song keeps playing it instead of loading it again', () {
      final p = plan(roomJson(current: current, position: 30), adopt: 'jiosaavn:a', at: 30.4);
      expect((p.load, p.playing, p.seek, p.loadedEntry), (null, null, null, 'e1'));
      expect(plan(roomJson(current: current), adopt: 'jiosaavn:other').load?.entryId, 'e1');
    });
  });

  group('a session', () {
    late FakePlayer player;
    late JamSession jam;
    late FakeServer server;
    late FakeLink link;
    var roomAnswer = <String, dynamic>{};
    var roomStatus = 200;

    setUp(() {
      player = FakePlayer();
      server = FakeServer((method, path, body) async => switch ('$method $path') {
            'POST /ws-ticket' => (200, {'ticket': 't', 'expires_in': 30}),
            'POST /jam' || 'POST /jam/join' => (201, roomAnswer),
            'GET /jam/room1' => (roomStatus, roomStatus == 200 ? roomAnswer : {'detail': 'Not found'}),
            'POST /jam/room1/leave' => (204, null),
            _ => (404, {'detail': 'unexpected $method $path'}),
          });
      useServer(server);
      link = FakeLink();
      jam = JamSession(connect: (_) async => link)
        ..player = player
        ..me = 'me';
      roomStatus = 200;
    });

    /// A message from the server, delivered before the test goes on.
    Future<void> push(String message) async {
      link.push(message);
      await pumpEventQueue(times: 30);
    }

    List<Map<String, dynamic>> sent() =>
        [for (final s in link.sent.where((s) => s != 'ping')) jsonDecode(s) as Map<String, dynamic>];

    test('a state for the host loads the song; the next one with a new place seeks; leaving gives the player back', () async {
      roomAnswer = roomJson();
      expect(await jam.start(), isNull);
      await pumpEventQueue(times: 60);
      expect((jam.inJam, jam.isHost, player.jam), (true, true, jam));

      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 5)));
      expect(player.calls, ['load a at 5.0 playing true']);
      player.isPlaying = true;
      player.position = 6;
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 6.5, queue: [entry('e2', listing('b'))])));
      expect(player.calls.length, 1, reason: 'a queue change alone does nothing to the player');
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 90)));
      expect(player.calls.last, 'seek 90.0');
      player.position = 90;
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 90, playing: false)));
      expect(player.calls.last, 'playing false');

      await jam.leave();
      expect((jam.inJam, player.jam, link.closed), (false, null, true));
      expect(server.count('POST /jam/room1/leave'), 1);
    });

    test('a member who is not the host plays the room\'s song; the room error shows to the user', () async {
      roomAnswer = roomJson(host: 'u2');
      expect(await jam.join('ABC-12'), isNull);
      expect(server.asked, contains('POST /jam/join'));
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')))));
      expect(player.calls.single, startsWith('load a'), reason: 'a member plays the room\'s song too');
      expect(jam.isHost, isFalse);
      await push(jsonEncode({'type': 'error', 'detail': 'Queue is full (200).'}));
      expect(jam.problem, 'Queue is full (200).');
      expect(player.calls.last, 'say Queue is full (200).');
    });

    test('starting a jam while a song plays carries it in and keeps it playing, without a reload or a jump back', () async {
      player.isPlaying = true;
      player.position = 61;
      player.jamCarry = JamCarry(listing('a'), 61);
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);

      await push(stateMessage(roomJson())); // the room, empty: the song joins it and the room moves to its place
      expect(sent().map((m) => m['type']), ['add', 'seek']);
      expect(sent()[0]['listings'][0]['id'], 'a');
      expect(sent()[1]['seconds'], 61);

      // after the add, before the seek
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 0)));
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 61.2)));
      expect(player.calls, isEmpty, reason: 'no load, and no seek to 0');
      player.position = 70;
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 70.1)));
      expect(player.calls, isEmpty);
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 200)));
      expect(player.calls, ['seek 200.0'], reason: 'later seeks are followed again');
    });

    test('play on a room with nothing playing starts it with the song on screen, or says why not', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      jam.togglePlay();
      expect(player.calls.single, startsWith('say '));
      player.jamOnScreen = Track(listing('z'), [listing('z')]);
      jam.togglePlay();
      expect(sent().single['type'], 'add');
      expect(sent().single['listings'][0]['id'], 'z');
    });

    test('commands: toggle follows the room, and songEnded is the host alone', () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), playing: true)));
      jam.togglePlay();
      jam.songEnded();
      jam.seek(-3);
      jam.jump(jam.state!.current!);
      expect(sent().map((m) => m['type']), ['pause', 'seek', 'jump']);
      expect(sent()[1]['seconds'], 0);
    });

    test('a dropped socket with the room gone (404) leaves the jam here', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson()));
      roomStatus = 404;
      link.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((jam.inJam, player.jam), (false, null));
      expect(jam.ended, jamEndedNotice);                       // said, not left without a word (#31)
      roomStatus = 200;
      await jam.start();
      expect(jam.ended, isNull);                               // a new jam: nothing left to say
      jam.leaveLocally();
    });

    test('a dropped socket with the room still there keeps the jam', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson()));
      link.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((jam.inJam, jam.ended), (true, null));
      jam.leaveLocally();
      expect(jam.ended, isNull);                               // leaving yourself needs no notice
    });

    test('a refused start gives the reason and no room', () async {
      Api.client = FakeServer((m, p, b) async => (409, {'detail': 'Already in a jam'}));
      expect(await jam.start(), 'Already in a jam');
      expect(jam.inJam, isFalse);
      expect(await jam.join('  '), "Enter the jam's code.");
    });

    test("a member plays the room's song with its other copies to fall back on, and sends copies with what it adds", () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      final withCopies = entry('e1', listing('a'))..['copies'] = [listing('b').toJson(), listing('c').toJson()];
      await push(stateMessage(roomJson(host: 'u2', current: withCopies)));
      expect(player.calls.single, startsWith('load a'));
      expect([for (final l in JamEntry.fromJson(withCopies).track.listings) l.id], ['a', 'b', 'c']);
      expect([for (final l in JamEntry.fromJson(entry('e2', listing('d'))).track.listings) l.id], ['d'],
          reason: 'an entry from an app that sent no copies has the one');

      jam.add([Track(listing('x'), [listing('x'), listing('y')])]);
      await pumpEventQueue();
      final add = sent().last;
      expect(add['type'], 'add');
      expect(add['copies'], [
        [listing('y').toJson()]
      ], reason: "the song's other copy goes with it");
    });

    test('every member hears the room until the host plays it alone; then the others follow silently', () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      final song = entry('e1', listing('a'));
      await push(stateMessage(roomJson(host: 'u2', current: song)));
      expect(player.silent, isFalse, reason: 'every device plays by default');
      await push(stateMessage(roomJson(host: 'u2', current: song)..['only_host_plays'] = true));
      expect((jam.state!.onlyHostPlays, player.silent), (true, true));
      jam.playHere = true;
      expect(player.silent, isTrue, reason: "Play here cannot override the host's choice");
      await push(stateMessage(roomJson(host: 'u2', current: song)));
      expect(player.silent, isFalse);
      jam.playHere = false;
      expect(player.silent, isTrue, reason: 'a member may still mute this device');
      jam.leaveLocally();
    });

    test("the host chooses where the jam plays, and the host's own device is never silent", () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      jam.setOnlyHostPlays(true);
      await pumpEventQueue();
      expect(sent().last, {'type': 'only_host_plays', 'on': true});
      await push(stateMessage(roomJson(current: entry('e1', listing('a')))..['only_host_plays'] = true));
      expect(player.silent, isFalse);
      jam.leaveLocally();
    });

    test("a member that has drifted moves to the host's playhead when it is reported", () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 10)));
      player.isPlaying = true;
      player.position = 11;
      await push(jsonEncode({'type': 'position', 'seconds': 12.0, 'is_playing': true}));
      expect(player.calls.last, startsWith('load'), reason: 'within a moment of the room: left alone');
      player.position = 4;
      await push(jsonEncode({'type': 'position', 'seconds': 27.0, 'is_playing': true}));
      expect(player.calls.last, 'seek 27.0');
      jam.leaveLocally();
    });

    test("the room's playhead moves on while it plays and holds while it is paused: a song still loading starts there (#28)",
        () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 10)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(jam.playhead, closeTo(10.4, 0.15), reason: 'the room played on while this song loaded');
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 20, playing: false)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(jam.playhead, 20);
      jam.leaveLocally();
    });

    test("while the host controls the jam a member's play, skip and seek are not sent, and Play adds to the end", () async {
      roomAnswer = roomJson(host: 'u2');
      await jam.join('abc12');
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')))..['only_host_controls'] = true));
      expect(jam.canControl, isFalse);
      final before = sent().length;
      jam.togglePlay();
      jam.skip();
      jam.seek(40);
      await pumpEventQueue();
      expect(sent().length, before, reason: 'the server would refuse them');
      expect(player.calls.last, 'say ${JamSession.lockedNotice}');

      jam.add([Track(listing('x'), [listing('x')])], placement: 'now');
      await pumpEventQueue();
      expect((sent().last['type'], sent().last['placement']), ('add', 'end'));
      expect(player.calls.last, startsWith('say Added to the end of the queue'));

      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')))));
      jam.skip();
      await pumpEventQueue();
      expect((jam.canControl, sent().last['type']), (true, 'skip'), reason: 'turned off: every member controls again');
      jam.leaveLocally();
    });

    test('the host keeps every control, and sends the setting', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(current: entry('e1', listing('a')))..['only_host_controls'] = true));
      jam.setOnlyHostControls(true);
      jam.skip();
      await pumpEventQueue();
      final out = sent();
      expect(out[out.length - 2], {'type': 'only_host_controls', 'on': true});
      expect(out.last['type'], 'skip');
      jam.leaveLocally();
    });
  });
}
