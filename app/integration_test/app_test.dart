// Drives the whole app from inside (no system input: it runs alongside the user) against a test server:
//   flutter test integration_test -d macos --dart-define=SERVER=http://127.0.0.1:8765
// Searches, plays the first result, opens Now Playing with Up Next, adds to the queue, and checks lyrics.
// Writes a picture of the app as it draws itself to $NN_SNAPS (default: the system temp folder). Muted.
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
import 'package:nononsense/ui/layout.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/settings_screen.dart';
import 'package:nononsense/ui/song_row.dart';

final shot = GlobalKey();

/// Writes the app's current layer tree, not the screen, to a PNG in the app's container.
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

/// Pumps the tester until [done] is true or [seconds] elapse.
Future<void> until(WidgetTester tester, bool Function() done, {int seconds = 20}) async {
  for (var i = 0; i < seconds * 4 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home, search, play, Now Playing (Up Next, lyrics), Add to Queue, a playlist', (tester) async {
    // an overflow names its widget while that widget still exists (reported later, the tree was already rebuilt)
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) {
        for (final node in details.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
          final value = node.value;
          if (value is RenderObject && value.debugCreator is DebugCreator) {
            debugPrint('OVERFLOW ${(value.debugCreator as DebugCreator).element.debugGetCreatorChain(12)}');
          }
        }
      }
      reportError?.call(details);
    };
      final settings = Settings();
    await settings.load();
    expect(Api.base, isNot(contains(':8000')), reason: 'a test runs only against a test server, never your library');
    final player = Player()..setVolume(0);
    final library = Library()..playlistChanged = player.playlistChanged;
    final lyrics = LyricsStore();
    // a fresh test account, signed in before the window opens: the app opens on Home, not the sign-in screen
    final auth = Auth(store: MemoryTokenStore());
    final error = await auth.signIn('test-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}', 'a test password', create: true);
    expect(error, isNull, reason: 'signed up on the test server');
    await tester.pumpWidget(RepaintBoundary(key: shot, child: NoNonsenseApp(player: player, library: library, lyrics: lyrics, settings: settings, auth: auth)));
    await tester.pump(const Duration(seconds: 2));
    // a new account's recovery codes come first, and Done unlocks only after Copy
    expect(find.text('Save Your Recovery Codes'), findsOneWidget, reason: 'sign-up shows the recovery codes once');
    await tester.tap(find.text('Copy'));
    // the clipboard is a call into the platform: on the Android emulator it took longer than a fixed 300 ms (13 Oct)
    for (var i = 0; i < 50 && find.text('Copied').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Copied'), findsOneWidget, reason: 'Copy puts the codes on the clipboard and says so: Done waits for it');
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Save Your Recovery Codes'), findsNothing, reason: 'Done closes the codes');
    expect(find.textContaining('Good '), findsOneWidget, reason: 'the app opens on Home');
    await snap(tester, 'home');

    await tester.tap(find.text('Search'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'arijit singh');
    // All puts artists and albums first; the Songs capsule shows songs alone (and asks the server for songs only)
    await until(tester, () => find.text('Songs').evaluate().isNotEmpty);
    await tester.tap(find.text('Songs').first);
    await until(tester, () => find.byType(SongRow).evaluate().length > 3);
    expect(find.byType(SongRow), findsWidgets);
    await snap(tester, 'search');

    // the first row plays, with the results as the queue: one tap on a phone, a double-click with a mouse
    final first = find.byType(SongRow).first;
    await tester.tap(first);
    if (!isTouchDevice) {
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(first);
    }
    await until(tester, () => player.isPlaying && player.duration > 10, seconds: 25);
    expect(player.isPlaying, isTrue, reason: 'the first result plays');
    // a search result plays alone; Autoplay then fills Up Next with songs like it
    await until(tester, () => player.queue.upNext.length > 2, seconds: 15);
    expect(player.queue.upNext.length, greaterThan(2), reason: 'Autoplay fills Up Next');
    await tester.pump(const Duration(seconds: 2));
    await snap(tester, 'playing');

    // the controls show their state: the disc toggles pause and play, shuffle and repeat light up when on
    expect(find.byTooltip('Pause'), findsWidgets, reason: 'playing: the disc shows pause');
    await tester.tap(find.byTooltip('Pause').hitTestable().first);
    await until(tester, () => !player.isPlaying, seconds: 5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Play'), findsWidgets, reason: 'paused: the disc shows play');
    await tester.tap(find.byTooltip('Play').hitTestable().first);
    await until(tester, () => player.isPlaying, seconds: 8);
    // shuffle and repeat: in the bar on a desktop window, in Now Playing on a phone (its bar keeps to play and next)
    final phone = tester.view.physicalSize.width / tester.view.devicePixelRatio < 700;
    if (phone) {
      player.setShowNowPlaying(true);
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.byTooltip('Shuffle').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Shuffle is on'), findsWidgets);
    await tester.tap(find.byTooltip('Shuffle is on').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Repeat').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Repeating the queue'), findsWidgets);
    await tester.tap(find.byTooltip('Repeating the queue').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Repeating this song').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Repeat'), findsWidgets, reason: 'off → all → one → off');
    if (phone) {
      player.setShowNowPlaying(false);
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Add to Queue puts the song after the user's own queued songs, before Autoplay's
    final extra = player.queue.upNext[1];
    player.addToQueue(extra);
    final mine = player.queue.upcoming.where((e) => !e.autoplay).toList();
    expect(mine.last.track.id, extra.id, reason: 'your song goes before Autoplay songs');

    player.setShowNowPlaying(true);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));      // the slide up (280 ms) runs from the frame above
    expect(find.text('Up Next'), findsWidgets);
    expect(find.byTooltip('More: Add to Playlist, Download').hitTestable(), findsWidgets, reason: 'the playing song has its menu');
    await snap(tester, 'now-playing');
    if (isTouchDevice) {
      // one tap on an Up Next song plays it (it took several: a double tap was needed, 13 Oct)
      if (player.panel != 'upNext') player.setPanel('upNext');   // setPanel on the panel shown hides it
      await tester.pump(const Duration(milliseconds: 400));
      final target = player.queue.upNext.first;
      await tester.tap(find.descendant(of: find.byType(UpNext), matching: find.text(target.title)).first);
      await until(tester, () => player.current?.id == target.id, seconds: 5);
      expect(player.current?.id, target.id, reason: 'a tap on an Up Next song plays it');
    }

    // lyrics are requested when the song starts, not when the panel opens
    await until(tester, () => lyrics.of(player.current!) != null, seconds: 15);
    expect(lyrics.of(player.current!), isNotNull, reason: 'fetched with the song, before the panel opens');
    // beside the song: found, or "Couldn't find lyrics", never left on "Finding lyrics…"
    player.setPanel('lyrics');
    await tester.pump();
    expect(find.text('Finding lyrics…'), findsNothing, reason: 'already there when the panel opens');
    await until(tester, () => lyrics.of(player.current!) != null, seconds: 15);
    await tester.pump(const Duration(seconds: 1));
    final found = lyrics.of(player.current!);
    expect(found, isNotNull, reason: 'the server answered for lyrics');
    debugPrint('LYRICS ${found!.lines.length} lines, synced ${found.synced}, from ${found.sourceName}');
    await snap(tester, 'lyrics');
    player.setPanel('upNext');
    // the system's Back closes Now Playing, not the app (it closed the app, 13 Oct)
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.showNowPlaying, isFalse, reason: 'Back closes Now Playing');

    // a playlist: made, filled with 3 songs, opened, its rows in order; then deleted
    final name = 'Flutter test ${DateTime.now().millisecondsSinceEpoch % 10000}';
    expect(await library.createPlaylist(name), isNull);
    final id = library.playlists.firstWhere((p) => p.name == name).id;
    final three = player.queue.tracks.take(3).toList();
    for (final t in three) {
      await library.add(t, id);
    }
    await tester.pump(const Duration(milliseconds: 300)); // the sidebar shows it
    if (phone) {
      // a phone has no sidebar: Home lists your playlists
      await tester.tap(find.text('Home').last);
      await tester.pump(const Duration(seconds: 1));
      await tester.scrollUntilVisible(find.text(name), 200, scrollable: find.byType(Scrollable).first);
      // in view is not in reach: the card can stand under the floating player bar, which then takes the tap (13 Oct)
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.tap(find.text(name).first);
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

    // a YouTube copy looked up by this device: on the Mac build, the server's link fails with just_audio's -1
    const yt = Listing(source: 'ytmusic', id: 'J7p4bzqLvCw', title: 'Blinding Lights', artists: ['The Weeknd'], duration: 200);
    await player.play([Track(yt, const [yt])]);
    await until(tester, () => player.position > 3, seconds: 20);
    expect(player.position, greaterThan(3), reason: 'a YouTube song plays in the app');
    expect(player.current?.title, 'Blinding Lights', reason: 'the YouTube copy itself, not a fallback song');
    expect(player.duration, inInclusiveRange(195, 201), reason: 'its length as listed (200 s), not the doubled one Apple reports');
    player.togglePlayPause();

    // Settings, opened from the sidebar's bottom item: each section is on screen, inside the window
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    final window = tester.getRect(find.byKey(shot));
    final settingsList = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
    // every section the Mac app has that applies here, each scrolled to and checked on screen
    for (final label in ['Account', 'Device Name', 'Server', 'Connected', 'Appearance', 'Text size', 'Playback', 'Lyrics', 'Line movement']) {
      final found = find.text(label);
      await tester.scrollUntilVisible(found.first, 120, scrollable: settingsList);
      await tester.pumpAndSettle();
      final r = tester.getRect(found.first);
      expect(window.contains(r.center), isTrue, reason: '"$label" at $r, inside the window $window');
    }
    // Playback › Autoplay and the switch under it (back up: the list stands at Lyrics): stored when tapped, and only
    // switchable while Autoplay is on
    final autoplay = find.widgetWithText(SwitchListTile, 'Autoplay');
    final skips = find.widgetWithText(SwitchListTile, 'Skip songs I played or skipped lately');
    await tester.scrollUntilVisible(autoplay, -120, scrollable: settingsList);
    await tester.pumpAndSettle();
    expect(settings.autoplaySkipsRecent, isTrue);
    await tester.tap(skips);
    await tester.pumpAndSettle();
    expect(settings.autoplaySkipsRecent, isFalse);
    await tester.tap(autoplay);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(skips).onChanged, isNull);
    await tester.tap(autoplay);
    await tester.pumpAndSettle();                     // switchable again only once rebuilt
    await tester.tap(skips);
    await tester.pumpAndSettle();
    expect((settings.autoplay, settings.autoplaySkipsRecent), (true, true));
    // dark, and larger text: the whole app follows at once
    await settings.setTheme(ThemeMode.dark);
    await settings.setTextScale(1.25);
    await tester.pumpAndSettle();
    // any widget of the settings list will do: which headings are built depends on how far it has scrolled
    final anyRow = find.descendant(of: settingsList, matching: find.byType(Text)).first;
    expect(Theme.of(tester.element(anyRow)).brightness, Brightness.dark);
    expect(MediaQuery.textScalerOf(tester.element(anyRow)).scale(10), closeTo(12.5, 0.01));
    await tester.scrollUntilVisible(find.text('Account'), -300, scrollable: settingsList);
    await snap(tester, 'settings');
    await settings.setTheme(ThemeMode.system);
    await settings.setTextScale(1);
  });
}
