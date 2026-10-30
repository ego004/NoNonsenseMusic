// When the server does not answer, what you did says so and the screen does not pretend (29 Oct): a like that did not
// happen is not left on the heart, a playlist that was not deleted stays in the list, and each says why.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/models.dart';

import 'fake_http.dart' show FakeServer, useServer;

Track song() {
  final l = Listing(source: 'jiosaavn', id: 'a', title: 'Regardless', artists: const ['Asim Azhar'], duration: 224);
  return Track(l, [l], choosingVersion: false);
}

void main() {
  late Library library;
  late List<String> problems;

  setUp(() {
    problems = [];
    // every request fails as it does with no network
    useServer(FakeServer((method, path, body) async => throw http.ClientException('down')));
    library = Library()..problem = problems.add;
  });

  test('a like the server did not get is taken off the heart, and says so', () async {
    final t = song();
    await library.toggleLike(t);
    await pumpEventQueue();
    expect(library.isLiked(t), isFalse);
    expect(problems.single, startsWith("Couldn't like “Regardless”"));
  });

  test('an unlike the server did not get puts the heart back, and says so', () async {
    final t = song();
    library = Library()..problem = problems.add;
    // a liked song: the heart is on before the call
    useServer(FakeServer((method, path, body) async => (200, {'song_id': 's1'})));
    await library.toggleLike(t);
    await pumpEventQueue();
    expect(library.isLiked(t), isTrue);
    useServer(FakeServer((method, path, body) async => throw http.ClientException('down')));
    await library.toggleLike(t);
    await pumpEventQueue();
    expect(library.isLiked(t), isTrue, reason: 'still liked: the server never heard');
    expect(problems.single, startsWith("Couldn't unlike “Regardless”"));
  });

  test('adding to a playlist that fails says so, naming the playlist', () async {
    library.playlists = [PlaylistSummary('p1', 'Gym', 0, 0)];
    await library.add(song(), 'p1');
    expect(problems.single, startsWith("Couldn't add to “Gym”"));
  });

  test('a playlist the server did not delete stays in the list, and it says so', () async {
    library.playlists = [PlaylistSummary('p1', 'Gym', 0, 0)];
    await library.deletePlaylist('p1');
    expect(library.playlists.map((p) => p.id), ['p1']);
    expect(problems.single, startsWith("Couldn't delete “Gym”"));
  });
}
