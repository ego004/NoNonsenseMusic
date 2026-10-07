import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';

/// The playing cover's most vivid colour, made readable: buttons, the progress line and the selection take it, as on
/// the Mac (ThemeStore's "Song"). null for a grey cover: the default accent stays. Worked out once per song from the
/// cover shrunk to 24 × 24 pixels.
class Accent extends ValueNotifier<Color?> {
  Accent() : super(null);
  String? _for;

  Future<void> follow(String? url) async {
    if (url == _for) return;
    _for = url;
    if (url == null) {
      value = null;
      return;
    }
    try {
      final stream = ResizeImage(NetworkImage(url), width: 24, height: 24).resolve(ImageConfiguration.empty);
      final done = Completer<ui.Image>();
      late final ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (!done.isCompleted) done.complete(info.image);
        stream.removeListener(listener);
      }, onError: (e, _) {
        if (!done.isCompleted) done.completeError(e);
      });
      stream.addListener(listener);
      final image = await done.future;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null || url != _for) return;
      Color? best;
      var score = 0.0;
      for (var i = 0; i + 3 < bytes.lengthInBytes; i += 4) {
        final c = Color.fromARGB(255, bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
        final hsl = HSLColor.fromColor(c);
        // vivid, and neither near black nor near white
        final s = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 1.6);
        if (s > score) {
          score = s;
          best = c;
        }
      }
      value = score < 0.18 || best == null ? null : best; // a grey cover keeps the default
    } catch (_) {
      if (url == _for) value = null;
    }
  }

  /// The colour, adjusted so it reads on this background.
  static Color readable(Color c, Brightness b) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness(b == Brightness.dark ? hsl.lightness.clamp(0.58, 0.72) : hsl.lightness.clamp(0.32, 0.45)).withSaturation(hsl.saturation.clamp(0.45, 0.85)).toColor();
  }
}
