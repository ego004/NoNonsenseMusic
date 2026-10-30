// ⏮ onto a song that will not load keeps going back (29 Oct): after the last copy of a song fails the player moved on to
// the NEXT song whichever way you were going, so pressing ⏮ on a flaky connection jumped forward again and the queue
// seemed not to follow. Fake audio that refuses chosen songs, as player_recovery_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/audio_download.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/range_fetcher.dart';

import 'audio_cache_test.dart' show FakeAudioHost;
import 'player_recovery_test.dart' show AppServer, FakeAudio, copy;

/// Refuses to load the songs named in [refuse], as a link that does not answer.
class RefusingAudio extends FakeAudio {
  final refuse = <String>{};

  @override
  Future<Duration?> setAudioSource(ja.AudioSource audioSource,
      {bool preload = true, int? initialIndex, Duration? initialPosition}) async {
    final source = audioSource is ja.ClippingAudioSource ? audioSource.child : audioSource as ja.UriAudioSource;
    if (refuse.any((id) => source.uri.path.endsWith('/$id.m4a'))) throw ja.PlayerException(0, 'refused', null);
    return super.setAudioSource(audioSource, preload: preload, initialIndex: initialIndex, initialPosition: initialPosition);
  }
}

void main() {
  late RefusingAudio audio;
  late Directory dir;
  late AudioDownloads fetches;

  setUp(() {
    Api.base = 'http://server.test';
    Api.client = AppServer();
    Api.token = 'test-token';
    Player.autoplay = false;
    audio = RefusingAudio();
    dir = Directory.systemTemp.createTempSync('player_previous_failure');
    fetches = AudioDownloads(cache: AudioCache(dir)..limitMB = 0, fetcher: RangeFetcher(FakeAudioHost(), retryDelay: Duration.zero));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> settle() => pumpEventQueue(times: 200);
  Track song(String id) => Track(copy('jiosaavn', id), [copy('jiosaavn', id)], choosingVersion: false);

  test('⏮ onto a song that will not load goes on back to the one before it', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c'), song('d')], startAt: 2));
    await settle();
    audio.refuse.add('b');

    await p.previous();
    await settle();

    expect(p.current?.best.id, 'a', reason: 'b would not load: on back, not forward again');
    expect(p.queue.upNext.map((t) => t.best.id), ['b', 'c', 'd']);
  });

  test('⏭ onto a song that will not load still goes on forward', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c'), song('d')], startAt: 0));
    await settle();
    audio.refuse.add('b');

    await p.next();
    await settle();

    expect(p.current?.best.id, 'c');
  });

  test('⏮ onto a song that will not load, with nothing before it, plays the next one that does', () async {
    final p = Player(audio: audio, fetches: fetches);
    addTearDown(p.dispose);
    unawaited(p.play([song('a'), song('b'), song('c')], startAt: 1));
    await settle();
    audio.refuse.add('a');

    await p.previous();
    await settle();

    expect(p.current?.best.id, 'b', reason: 'a would not load and nothing is before it: back to where you were');
  });
}
