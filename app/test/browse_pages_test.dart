// The artist and album pages with made-up data, at a phone's and a desktop window's size: they build without a
// RenderFlex overflow or any other error, and show what the Mac's pages show.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/browse_pages.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/theme.dart';

Track song(int i) => Track(
    Listing(source: i.isEven ? 'jiosaavn' : 'ytmusic', id: 'id$i', title: 'A fairly long song title number $i', artists: const ['Alex', 'Sam'],
        duration: 180 + i, album: 'Made-Up Album'),
    const []);

final albumRef = AlbumRef(source: 'jiosaavn', id: 'b1', title: 'Made-Up Album', artists: const ['Alex', 'Sam'], year: 2024, songCount: 12);

final album = AlbumDetail(
    source: 'jiosaavn', id: 'b1', title: 'Made-Up Album With a Rather Long Title That Wraps', artists: const ['Alex', 'Sam'], year: 2024, songs: [for (var i = 0; i < 12; i++) song(i)]);

final artist = ArtistDetail(
    source: 'jiosaavn', id: 'a1', name: 'Alex With a Long Stage Name Too', monthlyListeners: 1234567, songs: [for (var i = 0; i < 14; i++) song(i)],
    albums: [for (var i = 0; i < 9; i++) AlbumRef(source: 'jiosaavn', id: 'b$i', title: 'Album number $i', year: 2000 + i)]);

Widget app(Widget page) => Scope(
      player: Player(),
      library: Library(),
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(theme: buildTheme(Brightness.dark, null), home: Scaffold(body: page)),
    );

void main() {
  for (final (name, size) in [('a phone', const Size(390, 844)), ('a desktop window', const Size(1280, 800))]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets('the album page builds on $name at text size $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)), child: app(AlbumView(album: album))));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Made-Up Album With'), findsOneWidget);
        expect(find.text('Play'), findsOneWidget);
        expect(find.text('Shuffle'), findsOneWidget);
        expect(find.byTooltip('Keep this album on Home'), findsOneWidget);
        expect(find.text('2024 · 12 SONGS · 37 MIN'), findsOneWidget);
        expect(find.text('1'), findsOneWidget, reason: 'album songs are numbered');
        expect(find.textContaining('Alex, Sam', findRichText: true), findsWidgets, reason: 'the artists are links under the title');
        expect(find.textContaining('number 0'), findsOneWidget);
      });

      testWidgets('the artist page builds on $name at text size $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)), child: app(ArtistView(artist: artist))));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Alex With a Long'), findsOneWidget);
        expect(find.text('1.2M monthly listeners'), findsOneWidget);
        expect(find.text('Top Songs'), findsOneWidget);
        expect(find.text('Play'), findsOneWidget);
        // scrolled to the albums: the grid is lazy and fills the width
        await tester.scrollUntilVisible(find.text('Album number 8'), 400, scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
        expect(find.text('Album number 8'), findsOneWidget);
      });
    }
  }

  test('listener counts are compact', () {
    expect(compactCount(1234567), '1.2M');
    expect(compactCount(950), '950');
    expect(compactCount(12000), '12K');
  });
}
