// Jam: the scenarios of docs/jam.md (the same list as backend/tests/test_jam.py and the Mac's NN_SELFTEST_JAM), against a
// fake server and a fake socket, with a fake player that records what the room asks of it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  List<(String, String)> members = const [('me', 'kai'), ('u2', 'sam')],
  String id = 'room1',
}) =>
    {
      'room_id': id,
      'code': 'abc12',
      'name': name,
      'host_id': host,
      'members': [for (final (id, name) in members) {'user_id': id, 'username': name}],
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
  String? jamPlayingKey;
  @override
  JamSong? jamSong;
  List<Track> radio = const [];
  final radioSeeds = <String>[];
  final calls = <String>[];
  double? loadedAt;

  @override
  void jamLoad(Track track, double at, {required bool playing}) {
    calls.add('load ${track.best.id} playing $playing');
    loadedAt = at;
    jamPlayingKey = track.best.key;
  }

  @override
  void jamFollowPlaying(bool playing) => calls.add('playing $playing');
  @override
  void jamFollowSeek(double seconds) => calls.add('seek ${seconds.round()}');
  @override
  void jamSay(String text) => calls.add('say $text');
  bool silent = false;
  @override
  void jamSetSilent(bool s) => silent = s;
  @override
  Future<List<Track>> jamRadio(Listing seed, List<Listing> exclude) async {
    radioSeeds.add(seed.id);
    return radio;
  }

  /// This player on [l] at [seconds], playing or not, as the user left it before a jam.
  void playing(Listing l, double seconds, {bool on = true, List<Listing> copies = const []}) {
    jamPlayingKey = l.key;
    position = seconds;
    isPlaying = on;
    jamSong = JamSong(l, seconds, playing: on, copies: copies);
  }
}

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
    expect(m(const JamCommand.ended('e1')), {'type': 'ended', 'entry_id': 'e1'});
    expect(m(const JamCommand.remove('e1')), {'type': 'remove', 'entry_id': 'e1'});
    expect(m(const JamCommand.jump('e2')), {'type': 'jump', 'entry_id': 'e2'});
    expect(m(const JamCommand.move('e3', 0)), {'type': 'move', 'entry_id': 'e3', 'to_index': 0});
    final add = m(JamCommand.add([listing('a')]));
    expect(add.keys, ['type', 'listings', 'placement']);
    expect(add['placement'], 'end');
    expect(m(JamCommand.add([listing('a')], placement: 'now'))['placement'], 'now', reason: 'Play in a jam plays at once');
    expect(add['listings'][0], containsPair('album', null), reason: 'the server answers 422 when album or popularity is absent');
    expect(add['listings'][0], containsPair('popularity', null));
    expect(JamSong(listing('a'), 61.5, playing: false, copies: [listing('b')]).toJson(),
        {'listing': listing('a').toJson(), 'copies': [listing('b').toJson()], 'seconds': 61.5, 'playing': false});
  });

  group('the scenarios', () {
    late FakePlayer player;
    late JamSession jam;
    late FakeServer server;
    late FakeLink link;
    var roomAnswer = <String, dynamic>{};
    var roomStatus = 200;
    final bodies = <String, Object?>{};

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      player = FakePlayer();
      bodies.clear();
      server = FakeServer((method, path, body) async {
        bodies['$method $path'] = body;
        return switch ('$method $path') {
          'POST /ws-ticket' => (200, {'ticket': 't', 'expires_in': 30}),
          'POST /jam' || 'POST /jam/join' => (201, roomAnswer),
          'GET /jam/room1' => (roomStatus, roomStatus == 200 ? roomAnswer : {'detail': 'Not found'}),
          'POST /jam/room1/leave' => (204, null),
          _ => (404, {'detail': 'unexpected $method $path'}),
        };
      });
      useServer(server);
      link = FakeLink();
      jam = JamSession(connect: (_) async => link)
        ..player = player
        ..me = 'me';
      roomStatus = 200;
    });

    tearDown(() => jam.leaveLocally());

    /// A message from the server, delivered before the test goes on.
    Future<void> push(String message) async {
      link.push(message);
      await pumpEventQueue(times: 30);
    }

    List<Map<String, dynamic>> sent() =>
        [for (final s in link.sent.where((s) => s != 'ping')) jsonDecode(s) as Map<String, dynamic>];

    Future<void> joinAsMember([Map<String, dynamic>? room]) async {
      roomAnswer = room ?? roomJson(host: 'u2');
      expect(await jam.join('ABC-12'), isNull);
      await pumpEventQueue(times: 60);
    }

    test('1. a jam started with a song playing starts with it where it was, and the player keeps it', () async {
      player.playing(listing('a'), 61, copies: [listing('b')]);
      roomAnswer = roomJson(current: entry('e1', listing('a'))..['copies'] = [listing('b').toJson()], position: 61);
      expect(await jam.start(), isNull);
      await pumpEventQueue(times: 60);
      final song = (bodies['POST /jam'] as Map)['song'] as Map;
      expect((song['listing']['id'], song['seconds'], song['playing'], song['copies'][0]['id']), ('a', 61, true, 'b'),
          reason: 'one request: the room starts with the song, not an add and a seek after its first, empty, state');
      expect((jam.isHost, player.jam), (true, jam));
      expect(player.calls, isEmpty, reason: 'no reload, no jump, no pause');
      await push(stateMessage(roomJson(current: entry('e1', listing('a')), position: 200)));
      expect(player.calls, ['seek 200'], reason: 'a later seek is followed');

      jam.leaveLocally();
      player.jamSong = null;
      roomAnswer = roomJson();
      await jam.start();
      expect((bodies['POST /jam'] as Map).containsKey('song'), isFalse, reason: 'nothing on screen: an empty room');
    });

    test('2. joining an empty room brings your song, which plays on, and Play and Pause then work (bug of 14 Oct)', () async {
      player.playing(listing('a'), 30);
      await joinAsMember(roomJson(host: 'u2', current: entry('e9', listing('a')), position: 30));
      expect(((bodies['POST /jam/join'] as Map)['song'] as Map)['seconds'], 30);
      expect(player.calls, isEmpty, reason: 'the Mac paused it here, then refused Play: "Nothing to play."');
      jam.setPlaying(false);
      jam.setPlaying(true);
      expect(sent().map((m) => m['type']), ['pause', 'play']);
    });

    test("2. joining a room with a song plays the room's, from the room's playhead", () async {
      player.playing(listing('mine'), 12);
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 50));
      expect(player.calls, ['load a playing true']);
      expect(player.loadedAt, closeTo(50, 0.2));
    });

    test('3. play and pause, by anyone, reach every player; a button sends what it shows', () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a'))));
      player.calls.clear();
      player.isPlaying = true;
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), playing: false)));
      expect(player.calls, ['playing false']);
      player.isPlaying = false;
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')))));
      expect(player.calls.last, 'playing true');
      // still loading here, so its button shows Play while the room plays: Play, not a pause for everyone
      jam.setPlaying(true);
      expect(sent().last['type'], 'play');
    });

    test('3. Play with the room empty starts it with the song on screen, or says how to start', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      jam.setPlaying(true);
      expect(player.calls.single, 'say Nothing is playing in the jam. Play any song to start it.');
      player.playing(listing('z'), 0, on: false);
      jam.setPlaying(true);
      expect((sent().single['type'], sent().single['placement'], sent().single['listings'][0]['id']), ('add', 'now', 'z'));
      expect(player.calls.last, 'say Playing “Song” in the jam');
    });

    test('4. a seek moves every player; under 2.5 s apart, or while loading, nothing moves', () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 10));
      player
        ..calls.clear()
        ..isPlaying = true
        ..position = 11;
      await push(jsonEncode({'type': 'position', 'seconds': 12.0, 'is_playing': true}));
      expect(player.calls, isEmpty, reason: 'within a moment of the room: left alone');
      player.position = 4;
      await push(jsonEncode({'type': 'position', 'seconds': 27.0, 'is_playing': true}));
      expect(player.calls.single, 'seek 27', reason: "a member that drifted moves to the host's report");
      player.jamLoading = true;
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 90)));
      expect(player.calls.length, 1, reason: 'a song still loading starts at the playhead when ready instead');
      expect(jam.state!.positionSeconds, 90);
    });

    test("5. Next and Previous are the room's: the next song, or this one from the start", () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a'))));
      jam.skip();
      jam.seek(-3);
      expect(sent().map((m) => (m['type'], m['seconds'])), [('skip', null), ('seek', 0)]);
    });

    test('6. every member says when the song ended here: the entry it loaded, not one the room moved to', () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a'))));
      jam.songEnded();
      expect(sent().single, {'type': 'ended', 'entry_id': 'e1'}, reason: 'not the host: the room no longer waits for it');
    });

    test('7. the host leaving makes the next member host, who is told and runs Autoplay', () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a'))));
      player
        ..isPlaying = true
        ..radio = [Track(listing('r1'), [listing('r1')])];
      await push(stateMessage(roomJson(host: 'me', current: entry('e1', listing('a')), members: [('me', 'kai')])));
      expect(player.calls.where((c) => c.startsWith('say')), ["say “sam” left the jam. You're the host now."]);
      expect(player.radioSeeds, ['a'], reason: 'the host asks for songs like the last one once the queue runs low');
      expect(sent().last['listings'][0]['id'], 'r1');
      await push(stateMessage(roomJson(host: 'me', current: entry('e1', listing('a')), members: [('me', 'kai')])));
      expect(player.radioSeeds, ['a'], reason: 'once per song asked about');
    });

    test('7. a handover is told to everyone, and a member asks for no Autoplay', () async {
      const three = [('me', 'kai'), ('u2', 'sam'), ('u3', 'ana')];
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a')), members: three));
      await push(stateMessage(roomJson(host: 'u3', current: entry('e1', listing('a')), members: three)));
      expect(player.calls, contains('say “ana” is the host now.'));
      expect(player.radioSeeds, isEmpty);
    });

    test("8. a slow load starts at the room's playhead as it is when ready, which moves on while the room plays (#28)",
        () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 10));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(jam.playhead, closeTo(10.4, 0.15), reason: 'the room played on while this song loaded');
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), position: 20, playing: false)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(jam.playhead, 20);
    });

    test("9. the room's song comes with its other copies to fall back on, and an add sends the song's copies", () async {
      final withCopies = entry('e1', listing('a'))..['copies'] = [listing('b').toJson(), listing('c').toJson()];
      await joinAsMember(roomJson(host: 'u2', current: withCopies));
      expect(player.calls.single, startsWith('load a'));
      expect([for (final l in JamEntry.fromJson(withCopies).track.listings) l.id], ['a', 'b', 'c']);
      expect([for (final l in JamEntry.fromJson(entry('e2', listing('d'))).track.listings) l.id], ['d'],
          reason: 'an entry from an app that sent no copies has the one');
      jam.add([Track(listing('x'), [listing('x'), listing('y')])]);
      expect(sent().last['copies'], [
        [listing('y').toJson()]
      ], reason: "the song's other copy goes with it");
      expect(player.calls.last, 'say Added “Song” to the jam');
    });

    test('10. after a dropped socket the app connects again and follows the room as it is now', () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a'))));
      player
        ..isPlaying = true
        ..calls.clear();
      final first = link;
      link = FakeLink();
      first.close();
      await pumpEventQueue();
      jam.skip();
      expect(player.calls.single, 'say ${JamSession.notConnected}', reason: 'not sent late, and not dropped without a word');
      player.calls.clear();
      await Future<void>.delayed(const Duration(milliseconds: 1300)); // the first wait, 1 s
      expect((jam.inJam, jam.ended), (true, null));
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')), playing: false)));
      expect(player.calls, ['playing false'], reason: 'paused meanwhile: the state on connecting says so');
    });

    test('11. the room gone (404 after a drop) leaves the jam and says so; a new jam has nothing to say', () async {
      await joinAsMember();
      roomStatus = 404;
      link.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((jam.inJam, player.jam, jam.ended), (false, null, jamEndedNotice));
      roomStatus = 200;
      await jam.start();
      expect(jam.ended, isNull);
    });

    test('11. removed by the host, or left on another device: told at once, and out', () async {
      await joinAsMember();
      await push(jsonEncode({'type': 'out', 'reason': 'removed'}));
      expect((jam.inJam, jam.ended), (false, 'The host removed you from the jam.'));
      link = FakeLink();
      await joinAsMember();
      await push(jsonEncode({'type': 'out', 'reason': 'left'}));
      expect((jam.inJam, jam.ended), (false, 'You left the jam on another device.'));
    });

    test('11. the app opened again is back in the jam it was in, or says it ended', () async {
      await joinAsMember();
      await pumpEventQueue();
      expect((await SharedPreferences.getInstance()).getString('jamRoom'), 'room1');
      final again = JamSession(connect: (_) async => FakeLink())
        ..player = FakePlayer()
        ..me = 'me';
      await again.resume();
      expect(again.state?.roomId, 'room1', reason: 'still a member: back in, following the room');
      again.leaveLocally();
      await pumpEventQueue();
      expect((await SharedPreferences.getInstance()).getString('jamRoom'), isNull, reason: 'left here: forgotten');

      await (await SharedPreferences.getInstance()).setString('jamRoom', 'room1');
      roomStatus = 404;
      await again.resume();
      await pumpEventQueue();
      expect((again.inJam, again.ended), (false, jamEndedNotice));
      expect((await SharedPreferences.getInstance()).getString('jamRoom'), isNull);
    });

    test("12. while the host controls the jam a member's play, skip and seek are not sent, and Play adds to the end",
        () async {
      await joinAsMember(roomJson(host: 'u2', current: entry('e1', listing('a')))..['only_host_controls'] = true);
      expect(jam.canControl, isFalse);
      final before = sent().length;
      jam.setPlaying(false);
      jam.skip();
      jam.seek(40);
      expect(sent().length, before, reason: 'the server would refuse them');
      expect(player.calls.last, 'say ${JamSession.lockedNotice}');
      jam.add([Track(listing('x'), [listing('x')])], placement: 'now');
      expect((sent().last['type'], sent().last['placement']), ('add', 'end'));
      expect(player.calls.last, 'say Added “Song” to the jam: the host controls this jam');
      await push(stateMessage(roomJson(host: 'u2', current: entry('e1', listing('a')))));
      jam.skip();
      expect((jam.canControl, sent().last['type']), (true, 'skip'), reason: 'turned off: every member controls again');
    });

    test('12. the host keeps every control, and sends the settings', () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      await push(stateMessage(roomJson(current: entry('e1', listing('a')))..['only_host_controls'] = true));
      jam.setOnlyHostControls(true);
      jam.skip();
      final out = sent();
      expect(out[out.length - 2], {'type': 'only_host_controls', 'on': true});
      expect(out.last['type'], 'skip');
    });

    test('every member hears the room until the host plays it alone; then the others follow silently', () async {
      final song = entry('e1', listing('a'));
      await joinAsMember(roomJson(host: 'u2', current: song));
      expect(player.silent, isFalse, reason: 'every device plays by default');
      await push(stateMessage(roomJson(host: 'u2', current: song)..['only_host_plays'] = true));
      expect((jam.state!.onlyHostPlays, player.silent), (true, true));
      jam.playHere = true;
      expect(player.silent, isTrue, reason: "Play here cannot override the host's choice");
      await push(stateMessage(roomJson(host: 'u2', current: song)));
      expect(player.silent, isFalse);
      jam.playHere = false;
      expect(player.silent, isTrue, reason: 'a member may still mute this device');
    });

    test("the host's own device is never silent", () async {
      roomAnswer = roomJson();
      await jam.start();
      await pumpEventQueue(times: 60);
      jam.setOnlyHostPlays(true);
      expect(sent().last, {'type': 'only_host_plays', 'on': true});
      await push(stateMessage(roomJson(current: entry('e1', listing('a')))..['only_host_plays'] = true));
      expect(player.silent, isFalse);
    });

    test('starting or joining another jam leaves the one this device was in, on the server too', () async {
      await joinAsMember();
      roomAnswer = roomJson(id: 'room2');
      link = FakeLink();
      expect(await jam.start(), isNull);
      await pumpEventQueue();
      expect((jam.state!.roomId, server.count('POST /jam/room1/leave')), ('room2', 1));
    });

    test('a refused start gives the reason and no room', () async {
      Api.client = FakeServer((m, p, b) async => (409, {'detail': 'Already in a jam'}));
      expect(await jam.start(), 'Already in a jam');
      expect(jam.inJam, isFalse);
      expect(await jam.join('  '), "Enter the jam's code.");
    });

    test('a refusal from the room is shown to the user', () async {
      await joinAsMember();
      await push(jsonEncode({'type': 'error', 'detail': 'Queue is full (200).'}));
      expect((jam.problem, player.calls.last), ('Queue is full (200).', 'say Queue is full (200).'));
    });
  });

  // Traffic at rest (docs/jam.md), in fake time: what an app sends in five minutes of a room playing a song. Before 17
  // Oct the host sent 32 (12 pings and 20 reports) and a member 12 pings.
  for (final (who, host, playing, pings, reports) in [
    ('the host, the room playing', true, true, 0, 20),
    ('a member', false, true, 12, 0),
    ('the host, the room paused', true, false, 12, 0),
  ]) {
    testWidgets('traffic at rest: $who', (tester) async {
      SharedPreferences.setMockInitialValues({});
      useServer(FakeServer((method, path, body) async => switch ('$method $path') {
            'POST /ws-ticket' => (200, {'ticket': 't', 'expires_in': 30}),
            _ => (201, roomJson(host: host ? 'me' : 'u2')),
          }));
      final link = FakeLink();
      final player = FakePlayer()..isPlaying = playing;
      final jam = JamSession(connect: (_) async => link)
        ..player = player
        ..me = 'me';
      await (host ? jam.start() : jam.join('abc12'));
      await tester.pump(const Duration(seconds: 1));
      link.push(stateMessage(roomJson(host: host ? 'me' : 'u2', current: entry('e1', listing('a')), playing: playing)));
      await tester.pump(const Duration(seconds: 1));
      final before = link.sent.length;
      await tester.pump(const Duration(minutes: 5));
      final out = link.sent.skip(before).toList();
      expect((out.where((s) => s == 'ping').length, out.where((s) => s.contains('"position"')).length), (pings, reports));
      jam.leaveLocally();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
