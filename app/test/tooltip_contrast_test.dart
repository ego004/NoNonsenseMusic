// A tooltip's text reads against its bubble in both themes (#20: in the dark theme both were dark). Checked on the text
// as drawn, so a colour the theme leaves to Flutter's defaults is caught too.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/ui/theme.dart';

double contrast(Color a, Color b) {
  final (x, y) = (a.computeLuminance(), b.computeLuminance());
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final song in [null, const Color(0xFF8E2C6B)]) {
      testWidgets('a tooltip reads in the ${brightness.name} theme${song == null ? '' : ' with a song\'s colour'}', (tester) async {
        final theme = buildTheme(brightness, song);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: const Scaffold(body: Center(child: Tooltip(message: 'Shuffle', child: Icon(Icons.shuffle)))),
        ));
        tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
        await tester.pumpAndSettle();
        final text = tester.renderObject<RenderParagraph>(find.text('Shuffle')).text.style!.color!;
        final bubble = (theme.tooltipTheme.decoration! as BoxDecoration).color!;
        expect(contrast(text, bubble), greaterThan(7), reason: 'text $text on $bubble');
      });
    }
  }
}
