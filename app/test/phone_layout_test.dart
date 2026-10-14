// A phone's screens with made-up data, at two phone sizes, two text sizes and both themes: they build without a
// RenderFlex overflow, and each screen's heading and rows start on the same gutter. The backdrop is opaque: a
// see-through one drew as black on Android, under the light theme's dark text (13 Oct).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/glass.dart';
import 'package:nononsense/ui/home.dart';
import 'package:nononsense/ui/layout.dart';
import 'package:nononsense/ui/playlist_screen.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/screens.dart';
import 'package:nononsense/ui/song_row.dart';
import 'package:nononsense/ui/theme.dart';

Track song(int i) => Track(
    Listing(source: 'jiosaavn', id: 'id$i', title: 'A fairly long song title number $i', artists: const ['Alex', 'Sam'], duration: 180 + i),
    const []);

/// A library with songs played and liked, two playlists of the user's own and one shared with them.
Library library() {
  final own = PlaylistSummary('p1', 'A playlist with a rather long name', 6, 1200);
  return Library()
    ..recent = [for (var i = 0; i < 8; i++) LibrarySong('r$i', song(i))]
    ..liked = [for (var i = 0; i < 30; i++) LibrarySong('l$i', song(i))]
    ..playlists = [own, PlaylistSummary('p2', 'Mix', 3, 600), PlaylistSummary('p3', 'Theirs', 4, 800, role: 'viewer')]
    ..details['p1'] = PlaylistDetail(own, [for (var i = 0; i < 6; i++) ('item$i', song(i))]);
}

Widget app(Widget page, Brightness brightness) => Scope(
      player: Player(),
      library: library(),
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(theme: buildTheme(brightness, const Color(0xFF1DB954)), home: Scaffold(body: page)),
    );

void main() {
  for (final size in [const Size(360, 740), const Size(390, 844)]) {
    for (final scale in [1.0, 1.4]) {
      for (final brightness in Brightness.values) {
        final at = '${size.width.toInt()}x${size.height.toInt()}, text size $scale, ${brightness.name}';
        Future<void> show(WidgetTester tester, Widget page) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
              MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)), child: app(page, brightness)));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        testWidgets('Home builds at $at, and its shelf scrolls to the edge', (tester) async {
          await show(tester, Home(openPlaylist: (_) {}));
          expect(tester.getTopLeft(find.textContaining('Good ')).dx, 20, reason: 'the greeting stands on the gutter');
          expect(tester.getTopLeft(find.text('Jump back in')).dx, 20);
          final shelf = find.ancestor(of: find.textContaining('number 0').first, matching: find.byType(ListView)).first;
          expect(tester.getSize(shelf).width, size.width, reason: 'the shelf is as wide as the window: its cards are not cut off at the gutter');
          await tester.scrollUntilVisible(find.text('Liked Songs'), 300, scrollable: find.byType(Scrollable).first);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Liked Songs builds at $at, its rows on the gutter', (tester) async {
          await show(tester, const SongListScreen(liked: true));
          expect(tester.getTopLeft(find.text('Liked Songs')).dx, 20);
          expect(tester.getTopLeft(find.byType(SongRow).first).dx, 20, reason: 'a row is a card: its edge is under the heading');
          final extent = songRowExtent(tester.element(find.byType(SongRow).first));
          expect(tester.getSize(find.byType(SongRow).first).height, extent);
          final card = find.descendant(of: find.byType(SongRow).first, matching: find.byType(Container)).first;
          expect(tester.getSize(card).height, extent - 8, reason: 'the card leaves 8 of its extent as the gap to the next one');
        });

        testWidgets('a playlist builds at $at, the cover above its name', (tester) async {
          await show(tester, PlaylistScreen(id: 'p1', onDeleted: () {}));
          final name = find.text('A playlist with a rather long name');
          expect(tester.getTopLeft(name).dx, 20, reason: 'the name has the width, not the 150 left beside the cover');
          expect(tester.getTopLeft(name).dy, greaterThan(tester.getBottomLeft(find.byType(PlaylistCover)).dy));
          expect(find.byType(SongRow), findsWidgets);
        });
      }
    }
  }

  testWidgets('a desktop window keeps its own gutter and the cover beside the name', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(PlaylistScreen(id: 'p1', onDeleted: () {}), Brightness.light));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final name = find.text('A playlist with a rather long name');
    expect(tester.getTopLeft(find.byType(PlaylistCover)).dx, 32);
    expect(tester.getTopLeft(name).dx, 32 + 172 + 22);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the phone backdrop is opaque in the ${brightness.name} theme', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(brightness, const Color(0xFF1DB954)), home: const PhoneBackdrop()));
      final box = tester.widget<DecoratedBox>(find.descendant(of: find.byType(PhoneBackdrop), matching: find.byType(DecoratedBox)));
      final colors = ((box.decoration as BoxDecoration).gradient! as LinearGradient).colors;
      expect(colors.map((c) => c.a), everyElement(1.0));
      // the ink the theme writes with against every stop of the backdrop: at least 4.5 to 1
      final ink = buildTheme(brightness, null).colorScheme.onSurface;
      for (final c in colors) {
        final (a, b) = (ink.computeLuminance(), c.computeLuminance());
        final ratio = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
        expect(ratio, greaterThan(4.5), reason: 'text on $c');
      }
    });
  }
}
