// A song's title, its artists and its times stay on one line wherever they are shown (Now Playing, the player bar, a
// song list, Home), short or long, on a phone or a computer, at the usual text size and at 140% and 200% (#20: "titles
// and artist names don't scale well, and overflow to next line without reason, e.g. Superstar by Dox"). Measured with
// Roboto, Android's own font, which Flutter ships: the test font draws every letter as a square 1 em wide, about twice
// a real font's figures, and would wrap what a real font fits.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/home.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/player_bar.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/screens.dart';
import 'package:nononsense/ui/theme.dart';

Track song(String title, List<String> artists, String id) =>
    Track(Listing(source: 'jiosaavn', id: id, title: title, artists: artists, duration: 245, album: 'An Album'), const []);

final superstar = song('Superstar', ['Dox'], 's1');
final long = song('A Song With a Rather Long Title, Longer Than Any Row', ['Some Artist', 'Another One', 'A Third'], 's2');

/// How many lines a paragraph is laid out on.
int lines(RenderParagraph p) {
  final text = p.text.toPlainText();
  final boxes = p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length));
  return boxes.map((b) => b.top.round()).toSet().length;
}

/// Roboto under the names the theme asks for (Segoe UI Variable on Windows), so text is measured as a real font sets it.
Future<void> loadRoboto() async {
  final fonts = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  for (final family in ['Roboto', 'Segoe UI Variable Text', 'Segoe UI Variable Display']) {
    final loader = FontLoader(family);
    for (final weight in ['regular', 'medium', 'bold', 'black']) {
      final titleWeight = '${weight[0].toUpperCase()}${weight.substring(1)}';
      final file = File('$fonts/roboto-$weight.ttf').existsSync()
          ? File('$fonts/roboto-$weight.ttf')
          : File('$fonts/Roboto-$titleWeight.ttf');
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(loadRoboto);

  Future<void> show(WidgetTester tester, Widget page, Size size, double scale) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = Player()
      ..panel = 'none'
      ..queue.load([superstar, long], 0, shuffled: false);
    addTearDown(player.dispose);
    final library = Library()
      ..liked = [LibrarySong('l1', superstar), LibrarySong('l2', long)]
      ..recent = [LibrarySong('r1', superstar), LibrarySong('r2', long)];
    await tester.pumpWidget(Scope(
      player: player,
      library: library,
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, null),
        home: MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)), child: Scaffold(body: page)),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  for (final (where, size) in [
    ('a 360-point phone', const Size(360, 740)),
    ('a 412-point phone', const Size(412, 915)),
    ('a phone on its side', const Size(844, 390)),
    ('a computer', const Size(1280, 800)),
  ]) {
    for (final scale in [1.0, 1.4, 2.0]) {
      for (final (surface, page) in <(String, Widget Function())>[
        ('Now Playing', () => const NowPlaying()),
        ('the player bar', () => const Align(alignment: Alignment.bottomCenter, child: PlayerBar())),
        ('Liked Songs', () => const SongListScreen(liked: true)),
        ('Home', () => Home(openPlaylist: (_) {})),
      ]) {
        testWidgets('$surface on $where at text size $scale: titles, artists and times on one line', (tester) async {
          await show(tester, page(), size, scale);
          expect(tester.takeException(), isNull, reason: 'nothing overflows its box');
          final wrapped = <String>[];
          for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) {
            final text = p.text.toPlainText();
            final watched = [superstar, long].any((t) => text == t.title || text == t.artistLine) || RegExp(r'^-?\d+:\d\d$').hasMatch(text);
            if (watched && lines(p) > 1) wrapped.add('"$text" on ${lines(p)} lines in ${p.size.width.round()} points');
          }
          expect(wrapped, isEmpty);
        });
      }
    }
  }

  // the report: on a phone, Now Playing put "Superstar" on two lines though the row had room for it. The title had half
  // the room the buttons left: a Spacer beside it took the other half
  for (final width in [360.0, 412.0]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets('Now Playing on a $width-point phone at text size $scale: "Superstar" is whole, on one line', (tester) async {
        await show(tester, const NowPlaying(), Size(width, 800), scale);
        final title = tester.renderObject<RenderParagraph>(find.text('Superstar'));
        expect(lines(title), 1);
        expect(title.didExceedMaxLines, isFalse, reason: 'not cut short: ${title.size.width.round()} points for it');
      });
    }
  }
}
