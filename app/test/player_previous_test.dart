// ⏮ with the queue: it steps back one song, Up Next follows (the song left is next again), and presses that come
// faster than the player settles each step back one. Fake audio, as player_recovery_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/audio_download.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/range_fetcher.dart';

import 'audio_cache_test.dart' show FakeAudioHost;
import 'player_recovery_test.dart' show AppServer, FakeAudio, copy;

void main() {
  late FakeAudio audio;
  late Directory dir;
  late AudioDownloads fetches;

  setUp(() {
    Api.base = 'http://server.test';
    Api.client = AppServer();
    Api.token = 'test-token';
    Player.autoplay = false;
    audio = FakeAudio();
    dir = Directory.systemTemp.createTempSync('player_previous');
    fetches = AudioDownloads(cache: AudioCache(dir)..limitMB = 0, fetcher: RangeFetcher(FakeAudioHost(), retryDelay: Duration.zero));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> settle() => pumpEventQueue(times: 50);
  Track song(String id) => Track(copy('jiosaavn', id), [copy('jiosaavn', id)], choosingVersion: false);
  List<String> ids(Iterable<Track> tracks) => tracks.map((t) => t.best.id).toList();

  test('⏮ steps back one song, and the song left is next again', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c'), song('d')], startAt: 2));
    await settle();
    var notified = 0;
    p.addListener(() => notified++);

    await p.previous();
    await settle();

    expect(p.current?.best.id, 'b');
    expect(ids(p.queue.upNext), ['c', 'd'], reason: 'Up Next follows');
    expect(notified, greaterThan(0), reason: 'the screen is told');
  });

  test('two presses in a row step back two songs, and Up Next shows both again', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c'), song('d')], startAt: 3));
    await settle();

    final first = p.previous();
    final second = p.previous();
    await Future.wait([first, second]);
    await settle();

    expect(p.current?.best.id, 'b');
    expect(ids(p.queue.upNext), ['c', 'd']);
  });

  test('a press after 3 s into the song restarts it and leaves the queue as it is', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c')], startAt: 1));
    await settle();
    audio.pos = const Duration(seconds: 10);

    await p.previous();
    await settle();

    expect(p.current?.best.id, 'b');
    expect(ids(p.queue.upNext), ['c']);
  });
}
