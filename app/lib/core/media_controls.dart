import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'player.dart';

/// Exposes playback to the system's media controls. On Windows, the System Media Transport Controls (SMTC): the media
/// keys, and the overlay with the song and its cover that appears when the user presses them or changes the volume. On
/// Android, a media session (audio_service): the notification and lock-screen controls, and the foreground service that
/// keeps a backgrounded app allowed to fetch audio. Without it Android cut the app's network once it was in the
/// background: the song stopped when its buffer ran out, and went on when the app was opened (13 Oct).
///
/// The player reports song changes and play or pause transitions, never a per-second position: Windows' overlay carries
/// no running progress, and Android's runs the position on from the last one reported. Nothing on other platforms.
class MediaControls {
  final Player player;
  SMTCWindows? _smtc;
  StreamSubscription? _buttons;
  String? _shown;
  bool? _playing;
  static _AndroidSession? _session;

  MediaControls(this.player);

  /// Initialize the platform's API, before the app starts.
  static Future<void> initialize() async {
    if (Platform.isWindows) await SMTCWindows.initialize();
    if (Platform.isAndroid) {
      _session = await AudioService.init(
        builder: _AndroidSession.new,
        // kept in the foreground while paused: resumed from the lock screen, Android 12+ refuses to bring a background
        // service back to the foreground (ForegroundServiceStartNotAllowedException, audio_service's README)
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.nononsense.playback',
          androidNotificationChannelName: 'Playback',
          androidStopForegroundOnPause: false,
          // the logo's mark in one colour: Android draws a small icon from its shape, and the launcher icon's was a square
          androidNotificationIcon: 'drawable/ic_stat_nononsense',
        ),
      );
    }
  }

  /// Route the system's buttons to the player and start mirroring the player's state.
  void start() {
    if (Platform.isAndroid) {
      _session?.player = player;
      player.addListener(_changed);
      return;
    }
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
    final session = _session;
    if (session != null) return session.mirror(player);
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

  /// Stop mirroring the player and release the SMTC overlay.
  void dispose() {
    player.removeListener(_changed);
    _buttons?.cancel();
    _smtc?.dispose();
  }
}

/// Android's media session: its buttons drive the player, and it shows the song and whether it plays.
class _AndroidSession extends BaseAudioHandler with SeekHandler {
  Player? player;
  String? _shown;

  void mirror(Player p) {
    final t = p.current;
    if (t == null) {
      _shown = null;
      mediaItem.add(null);
      playbackState.add(PlaybackState());                    // idle: the service leaves the foreground
      return;
    }
    if (_shown != t.id) {
      _shown = t.id;
      mediaItem.add(MediaItem(id: t.id, title: t.title, artist: t.artistLine, album: t.best.album,
          duration: Duration(seconds: t.best.duration), artUri: t.image == null ? null : Uri.tryParse(t.image!)));
    }
    playbackState.add(PlaybackState(
      controls: [MediaControl.skipToPrevious, p.isPlaying ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {MediaAction.seek},
      processingState: p.isBuffering ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: p.isPlaying,
      updatePosition: Duration(milliseconds: (p.position * 1000).round()),
    ));
  }

  @override
  Future<void> play() async {
    if (player?.isPlaying == false) player!.togglePlayPause();
  }

  @override
  Future<void> pause() async {
    if (player?.isPlaying == true) player!.togglePlayPause();
  }

  @override
  Future<void> skipToNext() async => player?.next();

  @override
  Future<void> skipToPrevious() async => player?.previous();

  @override
  Future<void> seek(Duration position) async => player?.seek(position.inMilliseconds / 1000);
}
