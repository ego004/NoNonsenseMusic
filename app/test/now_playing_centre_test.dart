// A computer's Now Playing is centred: the song (with its panel, when one is open) in the middle of the window both
// ways, the panel as tall as the song, and the "Now Playing" heading over the middle (15 Oct: it sat 77 points left).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/ui/concept.dart';

import 'now_playing_layout_test.dart' show screen, track;

void main() {
  for (final size in [const Size(1916, 997), const Size(1166, 713)]) {
    for (final panel in ['none', 'lyrics', 'upNext']) {
      testWidgets('centred at $size, panel $panel', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final player = Player()
          ..panel = panel
          ..queue.load([track], 0, shuffled: false);
        addTearDown(player.dispose);
        await tester.pumpWidget(screen(player, size));
        await tester.pump(const Duration(seconds: 2));

        final cover = tester.getRect(find.byType(SpringCover));
        final song = Rect.fromLTRB(cover.left, cover.top, cover.right, tester.getRect(find.byType(AppleVolume)).bottom);
        final glass = find.byWidgetPredicate((w) => w is Container && w.key == ValueKey(panel));
        final group = panel == 'none' ? song : song.expandToInclude(tester.getRect(glass));
        final middle = size.center(Offset.zero);
        expect(group.center.dx, moreOrLessEquals(middle.dx, epsilon: 1));
        expect(group.center.dy, moreOrLessEquals(middle.dy, epsilon: 1));
        expect(tester.getCenter(find.text('NOW PLAYING')).dx, moreOrLessEquals(middle.dx, epsilon: 1));
        if (panel != 'none') {
          final box = tester.getRect(glass);
          expect(box.top, moreOrLessEquals(song.top, epsilon: 1));
          expect(box.bottom, moreOrLessEquals(song.bottom, epsilon: 1));
        }
        player.panel = 'none';
      });
    }
  }
}
