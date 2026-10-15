// UI v2 (15 Oct) on a computer: Home with a song playing (one line of greeting, the song large with Up Next beside it,
// Your Library as one grid), the cover glow, the command bar at the top, and the keys that work from anywhere.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/command_bar.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/in_front.dart';
import 'package:nononsense/ui/jam_panel.dart';
import 'package:nononsense/ui/redesign.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/settings_screen.dart';
import 'package:nononsense/ui/shell.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'redesign_shell_test.dart' show close;
import 'zz_concept_settle_test.dart' show song;

Future<Player> window(WidgetTester tester, Size size, {bool playing = true, bool glow = true, bool covers = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final settings = Settings();
  await settings.load();
  if (!glow) await settings.setCoverGlow(false);
  final player = Player();
  addTearDown(player.dispose);
  if (playing) {
    player.queue.load([for (var i = 0; i < 5; i++) covers ? Track(song(i).best, const [], image: 'http://img.test/$i.jpg') : song(i)], 0, shuffled: false);
    player.currentId.value = song(0).id;
  }
  await tester.pumpWidget(Scope(
    player: player,
    library: Library(),
    lyrics: LyricsStore(),
    settings: settings,
    auth: Auth(store: MemoryTokenStore()),
    child: MaterialApp(theme: buildTheme(Brightness.dark, null), home: const Shell()),
  ));
  await tester.pump(const Duration(seconds: 1));
  return player;
}

Finder get box => find.descendant(of: find.byType(CommandBar), matching: find.byType(TextField));

Future<void> ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  for (final size in [const Size(1000, 700), const Size(1280, 800), const Size(1920, 1009)]) {
    testWidgets('Home at $size: the song playing, Up Next, the command bar, and no extras', (tester) async {
      await window(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.byType(NowHero), findsOneWidget);
      expect(find.text('PAUSED'), findsOneWidget, reason: 'loaded, not started');
      expect(find.text('Up Next'), findsOneWidget);
      expect(find.text('Song number 1'), findsOneWidget, reason: 'the next song, beside the one playing');
      expect(find.byType(CommandBar), findsOneWidget);
      expect(find.text('“Same music, different people.”'), findsNothing);
      expect(find.descendant(of: find.byType(TopActions), matching: find.text('Jam')), findsOneWidget, reason: 'beside the bell');
      expect(find.text('Jam'), findsOneWidget, reason: 'not in the sidebar too');
      expect(find.text('Search songs, artists, albums…'), findsNothing, reason: 'one search box: the one at the top');
      await close(tester);
    });
  }

  testWidgets('Jam beside the bell opens the jam panel', (tester) async {
    await window(tester, const Size(1280, 800));
    await tester.tap(find.text('Jam'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(JamPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(JamPanel), findsNothing);
    await close(tester);
  });

  testWidgets('the page is no wider than 1504 in a wide window', (tester) async {
    await window(tester, const Size(2560, 1300));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(NowHero)).width, lessThanOrEqualTo(1504 - 2 * 32));
    await close(tester);
  });

  testWidgets('the cover glow lies under the window while a song with a cover is loaded', (tester) async {
    await window(tester, const Size(1280, 800), covers: true);
    expect(find.byType(CoverGlow), findsOneWidget);
    expect(find.descendant(of: find.byType(CoverGlow), matching: find.byType(CoverBackdrop)), findsOneWidget);
    await close(tester);
  });

  testWidgets('with the glow off, nothing is drawn for it', (tester) async {
    await window(tester, const Size(1280, 800), glow: false, covers: true);
    expect(find.descendant(of: find.byType(CoverGlow), matching: find.byType(CoverBackdrop)), findsNothing);
    await close(tester);
  });

  testWidgets('with nothing playing, Home has no song card', (tester) async {
    await window(tester, const Size(1280, 800), playing: false);
    expect(tester.takeException(), isNull);
    expect(find.text('PAUSED'), findsNothing);
    expect(find.text('NOW PLAYING'), findsNothing);
    await close(tester);
  });

  testWidgets('Ctrl+K puts the keyboard in the command bar; a command runs on Enter; Esc leaves', (tester) async {
    final p = await window(tester, const Size(1280, 800));
    await ctrlK(tester);
    expect(find.text('SUGGESTED'), findsOneWidget, reason: 'what is most likely wanted, before anything is typed');
    expect(find.text('Lyrics'), findsOneWidget);
    await tester.enterText(box, 'lyr');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ACTIONS'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((p.showNowPlaying, p.panel), (true, 'lyrics'));
    expect(find.text('ACTIONS'), findsNothing, reason: 'the list closes once a command runs');
    p.setShowNowPlaying(false);
    await tester.pump(const Duration(seconds: 1));
    await ctrlK(tester);
    await tester.enterText(box, 'set');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('ACTIONS'), findsNothing);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    await close(tester);
  });

  testWidgets('typing a page and Enter goes there', (tester) async {
    await window(tester, const Size(1280, 800));
    await ctrlK(tester);
    await tester.enterText(box, 'sett');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SettingsScreen), findsOneWidget);
    await close(tester);
  });

  testWidgets('M mutes and Ctrl+↓ turns the volume down from the moment the window opens; not while typing', (tester) async {
    final p = await window(tester, const Size(1280, 800));
    p.setVolume(0.5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(p.volume, closeTo(0.45, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(p.volume, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(p.volume, closeTo(0.45, 1e-9));
    // an M typed into the command bar is the bar's
    await ctrlK(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(p.volume, closeTo(0.45, 1e-9));
    await close(tester);
    // as on Windows: in a test's default (Android), the framework's own arrow keys scroll every list at once
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a mouse resting anywhere on Home never keeps the window drawing', (tester) async {
    // 15 Oct: resting on an artist's name in the player bar drew 60 frames a second (ArtistLinks), each one the whole
    // window under the cover glow: most of a core. A spot still drawing after 0.6 s is watched for 4 s more, which any
    // finished hover (a tooltip fading in) is not.
    await window(tester, const Size(1280, 800));
    await tester.pump(const Duration(seconds: 2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    final drawing = <Offset>[];
    for (var y = 10.0; y < 800; y += 12) {
      for (var x = 270.0; x < 1280; x += 40) {
        await mouse.moveTo(Offset(x, y));
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        if (tester.binding.hasScheduledFrame) drawing.add(Offset(x, y));
      }
    }
    final looping = <Offset>[];
    for (final at in drawing) {
      await mouse.moveTo(at);
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (tester.binding.hasScheduledFrame) looping.add(at);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(seconds: 3));
    }
    expect(looping, isEmpty);
    await mouse.removePointer();
    await close(tester);
  });

  testWidgets('every time line moves on one tick a second, together, and only while the window is in front', (tester) async {
    // 15 Oct: Home's line and the player bar's each kept a timer and drew a frame of their own: two a second, not one
    var a = 0, b = 0;
    void first() => a++;
    void second() => b++;
    secondTick.addListener(first);
    await tester.pump(const Duration(milliseconds: 500));
    secondTick.addListener(second); // half a second later: a timer of its own would tick at 1.5 s
    await tester.pump(const Duration(milliseconds: 600));
    expect((a, b), (1, 1), reason: 'at 1.1 s, both on the first tick');
    await tester.pump(const Duration(seconds: 1));
    expect((a, b), (2, 2));
    inFront.value = false;
    await tester.pump(const Duration(seconds: 3));
    expect((a, b), (2, 2), reason: 'behind other windows: no ticks');
    inFront.value = true;
    await tester.pump(const Duration(milliseconds: 1100));
    expect((a, b), (3, 3));
    secondTick.removeListener(first);
    secondTick.removeListener(second);
  });

  test('a command matches each word typed at the start of a word of its name', () {
    void nothing() {}
    final artist = Command('Go to Artist', Icons.person, nothing);
    expect(['go', 'art', 'go art', 'artist go', 'GO TO'].every(artist.matches), isTrue);
    expect(['rtist', 'go x', 'album'].any(artist.matches), isFalse);
    expect(Command('Ballin', Icons.queue_music, nothing).matches('ball'), isTrue);
  });
}
