// Now Playing's text reads on the cover behind it whatever the cover (#20), by the Mac's rule: made-up covers, very
// bright, very dark, half and half, a checkerboard, vivid and pale, in both themes, as a computer and a phone show
// them. Every pixel of the backdrop as kept, and every blend of two neighbours (the picture is stretched with
// smoothing), must give every kind of text WCAG AA: 4.5:1 for text, 3:1 for the large lyrics and symbols; and the
// accent's text the same on every one. Before, a white cover in the dark theme left the title at 2.0:1. Then Now Playing itself: its
// secondary text is drawn at the level that reads, and its artists in the accent made readable on what is behind.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/theme.dart';

const side = 64; // the backdrop's picture is 64 × 64

/// A made-up cover as the backdrop has it: RGBA, opaque, `colour(x, y)` at each pixel.
Uint8List cover(int Function(int x, int y) colour) {
  final out = Uint8List(side * side * 4);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final c = colour(x, y), i = (y * side + x) * 4;
      out[i] = c >> 16 & 0xFF;
      out[i + 1] = c >> 8 & 0xFF;
      out[i + 2] = c & 0xFF;
      out[i + 3] = 255;
    }
  }
  return out;
}

final covers = <String, Uint8List>{
  'white': cover((_, _) => 0xFFFFFF),
  'yellow': cover((_, _) => 0xFFE14D),
  'neon green': cover((_, _) => 0x00FF66),
  'black': cover((_, _) => 0x000000),
  'navy': cover((_, _) => 0x0A1236),
  'grey': cover((_, _) => 0x808080),
  'half white, half black': cover((_, y) => y < side / 2 ? 0xFFFFFF : 0x000000),
  'checkerboard': cover((x, y) => (x ~/ 8 + y ~/ 8).isEven ? 0xFFFFFF : 0x000000),
  'vivid': cover((x, y) => const [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF, 0xFF8000, 0x8000FF][(x ~/ 8 + y ~/ 8 * 3) % 8]),
  'pastel': cover((x, y) => const [0xF6D8E4, 0xD8EEF6, 0xF6F0D8, 0xE4D8F6][(x ~/ 16 + y ~/ 16) % 4]),
};

Color pixel(Uint8List p, int i) => Color.fromARGB(255, p[i * 4], p[i * 4 + 1], p[i * 4 + 2]);

void main() {
  for (final brightness in Brightness.values) {
    final theme = buildTheme(brightness, null);
    final dark = brightness == Brightness.dark;
    // Now Playing's cover opacity, under the thinnest part of its veil (now_playing.dart)
    for (final (where, share) in [('a computer', (dark ? 0.78 : 0.55) * (1 - 0.18)), ('a phone', (dark ? 0.55 : 0.4) * (1 - 0.35))]) {
      final ink = NowPlayingInk(theme, share: share);
      for (final MapEntry(key: name, value: pixels) in covers.entries) {
        test('$name, ${brightness.name} theme, on $where: every kind of text and the accent read on every pixel', () {
          final kept = ink.keep(pixels);
          // each pixel, and the blend of each with its right and lower neighbour, as it shows behind the text
          final shown = <Color>[];
          for (var i = 0; i < side * side; i++) {
            final c = pixel(kept, i);
            shown.add(ink.shown(c));
            if (i % side < side - 1) shown.add(ink.shown(Color.lerp(c, pixel(kept, i + 1), 0.5)!));
            if (i ~/ side < side - 1) shown.add(ink.shown(Color.lerp(c, pixel(kept, i + side), 0.5)!));
          }
          for (final (alpha, target) in NowPlayingInk.roles) {
            final worst = shown.map((b) => NowPlayingInk.contrast(Color.alphaBlend(ink.ink.withValues(alpha: alpha), b), b)).reduce((a, b) => a < b ? a : b);
            expect(worst, greaterThanOrEqualTo(target), reason: 'text at ${(alpha * 100).round()}%: ${worst.toStringAsFixed(2)}:1');
          }
          final behind = [for (var i = 0; i < side * side; i += 37) ink.shown(pixel(kept, i))];
          for (final accent in [theme.colorScheme.primary, buildTheme(brightness, const Color(0xFF1DB954)).colorScheme.primary,
              const Color(0xFFFFD60A), const Color(0xFF1C1C1E)]) {
            final made = ink.readable(accent, behind);
            final asText = shown.map((b) => NowPlayingInk.contrast(made, b)).reduce((a, b) => a < b ? a : b);
            final unlit = shown
                .map((b) => NowPlayingInk.contrast(Color.alphaBlend(made.withValues(alpha: NowPlayingInk.unlit), b), b))
                .reduce((a, b) => a < b ? a : b);
            expect(asText, greaterThanOrEqualTo(NowPlayingInk.text), reason: 'the accent $accent as text');
            expect(unlit, greaterThanOrEqualTo(NowPlayingInk.large), reason: 'the accent $accent as an unlit noted lyric');
          }
        });
      }
    }
  }

  test('before: on a white cover in the dark theme, and a black one in the light, the text did not read', () {
    for (final (brightness, colour) in [(Brightness.dark, Colors.white), (Brightness.light, Colors.black)]) {
      final theme = buildTheme(brightness, null);
      final ink = NowPlayingInk(theme, share: (brightness == Brightness.dark ? 0.78 : 0.55) * (1 - 0.18));
      final before = ink.shown(colour);
      expect(ink.reads(before), isFalse);
      expect(ink.reads(ink.shown(ink.kept(colour))), isTrue);
    }
  });

  testWidgets('Now Playing draws its secondary text at the level that reads, and its artists in the readable accent', (tester) async {
    const size = Size(1280, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final track = Track(const Listing(source: 'jiosaavn', id: 'np', title: 'Superstar', artists: ['Dox'], duration: 245,
        album: 'An Album', image: 'https://example.invalid/cover.jpg'), const []);
    final player = Player()
      ..panel = 'none'
      ..queue.load([track], 0, shuffled: false);
    addTearDown(player.dispose);
    final theme = buildTheme(Brightness.dark, null);
    final ink = NowPlayingInk(theme, share: 0.78 * (1 - 0.18));
    // what a white cover leaves behind the text: the accent must be made readable on it
    NowPlayingInk.behind.value = [ink.shown(ink.kept(Colors.white))];
    addTearDown(() => NowPlayingInk.behind.value = const []);
    await tester.pumpWidget(Scope(
      player: player,
      library: Library(),
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(theme: theme, home: const Scaffold(body: NowPlaying())),
    ));
    await tester.pump(const Duration(seconds: 1));
    Color colour(Finder f) => tester.renderObject<RenderParagraph>(f).text.style!.color!;
    expect(colour(find.text('NOW PLAYING')).a, closeTo(NowPlayingInk.secondary, 0.01));
    expect(colour(find.textContaining('JioSaavn')).a, closeTo(NowPlayingInk.secondary, 0.01), reason: 'the copy playing');
    final artists = tester.renderObject<RenderParagraph>(find.textContaining('Dox', findRichText: true)).text.style!.color!;
    expect(artists, ink.readable(theme.colorScheme.primary, NowPlayingInk.behind.value));
    expect(NowPlayingInk.contrast(artists, NowPlayingInk.behind.value.single), greaterThanOrEqualTo(NowPlayingInk.text));
  });
}
