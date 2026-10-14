// Windows' audio plugin on a real Windows machine (#28): a sound loads and plays, and is never reported finished
// before it has played. pub.dev's just_audio_windows 0.2.3 said "completed" the moment the sound loaded (measured on
// GitHub's Windows runner, 14 Oct: idle → loading → completed → completed+playing), which the app takes as the song
// having ended. Run by .github/workflows/windows-audio.yml. The runner has no sound device, so the position does not
// move there; it is printed, not checked.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';

/// A [seconds]-long 440 Hz tone as a 16-bit mono WAV file: no audio file kept in the repository.
Uint8List tone({required int seconds, int rate = 44100}) {
  final samples = seconds * rate;
  final b = ByteData(44 + samples * 2);
  void text(int at, String s) => s.codeUnits.asMap().forEach((i, c) => b.setUint8(at + i, c));
  text(0, 'RIFF');
  b.setUint32(4, 36 + samples * 2, Endian.little);
  text(8, 'WAVEfmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  text(36, 'data');
  b.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final v = (8000 * (((i * 440 * 2) ~/ rate).isEven ? 1 : -1));     // a square wave
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a sound loads and plays, and is not reported finished before it has played', (tester) async {
    await tester.runAsync(() async {
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}nn_tone.wav')..writeAsBytesSync(tone(seconds: 4));
      final player = AudioPlayer();
      final states = <String>[];
      final watching = player.playerStateStream.listen((s) => states.add('${s.processingState.name}${s.playing ? '+playing' : ''}'));
      await player.setFilePath(file.path);
      final played = player.play();
      await Future<void>.delayed(const Duration(seconds: 3));
      final at = player.position;
      // ignore: avoid_print
      print('AUDIO-CHECK states: ${states.join(' → ')}');
      // ignore: avoid_print
      print('AUDIO-CHECK position after 3 s: ${at.inMilliseconds} ms');
      await player.stop();
      await played;
      await watching.cancel();
      await player.dispose();
      expect(states, contains('ready+playing'), reason: states.join(' → '));
      expect(states.where((s) => s.startsWith('completed')), isEmpty, reason: states.join(' → '));
    });
  }, skip: !Platform.isWindows);
}
