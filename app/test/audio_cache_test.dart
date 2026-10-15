// The audio cache, the ranged fetch, the next-song rule, downloads and the loopback server, against a fake audio host.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/audio_download.dart';
import 'package:nononsense/core/download_store.dart';
import 'package:nononsense/core/loopback_audio.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/range_fetcher.dart';

/// An audio host: each path serves its bytes with Range support. [fail] makes the next requests to a path fail with a
/// dropped connection, [whole] makes a path ignore Range (a 200 with the whole file), [hold] keeps a path's answers
/// back until the future completes.
class FakeAudioHost extends http.BaseClient {
  final files = <String, Uint8List>{};
  final fail = <String, int>{};
  final whole = <String>{};
  final hold = <String, Future<void>>{};
  final asked = <String>[]; // "path bytes=a-b"

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final range = request.headers['range'] ?? '';
    asked.add('$path $range');
    await hold[path];
    if ((fail[path] ?? 0) > 0) {
      fail[path] = fail[path]! - 1;
      throw const SocketException('dropped');
    }
    final data = files[path];
    if (data == null) return http.StreamedResponse(const Stream.empty(), 404, request: request);
    if (whole.contains(path)) return http.StreamedResponse(Stream.value(data), 200, request: request);
    final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
    final from = int.parse(m[1]!), to = (int.parse(m[2]!) + 1).clamp(0, data.length);
    return http.StreamedResponse(Stream.value(data.sublist(from, to)), 206,
        headers: {'content-range': 'bytes $from-${to - 1}/${data.length}'}, request: request);
  }
}

Uint8List blob(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) i % 251]);
Listing song(String source, String id) =>
    Listing(source: source, id: id, title: 'Song $id', artists: const ['Alex'], duration: 200);
RangeFetcher quick(http.Client c) => RangeFetcher(c, retryDelay: Duration.zero);

