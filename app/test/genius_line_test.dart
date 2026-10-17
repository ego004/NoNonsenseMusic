// A lyric line with a Genius note: in the accent colour (not underlined), its note on glass while the pointer rests on
// it, the whole note in a glass window on a click; every animation settles.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/lyrics_panel.dart';

const note = GeniusNote('Roll up all my ones', 'Yebba is spending everything she has left on the night.', verified: true);

Widget lines({VoidCallback? onPlay}) => MaterialApp(
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange, brightness: Brightness.dark)),
      home: Scaffold(
        body: Column(children: [
          NotedLyricLine(text: 'Roll up all my ones, take my chances', note: note, url: 'https://genius.com/x', onPlay: onPlay,
              style: const TextStyle(color: Colors.white)),
          const NotedLyricLine(text: 'Hit another blunt', style: TextStyle(color: Colors.white)),
        ]),
      ),
    );

void main() {
  testWidgets('a noted line is coloured, not underlined', (tester) async {
    await tester.pumpWidget(lines());
    final noted = tester.widget<Text>(find.text('Roll up all my ones, take my chances')).style!;
    final plain = tester.widget<Text>(find.text('Hit another blunt')).style!;
    expect(noted.decoration, isNot(TextDecoration.underline));
    expect(noted.color, isNot(plain.color));
  });

  testWidgets('the pointer is a hand over a noted line', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    await tester.pumpWidget(lines());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Roll up all my ones, take my chances')));
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
    await mouse.moveTo(tester.getCenter(find.text('Hit another blunt')));   // no note, nothing to play: an arrow
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
    await tester.pump(const Duration(seconds: 1));
  });

  // a computer: a phone has no pointer to rest on a line
  testWidgets('resting on a noted line shows the note on glass; leaving hides it', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    await tester.pumpWidget(lines());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Roll up all my ones, take my chances')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(note.text), findsNothing);                   // passing over a line shows nothing
    await tester.pump(const Duration(milliseconds: 250));          // resting: the card comes, then everything holds
    await tester.pumpAndSettle();
    expect(find.text(note.text), findsOneWidget);
    expect(find.ancestor(of: find.text(note.text), matching: find.byType(GlassCard)), findsOneWidget);
    await mouse.moveTo(tester.getCenter(find.text('Hit another blunt')));
    await tester.pumpAndSettle();
    expect(find.text(note.text), findsNothing);
  });

  testWidgets('a click opens the whole note in a glass window', (tester) async {
    var played = false;
    await tester.pumpWidget(lines(onPlay: () => played = true));
    await tester.tap(find.text('Roll up all my ones, take my chances'));
    await tester.pumpAndSettle();
    expect(find.text(note.text), findsOneWidget);                  // SelectableText shows it as a Text too
    expect(find.text('Genius · verified by the artist'), findsOneWidget);
    expect(find.ancestor(of: find.text('Play from here'), matching: find.byType(GlassCard)), findsOneWidget);
    await tester.tap(find.text('Play from here'));
    await tester.pumpAndSettle();
    expect((played, find.text(note.text).evaluate().isEmpty), (true, true));
  });

  // a fade from outside put the blur in an empty layer: the glass showed black until the fade ended (15 Oct)
  testWidgets('while the window and the card come in, nothing fades the glass from outside', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    final fading = find.byWidgetPredicate((w) => (w is Opacity && w.opacity < 1) || w is FadeTransition);
    await tester.pumpWidget(lines());
    await tester.tap(find.text('Roll up all my ones, take my chances'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));                 // part way in
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.ancestor(of: find.byType(BackdropFilter), matching: fading), findsNothing);
    await tester.tapAt(const Offset(4, 4));                              // the dim outside closes it
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Roll up all my ones, take my chances')));
    await tester.pump(const Duration(milliseconds: 300));                // the rest before the card
    await tester.pump(const Duration(milliseconds: 80));                 // part way in
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.ancestor(of: find.byType(BackdropFilter), matching: fading), findsNothing);
    await tester.pumpAndSettle();
  });
}
