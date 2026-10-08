// Genius notes (experimental, 8 Oct), without a server: the requests are answered here. Every word is made up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/ui/lyrics_panel.dart';

const notesJson = {
  'url': 'https://genius.example/made-up',
  'notes': [
    {'fragment': 'first made-up line of this song', 'text': 'A made-up note on the first line.', 'verified': true},
    {'fragment': 'DONT stop the made up music\nand a line that is not here', 'text': 'A note across two lines.', 'verified': false},
    {'fragment': 'oh oh', 'text': 'Too short to place.', 'verified': false},
  ],
  'about': {'description': 'A song made up for this test.', 'produced_by': ['Alex'], 'samples': []},
};

void main() {
  tearDown(() {
    Api.client = http.Client();
    LyricsStore.genius = false;
  });

  test('each note lands on its line: case, accents, apostrophes and punctuation ignored; short ones nowhere', () {
    final lines = ['First made-up line of this song', 'nothing to say about this one', 'Don’t stop the made-up music', 'oh oh', 'the last made-up line']
        .indexed.map((e) => LyricLine(e.$1 * 4000, e.$2)).toList();
    final placed = GeniusNotes.fromJson(notesJson).byLine(lines);
    expect(placed.keys.toList()..sort(), [0, 2]);
    expect(placed[2]!.text, 'A note across two lines.');
  });

  test('Genius is asked only with the setting on, once per song', () async {
    var asked = 0;
    Api.client = MockClient((r) async {
      if (r.url.path == '/genius') asked++;
      return r.url.path == '/genius'
          ? http.Response(jsonEncode(notesJson), 200, headers: {'content-type': 'application/json'})
          : http.Response(jsonEncode({'lyrics_source': null, 'synced': false, 'lines': []}), 200, headers: {'content-type': 'application/json'});
    });
    final song = Track(const Listing(source: 'jiosaavn', id: 'made-up', title: 'Made-Up Song', artists: ['Kai', 'Sam'], duration: 200), const []);
    final store = LyricsStore();
    await store.fetch(song);
    expect((asked, store.notesOf(song)), (0, null), reason: 'off by default: no lookup');

    LyricsStore.genius = true;
    final other = Track(const Listing(source: 'jiosaavn', id: 'made-up-2', title: 'Made-Up Song', artists: ['Kai'], duration: 200), const []);
    await store.fetchNotes(other);
    await store.fetchNotes(other);
    expect(asked, 1, reason: 'once per song');
    expect(store.notesOf(other)!.notes.length, 3);
  });

  testWidgets('a line with a note is underlined; a click opens the note instead of playing; Play from here plays', (tester) async {
    var tapped = 0, played = 0;
    const note = GeniusNote('first made-up line', 'A made-up note.', verified: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      NotedLyricLine(text: 'First made-up line', note: note, url: 'https://genius.example', onTap: () => tapped++, onPlay: () => played++),
      NotedLyricLine(text: 'A line with no note', onTap: () => tapped++),
    ]))));
    expect(tester.widget<Text>(find.text('First made-up line')).style?.decoration, TextDecoration.underline);
    expect(tester.widget<Text>(find.text('A line with no note')).style?.decoration, isNot(TextDecoration.underline));

    await tester.tap(find.text('First made-up line'));
    await tester.pumpAndSettle();
    expect(find.text('A made-up note.'), findsOneWidget);
    expect(find.text('Genius · verified by the artist'), findsOneWidget);
    expect(tapped, 0, reason: 'the note opened; the song did not jump');
    await tester.tap(find.text('Play from here'));
    await tester.pumpAndSettle();
    expect((played, find.text('A made-up note.').evaluate().isEmpty), (1, true));

    await tester.tap(find.text('A line with no note'));
    expect(tapped, 1, reason: 'a line without a note plays from it, as before');
  });
}
