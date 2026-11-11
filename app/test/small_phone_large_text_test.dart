// The new phone screens at the hardest size: a 360-wide phone with Android's text at 200% (the app has overflowed there
// before, #20). A layout overflow is an exception, so each test fails if one appears.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/add_to_playlist.dart';
import 'package:nononsense/ui/phone_page.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/settings_screen.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zz_concept_settle_test.dart' show song;

Future<void> pump(WidgetTester tester, Widget Function(Library) home) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'checkUpdates': false});
  final settings = Settings();
  await settings.load();
  final player = Player();
  addTearDown(player.dispose);
  player.queue.load([song(0), song(1)], 0, shuffled: false);
  player.currentId.value = song(0).id;
  final library = Library()
    ..playlists = [
      PlaylistSummary('gym', 'A playlist with a rather long name that has to wrap or be cut', 12, 3000),
      PlaylistSummary('chill', 'Chill', 0, 0),
    ];
  library.details['gym'] = PlaylistDetail(library.playlists[0], [('r1', song(0))]);
  library.details['chill'] = PlaylistDetail(library.playlists[1], const []);
  await tester.pumpWidget(Scope(
    player: player,
    library: library,
    lyrics: LyricsStore(),
    settings: settings,
    auth: Auth(store: MemoryTokenStore()),
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, null, look: Look.phone),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2.0)), child: child!),
      home: home(library),
    ),
  ));
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('the Add to Playlist picker has no overflow at 200% text on a 360 dp phone', (tester) async {
    await pump(tester, (_) => Scaffold(body: AddToPlaylistSheet(track: song(0))));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Already added'), findsOneWidget);
  });

  testWidgets('a page with its dock has no overflow at 200% text on a 360 dp phone', (tester) async {
    await pump(tester, (_) => const PhonePage(child: Center(child: Text('Page'))));
    expect(tester.takeException(), isNull);
    expect(find.byType(PageBackButton), findsOneWidget);
  });

  testWidgets('Settings in cards has no overflow at 200% text on a 360 dp phone', (tester) async {
    await pump(tester, (_) => const PhonePage(child: SettingsScreen()));
    expect(tester.takeException(), isNull);
    expect(find.text('Account'), findsOneWidget);
  });
}
