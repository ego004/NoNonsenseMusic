import 'dart:async';
import 'dart:io';

import 'package:smtc_windows/smtc_windows.dart';

import 'player.dart';

/// Windows' own media controls: the media keys, and the overlay with the song and its cover that appears when you
/// press them or change the volume (System Media Transport Controls). Told about a new song, play and pause; never
/// per second. Windows only: on the Mac preview it does nothing.
class MediaControls {
  final Player player;
  SMTCWindows? _smtc;
  StreamSubscription? _buttons;
  String? _shown;
  bool? _playing;

  MediaControls(this.player);

  static Future<void> initialize() async {
    if (Platform.isWindows) await SMTCWindows.initialize();
  }

  void start() {
    if (!Platform.isWindows) return;
    _smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true, pauseEnabled: true, nextEnabled: true, prevEnabled: true,
        stopEnabled: false, fastForwardEnabled: false, rewindEnabled: false,
      ),
    );
    _buttons = _smtc!.buttonPressStream.listen((b) {
      switch (b) {
        case PressedButton.play || PressedButton.pause:
          player.togglePlayPause();
        case PressedButton.next:
          player.next();
        case PressedButton.previous:
          player.previous();
        default:
          break;
      }
    });
    player.addListener(_changed);
  }

  void _changed() {
    final smtc = _smtc, t = player.current;
    if (smtc == null) return;
    if (t == null) {
      if (_shown != null) smtc.clearMetadata();
      _shown = null;
      return;
    }
    if (_shown != t.id) {
      _shown = t.id;
      smtc.updateMetadata(MusicMetadata(title: t.title, artist: t.artistLine, album: t.best.album ?? '', albumArtist: t.artistLine, thumbnail: t.image));
    }
    if (_playing != player.isPlaying) {
      _playing = player.isPlaying;
      smtc.setPlaybackStatus(player.isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused);
    }
  }

  void dispose() {
    player.removeListener(_changed);
    _buttons?.cancel();
    _smtc?.dispose();
  }
}
