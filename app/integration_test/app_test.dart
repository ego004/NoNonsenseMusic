// Drives the whole app from inside (no system input: it runs while you use the Mac) against a TEST server:
//   flutter test integration_test -d macos --dart-define=SERVER=http://127.0.0.1:8765
// Search, play the first result, Now Playing with Up Next, Add to Queue. Saves pictures of the app as it draws
// itself to $NN_SNAPS (default: the system temp folder). Muted.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/main.dart';
import 'package:nononsense/ui/song_row.dart';

final shot = GlobalKey();

/// The app as it draws itself now (its own layer tree, not the screen), into the app's container.
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

Future<void> until(WidgetTester tester, bool Function() done, {int seconds = 20}) async {
  for (var i = 0; i < seconds * 4 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search, play, Now Playing, Up Next, Add to Queue', (tester) async {
    expect(Api.base, isNot(contains(':8000')), reason: 'a test runs only against a test server, never your library');
    MediaKit.ensureInitialized();
    final player = Player()..setVolume(0);
    final library = Library();
    await tester.pumpWidget(RepaintBoundary(key: shot, child: NoNonsenseApp(player: player, library: library)));
    await tester.pump(const Duration(seconds: 1));

    await tester.enterText(find.byType(TextField), 'arijit singh');
    await until(tester, () => find.byType(SongRow).evaluate().length > 3);
    expect(find.byType(SongRow), findsWidgets);
    await snap(tester, 'search');

    // a double-click on the first row plays it, with the results as the queue
    final first = find.byType(SongRow).first;
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(first);
    await until(tester, () => player.isPlaying && player.duration > 10, seconds: 25);
    expect(player.isPlaying, isTrue, reason: 'the first result plays');
    expect(player.queue.upNext.length, greaterThan(2));
    await tester.pump(const Duration(seconds: 2));
    await snap(tester, 'playing');

    // Add to Queue: the end of Up Next
    final extra = player.queue.upNext[1];
    player.addToQueue(extra);
    expect(player.queue.upNext.last.id, extra.id);

    player.setShowNowPlaying(true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Up Next'), findsOneWidget);
    await snap(tester, 'now-playing');
    player.setShowNowPlaying(false);
    await tester.pump(const Duration(milliseconds: 400));
    player.togglePlayPause();
    await tester.pump(const Duration(milliseconds: 500));
  });
}
