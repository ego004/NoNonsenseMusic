// Under the artist, Now Playing shows the album and where the song plays from ("YouTube Music · AAC 128 kbps"). The two
// shared the row half and half, so a long album name left the source cut to "AAC 12…" (29 Oct). The album gives way.
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';

import 'now_playing_layout_test.dart' show screen;
import 'one_line_titles_test.dart' show loadRoboto;

final longAlbum = Track(
  const Listing(
    source: 'ytmusic',
    id: 'source-line-test',
    title: 'Blinding Lights',
    artists: ['The Weeknd'],
    album: 'The Highlights (Deluxe Edition With Bonus Tracks)',
    duration: 200,
  ),
  const [],
);

void main() {
  // real glyph widths: the test font's squares are far wider than text
  setUpAll(loadRoboto);
  for (final width in [320.0, 360.0, 411.0]) {
    testWidgets('the source and bitrate are whole at $width points, and a long album gives way', (tester) async {
      final size = Size(width, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = Player()
        ..panel = 'none'
        ..queue.load([longAlbum], 0, shuffled: false);
      addTearDown(player.dispose);

      await tester.pumpWidget(screen(player, size));
      await tester.pump();

      final source = find.text('YouTube Music · AAC 128 kbps');
      expect(source, findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(source).didExceedMaxLines, isFalse, reason: 'the bitrate is not cut off');
      expect(tester.takeException(), isNull);
    });
  }
}
