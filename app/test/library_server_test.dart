// The library against a TEST server, no window needed (runs while you use the Mac):
//   flutter test test/library_server_test.dart --dart-define=SERVER=http://127.0.0.1:8765
// Skipped without SERVER. Never against port 8000 (your library).
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/play_queue.dart';

import 'test_account.dart';

const server = String.fromEnvironment('SERVER');

void main() {
  final skip = server.isEmpty || server.contains(':8000') ? 'needs --dart-define=SERVER=<a test server>' : null;
  // every route needs a signed-in account (AUTH-1): one fresh test account for these tests
  setUpAll(() async { if (skip == null) await signUpTestAccount(); });

  test('playlists: create, add, open in order, move (the server agrees, a playing queue follows), remove, delete', () async {
    final songs = await Api.search('arijit singh');
    expect(songs.length, greaterThanOrEqualTo(3));
    final three = songs.take(3).toList();
    final library = Library();
    final queue = PlayQueue();
    library.playlistChanged = (d) => queue.sync(d.queueSource, d.items);

    final name = 'Dart test ${DateTime.now().millisecondsSinceEpoch % 100000}';
    expect(await library.createPlaylist(name), isNull);
    expect(await library.createPlaylist(name), contains('already have'), reason: "the server's own reason comes back");
    final id = library.playlists.firstWhere((p) => p.name == name).id;
    for (final t in three) {
      await library.add(t, id);
    }
    final d = library.details[id]!;
    // titles, not ids: the server keeps a song with its own best copy, which can differ from the search's
    List<String> titles(Iterable t) => [for (final x in t) x.title as String];
    expect(titles(d.tracks), titles(three));
    expect(library.playlists.firstWhere((p) => p.id == id).songCount, 3);

    queue.load(d.tracks, 0, keys: d.keys, source: d.queueSource, shuffled: false);
    await library.moveItem(id, 2, 0); // the 3rd song to the top
    final moved = titles([three[2], three[0], three[1]]);
    expect(titles(library.details[id]!.tracks), moved, reason: 'the screen at once');
    expect(titles(queue.tracks), moved, reason: 'the playing queue follows');
    await library.loadPlaylist(id);
    expect(titles(library.details[id]!.tracks), moved, reason: 'the server agrees');

    await library.remove(library.details[id]!.items.last.$1, id);
    await library.loadPlaylist(id);
    expect(library.details[id]!.items.length, 2);

    await library.deletePlaylist(id);
    expect(library.playlists.any((p) => p.id == id), isFalse);
    expect(await library.loadPlaylist(id), isFalse, reason: 'the server says 404');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('like then unlike at once: not liked on the server', () async {
    final library = Library();
    await library.refresh();
    final song = (await Api.search('arijit singh')).firstWhere((t) => !library.isLiked(t));
    final a = library.toggleLike(song);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final b = library.toggleLike(song);
    await Future.wait([a, b]);
    final onServer = (await Api.liked()).any((s) => s.track.listings.any((l) => song.listings.any((m) => m.key == l.key)));
    expect(onServer, isFalse);
    expect(library.isLiked(song), isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
