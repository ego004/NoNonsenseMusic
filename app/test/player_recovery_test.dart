// The player's way out of a copy that will not play (#30), with a fake audio player: a leftover "completed" from the
// replaced copy ends nothing, a load that never returns moves on to the next copy, and a copy fetched again after its
// file failed is really fetched again (never handed back as the deleted file).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/audio_download.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/range_fetcher.dart';
import 'package:nononsense/core/youtube.dart';

import 'audio_cache_test.dart' show FakeAudioHost, blob;
import 'fake_http.dart' show FakeLink;

/// The system's player as the test drives it: what it was given, and the states the test sends.
class FakeAudio extends ja.AudioPlayer {
  FakeAudio() : super(handleInterruptions: false, handleAudioSessionActivation: false);

  final _states = StreamController<ja.PlayerState>.broadcast();
  final loaded = <Uri>[];
  final onDisk = <bool>[]; // for each file given, whether it was there
  Future<void>? holdFirst; // the first load returns only when this completes
  Duration pos = Duration.zero;
  Duration? dur = const Duration(seconds: 224);
  bool _playing = false;

  void send(ja.ProcessingState state, {required bool playing}) => _states.add(ja.PlayerState(playing, state));

  @override
  Stream<ja.PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<ja.PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Duration get position => pos;
  @override
  Duration? get duration => dur;
  @override
  bool get playing => _playing;

  @override
  Future<Duration?> setAudioSource(ja.AudioSource audioSource,
      {bool preload = true, int? initialIndex, Duration? initialPosition}) async {
    final source = audioSource is ja.ClippingAudioSource ? audioSource.child : audioSource as ja.UriAudioSource;
    loaded.add(source.uri);
    if (source.uri.isScheme('file')) onDisk.add(File.fromUri(source.uri).existsSync());
    if (loaded.length == 1 && holdFirst != null) await holdFirst;
    return dur;
  }

  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seek(Duration? position, {int? index}) async => pos = position ?? Duration.zero;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => _playing = false;
  @override
  Future<void> dispose() => _states.close();
}

/// The app's server: /play answers with the audio's address, a jam room for the jam's calls; the play events are
/// recorded.
class AppServer extends http.BaseClient {
  final events = <String>[];
  Map<String, dynamic>? room;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path.startsWith('/play/')) {
      return http.StreamedResponse(const Stream.empty(), 302,
          headers: {'location': 'http://audio.test${path.substring('/play'.length)}.m4a'}, request: request);
    }
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) : null;
    if (path == '/events') events.add((body as Map)['type'] as String);
    final (status, answer) = switch (path) {
      '/ws-ticket' => (200, {'ticket': 't', 'expires_in': 30}),
      '/jam' => (201, room),
      _ => (200, <String, dynamic>{}),
    };
    return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(answer))), status,
        headers: {'content-type': 'application/json'}, request: request);
  }
}

Listing copy(String source, String id) =>
    Listing(source: source, id: id, title: 'Regardless', artists: const ['Asim Azhar'], duration: 224);

