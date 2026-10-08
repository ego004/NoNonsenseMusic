// Drives the whole app from inside (no system input: it runs while you use the Mac) against a TEST server:
//   flutter test integration_test -d macos --dart-define=SERVER=http://127.0.0.1:8765
// Search, play the first result, Now Playing with Up Next, Add to Queue. Saves pictures of the app as it draws
// itself to $NN_SNAPS (default: the system temp folder). Muted.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/main.dart';
import 'package:nononsense/ui/song_row.dart';

final shot = GlobalKey();

/// The app as it draws itself now (its own layer tree, not the screen), into the app's container.
Future<void> snap(WidgetTester tester, String name) async {
  final folder = Directory.systemTemp.path; // the app's own container: the Mac sandbox allows no other folder
  await tester.pump(const Duration(milliseconds: 300));
  final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  File('$folder/flutter-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  debugPrint('SNAP $folder/flutter-$name.png');
}

Future<void> until(WidgetTester tester, bool Function() done, {int seconds = 20}) async {
  for (var i = 0; i < seconds * 4 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home, search, play, Now Playing (Up Next, lyrics), Add to Queue, a playlist', (tester) async {
      final settings = Settings();
    await settings.load();
    expect(Api.base, isNot(contains(':8000')), reason: 'a test runs only against a test server, never your library');
    final player = Player()..setVolume(0);
    final library = Library()..playlistChanged = player.playlistChanged;
    final lyrics = LyricsStore();
    // a fresh test account, signed in before the window opens (AUTH-1): the app opens on Home, not the sign-in screen
    final auth = Auth(store: MemoryTokenStore());
    final error = await auth.signIn('test-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}', 'a test password', create: true);
    expect(error, isNull, reason: 'signed up on the test server');
    await tester.pumpWidget(RepaintBoundary(key: shot, child: NoNonsenseApp(player: player, library: library, lyrics: lyrics, settings: settings, auth: auth)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Good '), findsOneWidget, reason: 'the app opens on Home');
    await snap(tester, 'home');

    await tester.tap(find.text('Search'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'arijit singh');
    await until(tester, () => find.byType(SongRow).evaluate().length > 3);
    expect(find.byType(SongRow), findsWidgets);
    await snap(tester, 'search');

    // a double-click on the first row plays it, with the results as the queue
    final first = find.byType(SongRow).first;
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(first);
    await until(tester, () => player.isPlaying && player.duration > 10, seconds: 25);
    expect(player.isPlaying, isTrue, reason: 'the first result plays');
    expect(player.queue.upNext.length, greaterThan(2));
    await tester.pump(const Duration(seconds: 2));
    await snap(tester, 'playing');

    // the controls show their state (8 Oct: ▶ stayed ▶, shuffle and repeat never lit up)
    expect(find.byTooltip('Pause'), findsWidgets, reason: 'playing: the disc shows pause');
    await tester.tap(find.byTooltip('Pause').first);
    await until(tester, () => !player.isPlaying, seconds: 5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Play'), findsWidgets, reason: 'paused: the disc shows play');
    await tester.tap(find.byTooltip('Play').first);
    await until(tester, () => player.isPlaying, seconds: 8);
    await tester.tap(find.byTooltip('Shuffle').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Shuffle is on'), findsWidgets);
    await tester.tap(find.byTooltip('Shuffle is on').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Repeat').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Repeating the queue'), findsWidgets);
    await tester.tap(find.byTooltip('Repeating the queue').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Repeating this song').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Repeat'), findsWidgets, reason: 'off → all → one → off');

    // Add to Queue: the end of Up Next
    final extra = player.queue.upNext[1];
    player.addToQueue(extra);
    expect(player.queue.upNext.last.id, extra.id);

    player.setShowNowPlaying(true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Up Next'), findsWidgets);
    await snap(tester, 'now-playing');

    // lyrics beside the song: found (or "Couldn't find lyrics"), never stuck on "Finding lyrics…"
    player.setPanel('lyrics');
    await until(tester, () => lyrics.of(player.current!) != null, seconds: 15);
    await tester.pump(const Duration(seconds: 1));
    final found = lyrics.of(player.current!);
    expect(found, isNotNull, reason: 'the server answered for lyrics');
    debugPrint('LYRICS ${found!.lines.length} lines, synced ${found.synced}, from ${found.sourceName}');
    await snap(tester, 'lyrics');
    player.setPanel('upNext');
    player.setShowNowPlaying(false);
    await tester.pump(const Duration(milliseconds: 400));

    // a playlist: made, filled with 3 songs, opened, its rows in order; then deleted
    final name = 'Flutter test ${DateTime.now().millisecondsSinceEpoch % 10000}';
    expect(await library.createPlaylist(name), isNull);
    final id = library.playlists.firstWhere((p) => p.name == name).id;
    final three = player.queue.tracks.take(3).toList();
    for (final t in three) {
      await library.add(t, id);
    }
    await tester.pump(const Duration(milliseconds: 300)); // the sidebar shows it
    await tester.tap(find.text(name));
    await until(tester, () => find.byType(SongRow).evaluate().length == 3);
    // titles: the server keeps a song with its own best copy, which can differ from the search's
    expect(library.details[id]!.tracks.map((t) => t.title), three.map((t) => t.title));
    await snap(tester, 'playlist');
    await library.moveItem(id, 2, 0);
    await library.loadPlaylist(id);
    expect(library.details[id]!.tracks.first.title, three[2].title, reason: 'a move reaches the server');
    await library.deletePlaylist(id);
    expect(library.playlists.any((p) => p.id == id), isFalse);
    player.togglePlayPause();
    await tester.pump(const Duration(milliseconds: 500));

    // a YouTube copy, looked up by this device (YouTubeLookup, 8 Oct): on the Mac build these failed with just_audio's
    // -1 when the server's link was played
    const yt = Listing(source: 'ytmusic', id: 'J7p4bzqLvCw', title: 'Blinding Lights', artists: ['The Weeknd'], duration: 200);
    await player.play([Track(yt, const [yt])]);
    await until(tester, () => player.position > 3, seconds: 20);
    expect(player.position, greaterThan(3), reason: 'a YouTube song plays in the app');
    expect(player.current?.title, 'Blinding Lights', reason: 'the YouTube copy itself, not a fallback song');
    player.togglePlayPause();

    // Settings, from the sidebar's bottom item: its sections are on screen, inside the window (8 Oct: "couldn't see")
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    final window = tester.getRect(find.byKey(shot));
    for (final label in ['Account', 'Device Name', 'Server']) {
      final found = find.text(label);
      expect(found, findsWidgets, reason: '"$label" in Settings');
      final r = tester.getRect(found.first);
      expect(window.contains(r.center), isTrue, reason: '"$label" at $r, inside the window $window');
    }
    await snap(tester, 'settings');
  });
}
