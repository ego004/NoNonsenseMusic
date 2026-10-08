// YouTube links looked up by this device (YouTubeLookup, 8 Oct), against the real YouTube:
//   flutter test test/youtube_test.dart --dart-define=YOUTUBE=1
// Skipped otherwise: it needs the internet, and YouTube.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/youtube.dart';

const online = String.fromEnvironment('YOUTUBE') != '';

void main() {
  test('a music track: looked up here, remembered, and served past its first megabyte', () async {
    final yt = YouTubeLookup();
    final watch = Stopwatch()..start();
    final url = await yt.audioUrl('J7p4bzqLvCw'); // a music track: the kind the Android client cut off at 1 MB
    final took = watch.elapsedMilliseconds;
    expect(Uri.parse(url).scheme, 'https');
    watch.reset();
    expect(await yt.audioUrl('J7p4bzqLvCw'), url, reason: 'the remembered link');
    expect(watch.elapsedMilliseconds, lessThan(50));
    final piece = await http.get(Uri.parse(url), headers: {'Range': 'bytes=3000000-3000999'});
    expect(piece.statusCode, 206, reason: 'a piece 3 MB in (lookup took $took ms)');
    expect(piece.bodyBytes.length, 1000);
    yt.forget('J7p4bzqLvCw');
    expect(await yt.audioUrl('J7p4bzqLvCw'), isNot(url), reason: 'forgotten: looked up again, a new link');
  }, skip: online ? null : 'needs --dart-define=YOUTUBE=1 (the internet and YouTube)');
}
