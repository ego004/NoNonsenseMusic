// A song row on a touch screen, as the iPhone's: swipe right for Play Next, left for Add to Queue; the row springs back.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/song_row.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zz_concept_settle_test.dart' show song;

void main() {
  Future<Player> pump(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = Settings();
    await settings.load();
    final player = Player();
    addTearDown(player.dispose);
    player.queue.load([song(0), song(1)], 0, shuffled: false);
    player.currentId.value = song(0).id;
    await tester.pumpWidget(Scope(
      player: player,
      library: Library(),
      lyrics: LyricsStore(),
      settings: settings,
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, null, look: Look.phone),
        home: Scaffold(body: Column(children: [SongRow(queue: [song(5)], index: 0)])),
      ),
    ));
    await tester.pump();
    return player;
  }

  testWidgets('swiping right plays the song next, and the row stays', (tester) async {
    final player = await pump(tester);
    await tester.drag(find.byType(SongRow), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(player.queue.upNext.first.id, song(5).id, reason: 'first in Up Next');
    expect(find.byType(SongRow), findsOneWidget, reason: 'the row springs back');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('swiping left adds the song to the end of the queue, and the row stays', (tester) async {
    final player = await pump(tester);
    await tester.drag(find.byType(SongRow), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(player.queue.upNext.last.id, song(5).id, reason: 'last in Up Next');
    expect(player.queue.upNext.length, 2, reason: 'one song was there, one added');
    expect(find.byType(SongRow), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
