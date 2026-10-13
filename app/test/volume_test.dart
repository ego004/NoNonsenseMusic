// The volume slider's place becomes the player's gain through a cube, so that each part of the slider changes how loud
// it sounds by a similar amount (loudness is heard in ratios; the player's gain is linear).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/player.dart';

double decibels(double gain) => 20 * math.log(gain) / math.ln10;

void main() {
  test('the ends stay silent and full', () {
    expect(Player.gain(0), 0);
    expect(Player.gain(1), 1);
  });

  test('a lower place is clearly quieter: half is -18 dB, a quarter -36 dB, a tenth -60 dB', () {
    expect(decibels(Player.gain(0.5)), closeTo(-18.1, 0.1));
    expect(decibels(Player.gain(0.25)), closeTo(-36.1, 0.1));
    expect(decibels(Player.gain(0.1)), closeTo(-60, 0.1));
  });

  test('every step down the slider turns it down', () {
    for (var i = 1; i <= 100; i++) {
      expect(Player.gain(i / 100), greaterThan(Player.gain((i - 1) / 100)));
    }
  });
}