void main() {
  late Directory dir;
  late AudioCache cache;
  late FakeAudioHost host;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('audio_cache_test');
    cache = AudioCache(Directory('${dir.path}/Audio')..createSync());
    host = FakeAudioHost();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String key, int bytes, DateTime used) {
    cache.path(key)
      ..writeAsBytesSync(blob(bytes))
      ..setLastModifiedSync(used);
  }

  test('eviction removes the least recently played first, until the rest fit the limit', () {
    cache.limitMB = 1; // 1,000,000 bytes
    put('jiosaavn:old', 400000, DateTime(2020));
    put('jiosaavn:mid', 400000, DateTime(2021));
    put('jiosaavn:new', 400000, DateTime(2022));
    cache.evict();
    expect(cache.peek('jiosaavn:old'), isNull);
    expect(cache.peek('jiosaavn:mid'), isNotNull);
    expect(cache.peek('jiosaavn:new'), isNotNull);
    expect(cache.size(), 800000);
  });

  test('playing a song marks it used, so it outlives older ones; Off keeps nothing and finds nothing', () {
    cache.limitMB = 1;
    put('jiosaavn:a', 400000, DateTime(2020));
    put('jiosaavn:b', 400000, DateTime(2021));
    expect(cache.file('jiosaavn:a'), isNotNull); // played now
    put('jiosaavn:c', 400000, DateTime(2022));
    cache.evict();
    expect(cache.peek('jiosaavn:a'), isNotNull);
    expect(cache.peek('jiosaavn:b'), isNull);
    cache.limitMB = 0;
    expect(cache.file('jiosaavn:a'), isNull, reason: 'off: the file is not used');
    cache.evict();
    expect(cache.size(), 0);
  });

  test('a song in the cache is used without any network call or link lookup', () async {
    put('jiosaavn:x', 1000, DateTime(2020));
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    var lookedUp = false;
    await fetches.prefetchNext(next: song('jiosaavn', 'x'), linkFor: (_) async { lookedUp = true; return Uri(); });
    expect(lookedUp, isFalse);
    expect(host.asked, isEmpty);
    expect(cache.file('jiosaavn:x'), isNotNull);
  });

  test('a song is fetched in bounded ranges (256 KB, then 1 MB), written to a file, and kept', () async {
    final data = blob(2 * 1024 * 1024 + 5000);
    host.files['/s.mp4'] = data;
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    final d = fetches.fetch('jiosaavn:s', Uri.parse('http://audio.test/s.mp4'));
    await d.whole();
    expect(d.isComplete, isTrue);
    expect(host.asked, [
      '/s.mp4 bytes=0-262143',
      '/s.mp4 bytes=262144-1310719',
      '/s.mp4 bytes=1310720-2359295',
    ]);
    expect(cache.peek('jiosaavn:s')!.readAsBytesSync(), data);
    expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty);
    // the bytes are readable from the file while and after they arrive
    expect(await d.bytes(100, 199), data.sublist(100, 200));
  });

  test('a range that fails is asked again twice; a third failure fails the song and leaves no file', () async {
    host.files['/r.mp4'] = blob(1000);
    host.fail['/r.mp4'] = 2;
    final ok = AudioDownloads(cache: cache, fetcher: quick(host)).fetch('jiosaavn:r', Uri.parse('http://audio.test/r.mp4'));
    await ok.whole();
    expect(ok.isComplete, isTrue);
    expect(host.asked.length, 3);

    host.asked.clear();
    host.fail['/r.mp4'] = 3;
    final bad = AudioDownloads(cache: cache, fetcher: quick(host)).fetch('jiosaavn:r2', Uri.parse('http://audio.test/r.mp4'));
    await bad.whole();
    expect(bad.isComplete, isFalse);
    expect(bad.hasFailed, isTrue);
    expect(host.asked.length, 3);
    expect(cache.peek('jiosaavn:r2'), isNull);
  });

  test('a 200 to a range past the first byte is refused at once, not read and not retried', () async {
    host.files['/w.mp4'] = blob(2000);
    host.whole.add('/w.mp4');
    final fetcher = quick(host);
    expect((await fetcher.fetchWithRetry(Uri.parse('http://audio.test/w.mp4'), 0, 99)).total, 2000,
        reason: 'at byte 0 a whole-file answer is the file');
    host.asked.clear();
    await expectLater(fetcher.fetchWithRetry(Uri.parse('http://audio.test/w.mp4'), 100, 199), throwsA(isA<RangeRefused>()));
    expect(host.asked.length, 1);
  });

  test('the next song is fetched only after the playing song is all in', () async {
    final release = Completer<void>();
    host.files['/a.mp4'] = blob(3000);
    host.files['/b.mp4'] = blob(3000);
    host.hold['/a.mp4'] = release.future;
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    final playing = fetches.fetch('jiosaavn:a', Uri.parse('http://audio.test/a.mp4'))..start();
    final prefetch = fetches.prefetchNext(
        playingKey: 'jiosaavn:a', next: song('jiosaavn', 'b'), linkFor: (_) async => Uri.parse('http://audio.test/b.mp4'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(host.asked.where((a) => a.startsWith('/b.mp4')), isEmpty, reason: 'the playing song is not all in');
    release.complete();
    await prefetch;
    expect(playing.isComplete, isTrue);
    expect(host.asked.where((a) => a.startsWith('/b.mp4')), isNotEmpty);
    expect(cache.peek('jiosaavn:b'), isNotNull);
  });

  test('a finished fetch whose file is gone is fetched again, not handed back (#30)', () async {
    host.files['/g.mp4'] = blob(3000);
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    final link = Uri.parse('http://audio.test/g.mp4');
    final first = fetches.fetch('ytmusic:g', link);
    await first.whole();
    expect(identical(fetches.fetch('ytmusic:g', link), first), isTrue, reason: 'its file is there: the same fetch');
    cache.path('ytmusic:g').deleteSync(); // the player's: a file that would not play
    host.asked.clear();
    final again = fetches.fetch('ytmusic:g', link);
    await again.whole();
    expect(identical(again, first), isFalse);
    expect(host.asked, isNotEmpty);
    expect(cache.peek('ytmusic:g'), isNotNull);
  });

  test('with the cache off, the song just fetched stays until the next one is fetched', () async {
    cache.limitMB = 0; // Windows still fetches a YouTube copy whole to play it
    host.files['/a.mp4'] = blob(3000);
    host.files['/b.mp4'] = blob(3000);
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    await fetches.fetch('youtube:a', Uri.parse('http://audio.test/a.mp4')).whole();
    expect(cache.path('youtube:a').existsSync(), isTrue);
    await fetches.fetch('youtube:b', Uri.parse('http://audio.test/b.mp4')).whole();
    expect((cache.path('youtube:a').existsSync(), cache.path('youtube:b').existsSync()), (false, true));
    expect(cache.file('youtube:b'), isNull, reason: 'off: never played from the cache');
  });

  test('a fetch whose song is no longer playing or next is cancelled and leaves no file', () async {
    host.files['/c.mp4'] = blob(3000);
    final release = Completer<void>();
    host.hold['/c.mp4'] = release.future;
    final fetches = AudioDownloads(cache: cache, fetcher: quick(host));
    final d = fetches.fetch('jiosaavn:c', Uri.parse('http://audio.test/c.mp4'))..start();
    fetches.keep({'jiosaavn:other'});
    release.complete();
    await d.whole();
    expect(d.isComplete, isFalse);
    expect(cache.peek('jiosaavn:c'), isNull);
  });

  test('a download falls back to the next copy when the first cannot be fetched, and keeps the cover', () async {
    host.files['/second.mp4'] = blob(5000);
    final first = song('ytmusic', 'bad'), second = song('jiosaavn', 'second');
    final track = Track(first, [first, second], image: 'http://img.test/cover.jpg', choosingVersion: false);
    final store = DownloadStore(
      cache: cache,
      fetches: AudioDownloads(cache: cache, fetcher: quick(host)),
      fetcher: quick(host),
      linkFor: (l) async => Uri.parse('http://audio.test/${l.id == 'bad' ? 'missing' : 'second'}.mp4'),
      client: MockClient((r) async => r.url.host == 'img.test' ? http.Response.bytes(blob(700), 200) : http.Response('', 404)),
    );
    await store.load(Directory('${dir.path}/Downloads'));
    expect(await store.download(track), isTrue);
    expect(store.keptCover('http://img.test/cover.jpg')?.readAsBytesSync(), blob(700), reason: 'the cover is kept: it shows offline');
    await store.keepLyrics(track, Lyrics('lrclib', true, [LyricLine(1000, 'a line', translation: 'una línea')]));
    final lyrics = await store.keptLyrics(track);
    expect((lyrics?.source, lyrics?.lines.single.text, lyrics?.lines.single.translation), ('lrclib', 'a line', 'una línea'));
    expect(store.items.single.key, 'jiosaavn:second');
    expect(store.isDownloaded(track), isTrue);
    expect(store.fileFor(track)!.readAsBytesSync(), blob(5000));
    expect(store.items.single.track.image, 'http://img.test/cover.jpg');
    // the list survives a restart with no server
    final again = DownloadStore(cache: cache);
    await again.load(Directory('${dir.path}/Downloads'));
    expect(again.items.single.track.title, 'Song bad', reason: 'the song as shown, not the copy that was fetched');
    final kept = again.keptCover('http://img.test/cover.jpg');
    expect(kept, isNotNull, reason: 'a restart finds the kept cover');
    await again.remove(track);
    expect(again.isDownloaded(track), isFalse);
    expect((kept!.existsSync(), again.keptCover('http://img.test/cover.jpg')), (false, null), reason: 'removed with the song');
  });

  test('a download copies from the cache when the song is there, without fetching', () async {
    put('jiosaavn:hit', 4000, DateTime(2020));
    final l = song('jiosaavn', 'hit');
    final store = DownloadStore(cache: cache, fetches: AudioDownloads(cache: cache, fetcher: quick(host)), fetcher: quick(host));
    await store.load(Directory('${dir.path}/Downloads'));
    expect(await store.download(Track(l, [l], choosingVersion: false)), isTrue);
    expect(host.asked, isEmpty);
  });

  test('the loopback server answers the player\'s byte ranges from a fetch in progress', () async {
    final data = blob(600000);
    host.files['/l.mp4'] = data;
    final d = AudioDownloads(cache: cache, fetcher: quick(host)).fetch('jiosaavn:l', Uri.parse('http://audio.test/l.mp4'));
    final uri = await LoopbackAudio.shared.serve(d);
    final client = http.Client();
    final ranged = await client.send(http.Request('GET', uri)..headers['range'] = 'bytes=1000-299999');
    expect(ranged.statusCode, 206);
    expect(ranged.headers['content-range'], 'bytes 1000-299999/600000');
    expect(await ranged.stream.toBytes(), data.sublist(1000, 300000));
    final all = await client.get(uri);
    expect(all.statusCode, 200);
    expect(all.bodyBytes, data);
    client.close();
  });
}
