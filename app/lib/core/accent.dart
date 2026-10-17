import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';

import 'cover_image.dart';

/// Holds the playing cover's most vivid colour, adjusted so it reads on the current background.
///
/// Buttons, the progress line and the selection take the accent, as on the Mac (ThemeStore's "Song"). The value stays
/// null for a grey cover, so the default accent remains. The colour is worked out once per song from the cover shrunk
/// to 24 × 24 pixels.
class Accent extends ValueNotifier<Color?> {
  Accent() : super(null);
  String? _for;

  /// Sets the accent to the most vivid colour of the cover image at [url].
  ///
  /// A null [url], a load failure or a grey cover set the value to null. A repeat call for the current [url] returns
  /// without decoding the image again.
  Future<void> follow(String? url) async {
    if (url == _for) return;
    _for = url;
    if (url == null) {
      value = null;
      return;
    }
    try {
      // a download's kept cover when there is one: the accent works offline too
      final stream = ResizeImage(coverProvider(url, px: 24), width: 24, height: 24)
          .resolve(ImageConfiguration.empty);
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
        // saturation, reduced by how far lightness sits from the middle: neither near-black nor near-white wins
        final s = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 1.6);
        if (s > score) {
          score = s;
          best = c;
        }
      }
      value = score < 0.18 || best == null ? null : best; // below 0.18 the cover is grey, so the default accent stays
    } catch (_) {
      if (url == _for) value = null;
    }
  }

  /// The accent with no song's colour (Colours › Accent › System, or a grey cover): Windows 11's default blue.
  static Color standard(Brightness b) => b == Brightness.dark ? const Color(0xFF60CDFF) : const Color(0xFF005FB8);

  /// Returns [c] adjusted so it reads on a background of brightness [b].
  ///
  /// Lightness and saturation are clamped to fixed ranges: a colour that suits a light background can disappear
  /// against a dark one, and the reverse. A song's colour is made at least a little [vivid]; a colour the user chose
  /// (Colours › Custom) keeps its own saturation: a grey would have turned red.
  static Color readable(Color c, Brightness b, {bool vivid = true}) {
    final hsl = HSLColor.fromColor(c);
    final lit = hsl.withLightness(b == Brightness.dark ? hsl.lightness.clamp(0.58, 0.72) : hsl.lightness.clamp(0.32, 0.45));
    return (vivid ? lit.withSaturation(hsl.saturation.clamp(0.45, 0.85)) : lit).toColor();
  }
}
