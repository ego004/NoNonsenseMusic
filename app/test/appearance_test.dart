// Settings › Appearance (#29): every option kept, today's look the default, applied at once; Now Playing's text readable
// at every colour strength by #20's rule; nothing left drawing.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/accent.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/glass.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/player_bar.dart';
import 'package:nononsense/ui/redesign.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/settings_screen.dart';
import 'package:nononsense/ui/shell.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'redesign_shell_test.dart' show close;
import 'zz_concept_settle_test.dart' show song;

/// The app as main.dart builds it: the theme made again from [Settings] whenever they change.
Future<(Settings, Player)> app(WidgetTester tester, Widget home,
    {Size size = const Size(1280, 800), Brightness brightness = Brightness.dark, Look? look, bool playing = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'checkUpdates': false}); // the shell would ask GitHub
  final settings = Settings();
  await settings.load();
  if (look != null) await settings.setLook(look);
  final player = Player();
  addTearDown(player.dispose);
  if (playing) {
    player.queue.load([for (var i = 0; i < 3; i++) song(i)], 0, shuffled: false);
    player.currentId.value = song(0).id;
  }
  await tester.pumpWidget(Scope(
    player: player,
    library: Library(),
    lyrics: LyricsStore(),
    settings: settings,
    auth: Auth(store: MemoryTokenStore()),
    child: ListenableBuilder(
      listenable: settings,
      builder: (_, _) => MaterialApp(theme: buildTheme(brightness, null, look: settings.look), home: RepaintBoundary(child: home)),
    ),
  ));
  await drawn(tester);
  return (settings, player);
}

/// A change of settings shown: the theme carries it, and its change starts on the frame after.
Future<void> shown(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Lets a backdrop be drawn and kept (the engine's work, off the frame), then shows it.
Future<void> drawn(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(seconds: 1));
  }
}

/// The colours on screen at [points].
Future<List<Color>> colours(WidgetTester tester, List<Offset> points) async {
  final screen = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
  return (await tester.runAsync(() async {
    final image = await screen.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int at(Offset p, int channel) => data.getUint8((p.dy.toInt() * image.width + p.dx.toInt()) * 4 + channel);
    return [for (final p in points) Color.fromARGB(255, at(p, 0), at(p, 1), at(p, 2))];
  }))!;
}

