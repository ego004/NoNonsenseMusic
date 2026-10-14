import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/cover.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/scope.dart';

final track = Track(
  const Listing(
    source: 'ytmusic',
    id: 'layout-test',
    title: 'A Long Song Title That Needs More Than One Line',
    artists: ['An Artist With a Long Name'],
    album: 'An Album With a Long Name',
    duration: 210,
    image: 'https://example.invalid/cover.jpg',
  ),
  const [],
);

Widget screen(Player player, Size size, {double textScale = 1}) => Scope(
  player: player,
  library: Library(),
  lyrics: LyricsStore(),
  settings: Settings(),
  auth: Auth(store: MemoryTokenStore()),
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        padding: size.width > 1000 ? EdgeInsets.zero : const EdgeInsets.only(top: 24, bottom: 24),
        textScaler: TextScaler.linear(textScale),
      ),
      child: const Scaffold(body: NowPlaying()),
    ),
  ),
);

void main() {
  for (final (name, size, textScale) in [
    ('small portrait', const Size(320, 568), 1.0),
    ('portrait', const Size(390, 844), 1.0),
    ('Android emulator portrait', const Size(411, 914), 1.0),
    ('landscape', const Size(844, 390), 1.0),
    ('Android emulator landscape', const Size(914, 411), 1.0),
    ('small landscape', const Size(640, 360), 1.0),
    ('scaled portrait', const Size(320, 568), 1.4),
    ('scaled landscape', const Size(640, 360), 1.4),
    ('Windows', const Size(1280, 800), 1.0),
  ]) {
    testWidgets('artwork and controls fit $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = Player()
        ..panel = 'none'
        ..queue.load([track], 0, shuffled: false);
      addTearDown(player.dispose);

      await tester.pumpWidget(screen(player, size, textScale: textScale));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final artwork = find.byKey(const ValueKey('now-playing-artwork'));
      final close = find.byTooltip('Close (Esc)');
      final lyrics = find.byTooltip('Show Lyrics');
      final queue = find.byTooltip('Show Up Next');
      expect(close, findsOneWidget);
      expect(lyrics, findsOneWidget);
      expect(queue, findsOneWidget);
      expect(tester.getRect(close).right, lessThan(tester.getRect(lyrics).left));
      expect(tester.getRect(lyrics).right, lessThan(tester.getRect(queue).left));

      if (name != 'Windows') {
        expect(artwork, findsOneWidget);
        final cover = tester.getRect(artwork);
        final title = tester.getRect(find.text(track.title));
        expect(cover.width, closeTo(cover.height, 0.01));
        expect(cover.top, greaterThanOrEqualTo(tester.getRect(close).bottom));
        expect(cover.right, lessThanOrEqualTo(size.width));
        expect(cover.bottom, lessThanOrEqualTo(size.height));
        if (size.width > size.height) {
          expect(cover.right, lessThan(title.left));
        } else {
          expect(cover.bottom, lessThan(title.top));
        }
        expect(tester.widget<Cover>(artwork).fit, BoxFit.cover);
      }

      player.setPanel('upNext');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Up Next'), findsWidgets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (name != 'Windows') {
        expect(artwork, findsNothing);
        player.setPanel('none');
        await tester.pumpAndSettle();
        expect(artwork, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets('one click on a song in Up Next plays it (${platform.name})', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const size = Size(1280, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Track song(String id) => Track(Listing(source: 'ytmusic', id: id, title: 'Song $id', artists: const ['A'], album: null, duration: 200), const []);
      final player = Player()
        ..panel = 'upNext'
        ..queue.load([song('1'), song('2'), song('3')], 0, shuffled: false);
      addTearDown(player.dispose);
      await tester.pumpWidget(screen(player, size));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Song 3'));
      await tester.pump(const Duration(milliseconds: 400));         // past a double-tap's wait: one click must be enough
      expect(player.queue.current?.title, 'Song 3');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));                 // the song's load gives up: no timer left behind
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a cover keeps its shape: decoded by height, then filled and cropped (a 16:9 thumbnail was squashed)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Cover('https://example.invalid/cover.jpg', size: 220)),
    ));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect(image.width, 220);
    expect(image.height, 220);
    final decoded = image.image as ResizeImage;
    expect(decoded.width, isNull, reason: 'the width follows the image: a fixed one too would squash a wide image');
    expect(decoded.height, 220 * tester.view.devicePixelRatio);
  });
}
