// UI v2 (15 Oct): the computer's player bar at every width: no overflow, the controls kept in order of need (like,
// the volume, Up Next, Lyrics, full screen), every one of them at full width, and frosted glass that nothing fades.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/player_bar.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/song_row.dart';
import 'package:nononsense/ui/theme.dart';

import 'zz_concept_settle_test.dart' show song;

Future<Player> bar(WidgetTester tester, double width) async {
  tester.view.physicalSize = const Size(1600, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final p = Player();
  p.queue.load([song(0)], 0, shuffled: false);
  p.currentId.value = song(0).id;
  await tester.pumpWidget(Scope(
    player: p,
    library: Library(),
    lyrics: LyricsStore(),
    settings: Settings(),
    auth: Auth(store: MemoryTokenStore()),
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, null),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: SizedBox(width: width, child: const PlayerBar()))),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
  return p;
}

void main() {
  testWidgets('no width overflows it, and the volume outlasts the buttons', (tester) async {
    for (var width = 720.0; width <= 960; width += 20) {
      final p = await bar(tester, width);
      expect(tester.takeException(), isNull, reason: 'at $width');
      // the volume goes only after Lyrics has gone
      if (find.byType(AppleVolume).evaluate().isEmpty) expect(find.byTooltip('Lyrics'), findsNothing, reason: 'at $width');
      await tester.pump(const Duration(seconds: 2));
      p.dispose();
    }
  });

  testWidgets('at full width every control is there, on frosted glass', (tester) async {
    final p = await bar(tester, 940);
    expect(find.byType(LikeButton), findsOneWidget);
    expect(find.byType(AppleVolume), findsOneWidget);
    for (final tip in ['Lyrics', 'Up Next', 'Now Playing']) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    expect(find.byType(BackdropFilter), findsOneWidget);
    final fading = find.byWidgetPredicate((w) => (w is Opacity && w.opacity < 1) || (w is FadeTransition && w.opacity.value < 1));
    expect(find.ancestor(of: find.byType(BackdropFilter), matching: fading), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    p.dispose();
  });
}