void main() {
  group('kept', () {
    test("today's look is the default", () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      final look = settings.look; // a computer's: the tests run on one
      expect(look, const Look());
      expect((look.material, look.accent, look.background), (WindowMaterial.glass, ColourMode.song, ColourMode.song));
      expect((look.barBlur, look.solid(0.88)), (1, 0.88), reason: 'the bar as it was: blurred, its tint at 88%');
      expect([Look.strong(look.artStrength, 0.55), Look.strong(look.nowPlayingColour, 0.78), look.cardSize], [closeTo(0.55, 1e-9), closeTo(0.78, 1e-9), 148],
          reason: 'the cover as strong as before, behind the window and in Now Playing');
      expect((Look.phone.barBlur, Look.phone.copyWith(barBlur: 1)), (0, const Look()), reason: "a phone's bars only lose the blur");
    });

    test('every option is kept, and only what changed is written', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      const chosen = Look(
        material: WindowMaterial.mica,
        accent: ColourMode.custom,
        background: ColourMode.system,
        accentColour: Color(0xFFFF453A),
        backgroundColour: Color(0xFF30D158),
        artStrength: 0.2,
        nowPlayingColour: 1,
        barBlur: 0.4,
        barSolid: 0.5,
        cardSize: 190,
      );
      await settings.setLook(chosen);
      final again = Settings();
      await again.load();
      expect((again.look, again.material), (chosen, WindowMaterial.mica));

      SharedPreferences.setMockInitialValues({});
      final fresh = Settings();
      await fresh.load();
      await fresh.setLook(fresh.look.copyWith(cardSize: 180));
      expect((await SharedPreferences.getInstance()).getKeys(), {'cardSize'});
    });

    test('Cover glow switched off is Background: System; a saved Solid is Solid Dark', () async {
      SharedPreferences.setMockInitialValues({'coverGlow': false, 'material': 'solid'});
      final settings = Settings();
      await settings.load();
      expect((settings.look.background, settings.material), (ColourMode.system, WindowMaterial.solidDark));
    });

    test('a hex code is read as the Mac writes it', () {
      expect(colourFromHex('#5E5CE6'), const Color(0xFF5E5CE6));
      expect(colourFromHex('ff9f0a'), const Color(0xFFFF9F0A));
      expect([colourFromHex('#12345'), colourFromHex('blue'), colourFromHex('#1234567')], [null, null, null]);
      expect(hexOf(const Color(0xFF0A84FF)), '#0A84FF');
    });

    test('Reset All brings back the window, colours, surfaces and sizes', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      await settings.setTextScale(1.3);
      await settings.setLook(const Look(cardSize: 200, barBlur: 0, accent: ColourMode.system, material: WindowMaterial.clear));
      await settings.resetLook();
      expect((settings.look, settings.textScale), (const Look(), 1));
    });

    test("a custom accent keeps its own saturation; a song's is made vivid, as before", () {
      const grey = Color(0xFF8E8E93);
      for (final b in Brightness.values) {
        final custom = buildTheme(b, null, look: const Look(accent: ColourMode.custom, accentColour: grey)).colorScheme.primary;
        expect(HSLColor.fromColor(custom).saturation, lessThan(0.1), reason: 'a grey stays grey, ${b.name}');
        expect(buildTheme(b, grey).colorScheme.primary, Accent.readable(grey, b));
        expect(buildTheme(b, grey, look: const Look(accent: ColourMode.system)).colorScheme.primary, Accent.standard(b));
      }
    });
  });

  group('applied at once', () {
    testWidgets('the window, the accent, the bar and the card size change as they are set', (tester) async {
      final (settings, _) = await app(tester, const Shell());
      Color panel() => ((tester.widget<DecoratedBox>(find.descendant(of: find.byType(DesktopSidebar), matching: find.byType(DecoratedBox)).first)
              .decoration) as BoxDecoration).color!;
      expect(panel(), const Color(0xFF1B1B20).withValues(alpha: 0.42));
      // the sidebar kept Glass's fill after a change to Mica until another page opened (it read the setting, not the theme)
      await settings.setMaterial(WindowMaterial.mica);
      await shown(tester);
      expect(panel(), Colors.white.withValues(alpha: 0.045));

      await settings.setLook(settings.look.copyWith(accent: ColourMode.custom, accentColour: const Color(0xFFFF453A)));
      await shown(tester);
      final primary = Theme.of(tester.element(find.byType(DesktopSidebar))).colorScheme.primary;
      expect(HSLColor.fromColor(primary).hue, closeTo(HSLColor.fromColor(const Color(0xFFFF453A)).hue, 1));

      ui.ImageFilter? blur() {
        final filters = find.descendant(of: find.byType(PlayerBar), matching: find.byType(BackdropFilter)).evaluate();
        return filters.isEmpty ? null : (filters.single.widget as BackdropFilter).filter;
      }

      Color tint() => ((tester.widget<Container>(find.descendant(of: find.byType(PlayerBar), matching: find.byType(Container)).first).decoration)
              as BoxDecoration).color!;
      expect(blur(), ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30));
      expect(tint().a, closeTo(0.88, 0.002));
      await settings.setLook(settings.look.copyWith(barBlur: 0, barSolid: 1));
      await shown(tester);
      expect((blur(), tint().a), (null, 1), reason: 'no blur drawn at all, not one of 0; the tint solid');

      await tester.tap(find.text('Library'));
      await tester.pump(const Duration(seconds: 1));
      Iterable<double> cards() => tester.widgetList<CollectionTile>(find.byType(CollectionTile)).map((c) => c.size).where((s) => s > 60); // the Library page's, not the sidebar's or Home's
      expect(cards(), everyElement(148));
      await settings.setLook(settings.look.copyWith(cardSize: 200));
      await shown(tester);
      expect(cards(), everyElement(200));
      await close(tester);
    });

    testWidgets("a phone's bars: blurred and filled as set, and no blur at all at 0", (tester) async {
      final (settings, _) = await app(tester, const Shell(), size: const Size(400, 800), look: Look.phone);
      Iterable<GlassSurface> bars() => tester.widgetList<GlassSurface>(find.byType(GlassSurface)).where((g) => g.radius == 22 || g.radius == 28);
      expect(bars().length, 2, reason: 'the player bar and the tabs');
      expect(bars().every((g) => g.blur == 0 && g.solid == 0), isTrue);
      expect(find.byType(BackdropFilter), findsNothing, reason: 'nothing blurred on a phone by default');
      await settings.setLook(settings.look.copyWith(barBlur: 1, barSolid: 0.5));
      await shown(tester);
      expect(bars().every((g) => g.blur == 18 && g.solid == 0.5), isTrue);
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      await close(tester);
    });

    testWidgets('Background: System leaves the glow out, Custom draws it with no song playing', (tester) async {
      final (settings, _) = await app(tester, const Stack(children: [Positioned.fill(child: CoverGlow())]),
          playing: false, look: const Look(background: ColourMode.custom));
      expect(find.byType(CoverBackdrop), findsOneWidget);
      expect(find.descendant(of: find.byType(CoverBackdrop), matching: find.byType(RawImage)), findsOneWidget, reason: 'its shades drawn');
      await settings.setLook(settings.look.copyWith(background: ColourMode.system));
      await shown(tester);
      expect(find.byType(CoverBackdrop), findsNothing);
    });
  });

  // #20's rule keeps Now Playing's text readable on its backdrop: at Vivid, with the user's own colour at its most
  // troublesome (white under the dark theme's text, black under the light's), it still does
  for (final b in Brightness.values) {
    final worst = b == Brightness.dark ? Colors.white : Colors.black;
    testWidgets("Now Playing at Vivid in ${b == Brightness.dark ? 'white' : 'black'}: every kind of text reads, ${b.name}", (tester) async {
      await app(tester, const Scaffold(body: NowPlaying()), brightness: b, look: Look(background: ColourMode.custom, backgroundColour: worst, nowPlayingColour: 1));
      expect(find.descendant(of: find.byType(CoverBackdrop), matching: find.byType(RawImage)), findsOneWidget, reason: 'the backdrop is drawn');
      // the window's sides at the height of the song, where the veil is thinnest: the backdrop, nothing over it
      final points = [
        for (var y = 280.0; y <= 520; y += 40) ...[Offset(8, y), Offset(60, y), Offset(1220, y), Offset(1270, y)],
      ];
      final ink = NowPlayingInk(Theme.of(tester.element(find.byType(NowPlaying))), share: 0);
      for (final c in await colours(tester, points)) {
        expect(ink.reads(c), isTrue, reason: 'on $c');
      }
    });
  }

  group('the settings', () {
    testWidgets('Surfaces, Sizes and Colours as on the Mac; a custom colour is taken from its hex code', (tester) async {
      final (settings, _) = await app(tester, const Scaffold(body: SettingsScreen()), size: const Size(1000, 3000), playing: false);
      for (final heading in ['Window', 'Surfaces', 'Sizes', 'Colours']) {
        expect(find.text(heading), findsOneWidget);
      }
      Slider slider(String label) => tester.widget<Slider>(
          find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first, matching: find.byType(Slider)));
      expect(slider('Colour strength').max, Look.defaultStrength, reason: "the window's colour can be softer, not stronger");
      await tester.tap(find.text('Player bar'));
      await tester.pump();
      expect([slider('Blur').value, slider('Transparency').value], [1, 0]);
      await tester.tap(find.text('Now Playing'));
      await tester.pump();
      expect(find.text('Blur'), findsNothing);
      expect(slider('Colour strength').max, 1);

      final accent = find.ancestor(of: find.text('Accent'), matching: find.byType(Column)).first;
      await tester.tap(find.descendant(of: accent, matching: find.text('Custom')));
      await tester.pump();
      expect(settings.look.accent, ColourMode.custom);
      final hex = find.descendant(of: accent, matching: find.byType(TextField));
      await tester.enterText(hex, '#30d158');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(settings.look.accentColour, const Color(0xFF30D158));
      await tester.enterText(hex, 'green');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect((settings.look.accentColour, tester.widget<TextField>(hex).controller!.text), (const Color(0xFF30D158), '#30D158'),
          reason: 'not a colour: the one set stays');
      await tester.tap(find.descendant(of: accent, matching: find.byTooltip('#FF9F0A')));
      await tester.pump();
      expect(settings.look.accentColour, const Color(0xFFFF9F0A));

      await tester.tap(find.text('Reset All'));
      await tester.pump();
      expect(settings.look, const Look());
    });

    testWidgets('on a phone the bar is the bottom bar, and Appearance fits its width', (tester) async {
      await app(tester, const Scaffold(body: SettingsScreen()), size: const Size(360, 3000), playing: false);
      await tester.tap(find.text('Bottom bar'));
      await tester.pump();
      expect(find.text('Transparency'), findsOneWidget);
      await tester.tap(find.text('Custom').first);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'no overflow at 360 points');
    });
  });

  testWidgets('with the bar blurred and a custom background, the window and Now Playing settle', (tester) async {
    final (_, player) = await app(tester, const Shell(), look: const Look(background: ColourMode.custom, nowPlayingColour: 1));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    player.setShowNowPlaying(true);
    await drawn(tester);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    player.setShowNowPlaying(false);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await close(tester);
  });
}
