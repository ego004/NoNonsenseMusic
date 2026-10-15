// TEMPORARY (UI concept, not to be committed): every animation in the concept is one-shot. Hover, press, buffer,
// pause, change song, open and close panels: after each, the frames must stop (pumpAndSettle times out on any
// animation that keeps running).
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/browse_pages.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/in_front.dart';
import 'package:nononsense/ui/now_playing.dart';
import 'package:nononsense/ui/player_bar.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/sidebar.dart';
import 'package:nononsense/ui/theme.dart';

Track song(int i) => Track(
    Listing(source: 'jiosaavn', id: 'id$i', title: 'Song number $i', artists: const ['Alex', 'Sam'], duration: 200, album: 'Made-Up Album'),
    const []);

void main() {
  testWidgets('the concept settles after every change', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    inFront.value = true;
    final p = Player();
    final songs = [for (var i = 0; i < 6; i++) song(i)];
    p.queue.load(songs, 0, shuffled: false);
    p.currentId.value = songs[0].id;
    p.isPlaying = true;
    p.setShowNowPlaying(true);
    final page = ValueNotifier<int>(0);
    await tester.pumpWidget(Scope(
      player: p,
      library: Library(),
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, null),
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: page,
            builder: (_, which, _) => switch (which) {
              0 => const NowPlaying(),
              1 => const Align(alignment: Alignment.bottomCenter, child: Padding(padding: EdgeInsets.all(12), child: PlayerBar())),
              _ => AlbumView(album: AlbumDetail(source: 'jiosaavn', id: 'b1', title: 'Made-Up Album', artists: const ['Alex'], year: 2024, songs: songs)),
            },
          ),
        ),
      ),
    ));
    Future<void> settled(String what) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: what);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '$what: a frame is still scheduled');
    }

    await settled('Now Playing opening');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    Future<void> hoverAll(String where) async {
      var n = 0;
      for (final f in [find.byType(Pressable), find.byType(AppleScrubber), find.byType(AppleVolume), find.byType(PillToggle)]) {
        for (final e in f.evaluate().toList()) {
          final box = e.renderObject as RenderBox?;
          if (box == null || !box.attached || !box.hasSize) continue;
          await mouse.moveTo(box.localToGlobal(box.size.center(Offset.zero)));
          await settled('$where: hovering ${e.widget.runtimeType}');
          n++;
        }
      }
      // ignore: avoid_print
      print('HOVERED $where: $n controls');
      await mouse.moveTo(const Offset(1, 1));
      await settled('$where: pointer away');
    }

    await hoverAll('Now Playing');
    await tester.tap(find.byType(PlayDisc));
    await settled('a press on the play disc');
    for (final (playing, buffering) in [(true, true), (true, false), (false, false), (true, false)]) {
      p.isPlaying = playing;
      p.isBuffering = buffering;
      p.cycleRepeat(); // notifies
      await settled('playing $playing, buffering $buffering');
    }
    p.queue.moveTo(1);
    p.currentId.value = songs[1].id;
    p.cycleRepeat();
    await settled('a new song');
    for (final panel in ['upNext', 'upNext', 'lyrics', 'lyrics']) {
      p.setPanel(panel);
      await settled('panel $panel toggled');
    }
    await tester.pump(const Duration(seconds: 3)); // three ticks of the scrubber: each draws one frame, then stops
    await settled('the scrubber ticking');

    p.setShowNowPlaying(false);
    page.value = 1;
    await settled('the bar');
    await hoverAll('the bar');

    page.value = 2;
    await settled('the album page');
    await hoverAll('the album page');
    for (final row in find.text('Song number 3').evaluate().toList()) {
      final box = row.renderObject! as RenderBox;
      await mouse.moveTo(box.localToGlobal(box.size.center(Offset.zero)));
      await settled('hovering a song row');
    }

    inFront.value = false;
    page.value = 3;
    await tester.pumpWidget(const SizedBox());
    await mouse.removePointer();
  });

  testWidgets('hover covers, sidebar items and pushed pages settle', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var selected = 0, plays = 0, opens = 0;
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark, null),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          set = setState;
          return Row(children: [
            SizedBox(
              width: 220,
              child: Column(children: [
                for (var i = 0; i < 3; i++) SideItem(icon: Icons.home, label: 'Item $i', selected: selected == i, onTap: () => setState(() => selected = i)),
              ]),
            ),
            PushIn(child: Column(children: [
              HoverCover(size: 148, onTap: () => opens++, onPlay: () => plays++, child: const SizedBox(width: 148, height: 148, child: ColoredBox(color: Colors.blue))),
              const SizedBox(height: 20),
              const HoverCover(size: 48, radius: 6, playing: true, child: SizedBox(width: 48, height: 48, child: ColoredBox(color: Colors.red))),
            ])),
          ]);
        }),
      ),
    ));
    Future<void> settled(String what) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: what);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '$what: a frame is still scheduled');
    }

    await settled('the page pushed in');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final big = find.byType(HoverCover).first;
    await mouse.moveTo(tester.getCenter(big));
    await settled('hovering a cover');
    await tester.tapAt(tester.getBottomRight(big) - const Offset(28, 28));
    await settled('the corner play button');
    expect(plays, 1, reason: 'the corner button plays');
    await tester.tapAt(tester.getCenter(big));
    await settled('a tap on the cover');
    expect(opens, 1, reason: 'the cover opens');
    await mouse.moveTo(tester.getCenter(find.byType(HoverCover).last));
    await settled('hovering a small playing cover');
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Item $i'));
      await settled('sidebar item $i chosen');
    }
    set(() => selected = 0);
    await settled('the selection set from outside');
    await mouse.moveTo(const Offset(1200, 700));
    await settled('pointer away');
    await mouse.removePointer();
  });
}
