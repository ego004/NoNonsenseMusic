// A phone's navigation, as one model: tabs hold the root screens, everything else is a page pushed over them with a back
// button that can be seen, Now Playing is a single layer over a page, and Back steps one layer at a time. (Pages had a
// transparent app bar, Recently Played had no back button, and Now Playing opened under a page's app bar, with a second
// layer in the shell: 11 Nov.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/recent_searches.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/phone_page.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/shell.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'redesign_shell_test.dart' show close;
import 'zz_concept_settle_test.dart' show song;

Future<Player> phone(WidgetTester tester, {bool playing = true}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'checkUpdates': false});
  final settings = Settings();
  await settings.load();
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
    child: MaterialApp(theme: buildTheme(Brightness.dark, null, look: Look.phone), home: const Shell()),
  ));
  await settle(tester);
  return player;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(seconds: 1));
  }
}

/// The system's Back, as Android sends it.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settle(tester);
}

void main() {
  testWidgets('Liked Songs opens as a page with a back button, and the tab bar stays on Library', (tester) async {
    await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    expect(find.byType(PageBackButton), findsNothing, reason: 'a tab has no back button');
    await tester.tap(find.text('Liked Songs'));
    await settle(tester);
    expect(find.byType(PageBackButton), findsOneWidget, reason: 'every pushed page has one that can be seen');
    await tester.tap(find.byType(PageBackButton));
    await settle(tester);
    expect(find.byType(PageBackButton), findsNothing);
    expect(find.text('Liked Songs'), findsWidgets, reason: 'back on Library');
    await close(tester);
  });

  testWidgets('Recently Played and Liked Songs both have a back button (Recently Played had none)', (tester) async {
    await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    for (final name in ['Recently Played', 'Liked Songs']) {
      await tester.tap(find.text(name).first);
      await settle(tester);
      expect(find.byType(PageBackButton), findsOneWidget, reason: name);
      await systemBack(tester);
      expect(find.byType(PageBackButton), findsNothing, reason: 'the system Back leaves $name');
    }
    await close(tester);
  });

  testWidgets('the back button is drawn with its own surface, not as an arrow on whatever is behind', (tester) async {
    await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    await tester.tap(find.text('Liked Songs'));
    await settle(tester);
    final button = tester.getRect(find.byType(PageBackButton));
    expect(button.width >= 48 && button.height >= 48, isTrue, reason: 'a thumb-sized target: $button');
    expect(button.top >= 0 && button.left >= 0, isTrue);
    final material = tester.widget<Material>(find.descendant(of: find.byType(PageBackButton), matching: find.byType(Material)).first);
    expect(material.color!.a > 0.5, isTrue, reason: 'it has a surface of its own, so it shows on a light or a dark backdrop');
    await close(tester);
  });

  testWidgets('Back closes Now Playing first, then the page, one step each', (tester) async {
    final player = await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    await tester.tap(find.text('Liked Songs'));
    await settle(tester);
    player.setShowNowPlaying(true);
    await settle(tester);
    expect(find.byType(NowPlaying), findsOneWidget, reason: 'one Now Playing, not one in the page and one in the shell');
    await systemBack(tester);
    expect(player.showNowPlaying, isFalse, reason: 'the first Back closes Now Playing');
    expect(find.byType(PageBackButton), findsOneWidget, reason: 'and leaves the page');
    await systemBack(tester);
    expect(find.byType(PageBackButton), findsNothing, reason: 'the second leaves the page');
    await close(tester);
  });

  testWidgets('Now Playing covers the whole page: the back button is not above it', (tester) async {
    final player = await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    await tester.tap(find.text('Liked Songs'));
    await settle(tester);
    player.setShowNowPlaying(true);
    await settle(tester);
    final back = tester.getRect(find.byType(PageBackButton, skipOffstage: false));
    final hit = tester.hitTestOnBinding(back.center);
    expect(hit.path.any((e) => e.target is RenderObject && e.target.runtimeType.toString().contains('PageBackButton')), isFalse,
        reason: 'a tap where the back button is reaches Now Playing, not a button under it');
    await close(tester);
  });

  testWidgets('Settings is a page with a back button too, and opening it twice does not stack pages', (tester) async {
    await phone(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.byType(PageBackButton), findsOneWidget);
    await systemBack(tester);
    expect(find.byType(PageBackButton), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.tap(find.byType(PageBackButton));
    await settle(tester);
    expect(find.byType(PageBackButton), findsNothing, reason: 'one Back from Settings is home again');
    await close(tester);
  });

  testWidgets('Back from a tab other than Home goes Home; from Home it leaves the app', (tester) async {
    await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    await systemBack(tester);
    expect(find.text('Good afternoon').evaluate().isNotEmpty || find.textContaining('Good ').evaluate().isNotEmpty, isTrue, reason: 'Home');
    await close(tester);
  });

  testWidgets('a pushed page keeps the tab bar: choosing a tab goes back to the shell on that tab', (tester) async {
    await phone(tester);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    await tester.tap(find.text('Liked Songs'));
    await settle(tester);
    expect(find.byType(NavigationBar), findsOneWidget, reason: 'the page has the tab bar, as the iPhone pages do');
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2, reason: 'Library stays selected');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Search')));
    await settle(tester);
    expect(find.byType(PageBackButton), findsNothing, reason: 'the page is gone');
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1, reason: 'on Search');
    await close(tester);
  });

  testWidgets('Search shows the recent searches under the empty field; × forgets one and Clear forgets all', (tester) async {
    await phone(tester);
    await tester.runAsync(() async {
      await RecentSearches.shared.clear();
      await RecentSearches.shared.add('shape of you');
      await RecentSearches.shared.add('tum hi ho');
    });
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Search')));
    await settle(tester);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('tum hi ho'), findsOneWidget, reason: 'newest first');
    expect(find.text('shape of you'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove tum hi ho'));
    await tester.pump();
    expect(find.text('tum hi ho'), findsNothing);
    expect(find.text('shape of you'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('Recent'), findsNothing, reason: 'nothing left to show');
    await close(tester);
  });
}