void main() {
  late AppServer server;
  late FakeAudio audio;
  late Directory dir;
  late AudioDownloads fetches;
  late FakeAudioHost host;

  setUp(() {
    server = AppServer();
    Api.base = 'http://server.test';
    Api.client = server;
    Api.token = 'test-token';
    Player.autoplay = false;
    audio = FakeAudio();
    dir = Directory.systemTemp.createTempSync('player_recovery');
    host = FakeAudioHost();
    // the cache off: copies stream from their address (YouTube's on Windows are still fetched whole)
    fetches = AudioDownloads(cache: AudioCache(dir)..limitMB = 0, fetcher: RangeFetcher(host, retryDelay: Duration.zero));
  });
  tearDown(() {
    Player.loadTimeout = const Duration(seconds: 15);
    dir.deleteSync(recursive: true);
  });

  Future<void> settle() => pumpEventQueue(times: 50);

  /// The first copy loads, is ready, and "finishes" at once at its end, as Windows played YouTube Music's fragmented
  /// file: the player moves on to the second copy. Then the replaced copy's leftover "completed" arrives.
  Future<void> firstCopyEndsAtOnce() async {
    audio.send(ja.ProcessingState.ready, playing: true);
    await settle();
    audio.pos = const Duration(seconds: 224);
    audio.send(ja.ProcessingState.completed, playing: true);
    await settle();
    expect(audio.loaded.map((u) => u.path), ['/jiosaavn/a.m4a', '/jiosaavn/b.m4a']);
    audio.send(ja.ProcessingState.completed, playing: false); // the leftover: Windows still at the old copy's end
    await settle();
  }

  test('a leftover "completed" from the replaced copy does not end the copy that replaced it', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([Track(copy('jiosaavn', 'a'), [copy('jiosaavn', 'a'), copy('jiosaavn', 'b')], choosingVersion: false)]));
    await settle();
    await firstCopyEndsAtOnce();
    expect(server.events, isNot(contains('finish')), reason: 'the second copy has not even started');
    expect(p.message, "That JioSaavn copy didn't load. Playing another JioSaavn copy.");
    expect(p.playingListing?.id, 'b');

    audio.pos = Duration.zero;
    audio.send(ja.ProcessingState.ready, playing: true);
    await settle();
    expect(p.isPlaying, isTrue);
    audio.send(ja.ProcessingState.completed, playing: true); // its own, once it has been ready: counted (far too soon)
    await settle();
    expect(p.message, "Couldn't play “Regardless”.");
  });

  test("a jam host's player does not skip the room's song for a leftover \"completed\"", () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    final link = FakeLink();
    final jam = JamSession(connect: (_) async => link)
      ..player = p
      ..me = 'me';
    server.room = {
      'room_id': 'room1', 'code': 'abc12', 'name': null, 'host_id': 'me', 'is_playing': true, 'position_seconds': 0,
      'members': [{'user_id': 'me', 'username': 'kai'}],
      'current': {'entry_id': 'e1', 'listing': copy('jiosaavn', 'a').toJson(), 'copies': [copy('jiosaavn', 'b').toJson()]},
      'queue': <Object>[],
    };
    expect(await jam.start(), isNull);
    await settle();
    await firstCopyEndsAtOnce();
    expect(link.sent.where((s) => s.contains('"skip"')), isEmpty);
    expect(p.playingListing?.id, 'b');
    jam.leaveLocally();
  });

  test('a copy the player never finishes opening counts as one that will not load: the next copy, with a word',
      () async {
    Player.loadTimeout = const Duration(milliseconds: 100);
    audio.holdFirst = Completer<void>().future; // never returns, as Windows' player for a file that is not there
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([Track(copy('jiosaavn', 'a'), [copy('jiosaavn', 'a'), copy('jiosaavn', 'b')], choosingVersion: false)]));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(audio.loaded.map((u) => u.path), ['/jiosaavn/a.m4a', '/jiosaavn/b.m4a']);
    expect(p.message, "That JioSaavn copy didn't load. Playing another JioSaavn copy.");
  });

  test('a copy that failed playing from its fetched file is fetched again, with a new link; never the deleted file',
      () async {
    var lookups = 0;
    YouTubeLookup.instance
      ..forget('HLhAG6X785o')
      ..client = _FakeYouTube(() => 'http://audio.test/ytm.m4a?clen=3000&n=${++lookups}');
    host.files['/ytm.m4a'] = blob(3000);
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([Track(copy('ytmusic', 'HLhAG6X785o'), [copy('ytmusic', 'HLhAG6X785o'), copy('youtube', 'k_Pkyyn7UE0')],
        choosingVersion: false)]));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(audio.onDisk, [true]);
    final asked = host.asked.length;

    audio.send(ja.ProcessingState.ready, playing: true);
    await settle();
    audio.send(ja.ProcessingState.completed, playing: true); // at 0:00: far too soon, so it did not play
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(audio.loaded.length, 2, reason: 'the same copy again');
    expect(audio.onDisk, [true, true], reason: 'a file that is there');
    expect(lookups, 2, reason: 'a new link');
    expect(host.asked.length, 2 * asked, reason: 'fetched again');
    expect((p.playingListing?.source, p.message), ('ytmusic', null));
  }, skip: !Platform.isWindows ? 'Windows fetches YouTube copies whole; elsewhere they stream' : null);
}

/// YouTube's home page and player API, answering the lookup with [link] for the audio.
class _FakeYouTube extends http.BaseClient {
  _FakeYouTube(this.link);
  final String Function() link;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request.url.path.endsWith('/player')
        ? jsonEncode({
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'adaptiveFormats': [
                {'itag': 140, 'url': link()},
              ],
            },
          })
        : '<script>{"VISITOR_DATA":"visitor"}</script>';
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200, request: request);
  }
}
