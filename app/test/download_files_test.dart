// Downloads as files (15 Oct): the folder holds only the songs' audio, each named after its song; the list, covers and
// lyrics are the app's own. Downloads from before move their details out and take their songs' names, and a chosen
// folder moves them all.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/download_store.dart';
import 'package:nononsense/core/models.dart';

Listing listing(String id, String title, [String artist = 'Alex']) =>
    Listing(source: 'jiosaavn', id: id, title: title, artists: [artist], duration: 200);
Track track(Listing l) => Track(l, [l], image: 'http://img.test/${l.id}.jpg', choosingVersion: false);
List<String> names(Directory d) => [for (final f in d.listSync()) f.uri.pathSegments.last]..sort();

void main() {
  late Directory dir, folder, data;
  late AudioCache cache;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('download_files');
    folder = Directory('${dir.path}/Downloads');
    data = Directory('${dir.path}/DownloadData');
    cache = AudioCache(Directory('${dir.path}/Audio')..createSync());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  DownloadStore store() => DownloadStore(
        cache: cache,
        client: MockClient((r) async => http.Response.bytes([1, 2, 3], 200)), // covers
      );
  /// In the cache, so a download copies it with no fetch.
  void cached(Listing l) => cache.path(l.key).writeAsBytesSync([for (var i = 0; i < 1000; i++) i % 251]);

  test('a file name is the song title, with what Windows forbids swapped for look-alikes', () {
    expect(DownloadStore.fileTitle('Blinding Lights'), 'Blinding Lights');
    expect(DownloadStore.fileTitle('Who Am I?'), 'Who Am I？');
    expect(DownloadStore.fileTitle('AC/DC: "Live" | *1991*'), 'AC⧸DC： ＂Live＂ ｜ ＊1991＊');
    expect(DownloadStore.fileTitle('  Hello,   Goodbye  '), 'Hello, Goodbye');
    expect(DownloadStore.fileTitle('Mr.'), 'Mr', reason: 'Windows drops a final dot');
    expect(DownloadStore.fileTitle('CON'), 'CON (song)', reason: 'a device name on Windows');
    expect(DownloadStore.fileTitle('...'), 'Song');
    expect(DownloadStore.fileTitle('a' * 300).length, 120);
  });

  test('a download puts only its audio in the folder, named after the song; same titles get their artists', () async {
    final s = store();
    await s.load(at: folder, data: data);
    final a = listing('a', 'Heartless', 'Kanye West'), b = listing('b', 'Heartless', 'The Weeknd');
    cached(a);
    cached(b);
    expect(await s.download(track(a)), isTrue);
    expect(await s.download(track(b)), isTrue);
    expect(names(folder), ['Heartless - The Weeknd.m4a', 'Heartless.m4a'], reason: 'only audio: no list, cover or lyrics');
    expect(s.fileFor(track(a))!.path, endsWith('Heartless.m4a'));
    await s.keepLyrics(track(a), Lyrics('lrclib', false, [LyricLine(0, 'a line')]));
    expect(names(data), ['index.json', 'jiosaavn_a.cover', 'jiosaavn_a.lyrics.json', 'jiosaavn_b.cover']);
    // the list survives a restart
    final again = store();
    await again.load(at: folder, data: data);
    expect([for (final i in again.items) i.file], ['Heartless - The Weeknd.m4a', 'Heartless.m4a']);
    expect((await again.keptLyrics(track(a)))?.lines.single.text, 'a line');
    expect(again.keptCover('http://img.test/a.jpg'), isNotNull);
    await again.remove(track(a));
    expect(names(folder), ['Heartless - The Weeknd.m4a']);
    expect(names(data), ['index.json', 'jiosaavn_b.cover'], reason: 'its cover and lyrics go with it');
  });

  test('downloads from before 15 Oct move their details out and take their songs\' names', () async {
    folder.createSync();
    final a = listing('a', 'Blinding Lights', 'The Weeknd'), b = listing('b', 'Who Am I?');
    final old = [
      for (final l in [a, b])
        DownloadItem(key: l.key, file: 'jiosaavn-${l.id}.m4a', best: l, listings: [l], image: 'http://img.test/${l.id}.jpg',
            bytes: 3, added: DateTime(2026, 10, 12)),
    ];
    File('${folder.path}/index.json').writeAsStringSync(jsonEncode([for (final i in old) i.toJson()]));
    for (final i in old) {
      File('${folder.path}/${i.file}').writeAsBytesSync([1, 2, 3]);
      File('${folder.path}/${i.file}.cover').writeAsBytesSync([9]);
    }
    File('${folder.path}/jiosaavn-a.m4a.lyrics.json')
        .writeAsStringSync(jsonEncode(Lyrics('lrclib', false, [LyricLine(0, 'kept')]).toJson()));
    // a song whose audio was removed by hand left its details behind
    File('${folder.path}/jiosaavn-gone.m4a.cover').writeAsBytesSync([9]);
    File('${folder.path}/jiosaavn-gone.m4a.lyrics.json').writeAsStringSync('{}');
    final s = store();
    await s.load(at: folder, data: data);
    expect(names(folder), ['Blinding Lights.m4a', 'Who Am I？.m4a']);
    expect(names(data), ['index.json', 'jiosaavn_a.cover', 'jiosaavn_a.lyrics.json', 'jiosaavn_b.cover']);
    expect(s.items.length, 2);
    expect(s.fileFor(track(a))!.readAsBytesSync(), [1, 2, 3]);
    expect((await s.keptLyrics(track(a)))?.lines.single.text, 'kept');
    expect(s.keptCover('http://img.test/b.jpg')?.readAsBytesSync(), [9]);
    // once: a second start finds it done
    final again = store();
    await again.load(at: folder, data: data);
    expect([for (final i in again.items) i.file], ['Blinding Lights.m4a', 'Who Am I？.m4a']);
  });

  test('a chosen folder takes every download, and Use Default brings them back', () async {
    final s = store();
    await s.load(at: folder, data: data);
    final a = listing('a', 'Song A'), b = listing('b', 'Song B');
    cached(a);
    cached(b);
    await s.download(track(a));
    await s.download(track(b));
    final music = Directory('${dir.path}/Music');
    await s.moveTo(music);
    expect(names(music), ['Song A.m4a', 'Song B.m4a']);
    expect(names(folder), isEmpty);
    expect(s.fileFor(track(a))!.existsSync(), isTrue);
    final again = store();
    await again.load(at: music, data: data);
    expect(again.items.length, 2, reason: 'the list follows the files');
    await again.moveTo(folder);
    expect(names(folder), ['Song A.m4a', 'Song B.m4a']);
  });

  test('a chosen folder that is not there leaves downloads off and the list as it was', () async {
    final s = store();
    await s.load(at: folder, data: data);
    final a = listing('a', 'Song A');
    cached(a);
    await s.download(track(a));
    final index = File('${data.path}/index.json').readAsStringSync();
    final blocked = File('${dir.path}/not a folder')..writeAsStringSync('');
    final gone = store();
    await gone.load(at: Directory('${blocked.path}/Music'), data: data); // as a drive unplugged: it cannot be made
    expect((gone.folder, gone.missingFolder?.path), (null, '${blocked.path}/Music'));
    expect(gone.items, isEmpty);
    expect(await gone.download(track(a)), isFalse);
    expect(File('${data.path}/index.json').readAsStringSync(), index, reason: 'its songs are not dropped');
  });
}
