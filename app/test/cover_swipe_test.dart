// Now Playing's cover on a touch screen follows the finger and skips when pulled far enough, as the iPhone's does.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zz_concept_settle_test.dart' show song;

void main() {
  Future<Player> pump(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'checkUpdates': false});
    final settings = Settings();
    await settings.load();
    final player = Player();
    addTearDown(player.dispose);
    player.queue.load([for (var i = 0; i < 3; i++) song(i)], 0, shuffled: false);
    player.currentId.value = song(0).id;
    player.panel = 'none';
    await tester.pumpWidget(Scope(
      player: player,
      library: Library(),
      lyrics: LyricsStore(),
      settings: settings,
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(theme: buildTheme(Brightness.dark, null, look: Look.phone), home: const Scaffold(body: NowPlaying())),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    return player;
  }

  testWidgets('a short, slow swipe on the cover follows the finger and springs back', (tester) async {
    await pump(tester);
    final cover = find.byKey(const ValueKey('now-playing-artwork'));
    final before = tester.getCenter(cover);
    final gesture = await tester.startGesture(before);
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 120)); // a slow drag: a fling would skip
    }
    expect(tester.getCenter(cover).dx < before.dx, isTrue, reason: 'the cover follows the finger');
    await gesture.up();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.getCenter(cover).dx, closeTo(before.dx, 0.5), reason: 'and springs back');
    debugDefaultTargetPlatformOverride = null;
  });
}
