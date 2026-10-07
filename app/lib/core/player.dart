import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'api.dart';
import 'models.dart';
import 'play_queue.dart';

/// Playback: the queue (PlayQueue) plus the audio (media_kit, the mpv engine), the events the server records
/// (play, skip, finish), copies that fail falling back to the song's other copies, and the next songs prefetched.
/// The same behaviour as the Mac app's Player.swift.
///
/// Footprint: listeners hear about changes of song, play/pause, buffering, the queue and Now Playing, never about
/// the position. The position is read once a second by the one widget that shows it (`positionTicks`), and only
/// while a song plays.
class Player extends ChangeNotifier {
  final _audio = mk.Player(configuration: const mk.PlayerConfiguration(title: 'NoNonsense', logLevel: mk.MPVLogLevel.error));
  final queue = PlayQueue();
  final List<StreamSubscription> _subs = [];

  /// The playing song's id, on its own: song rows listen to this, not to every play/pause and buffering change.
  final currentId = ValueNotifier<String?>(null);
  bool isPlaying = false;
  bool isBuffering = false;
  bool showNowPlaying = false;
  double volume = 1;
  String? message; // "Couldn't play …", shown for a few seconds
  Timer? _messageTimer;

  int _copy = 0; // which of the current song's listings is loaded
  int _failuresInARow = 0;
  bool _reported = false; // the current song's "play" was sent

  Player() {
    _subs.add(_audio.stream.playing.listen((p) => _set(() => isPlaying = p)));
    _subs.add(_audio.stream.buffering.listen((b) => _set(() => isBuffering = b)));
    _subs.add(_audio.stream.completed.listen((done) {
      if (done) _ended();
    }));
    _subs.add(_audio.stream.error.listen((_) => _failed()));
    _subs.add(_audio.stream.duration.listen((d) {
      if (d > Duration.zero) {
        _failuresInARow = 0; // this song loads: the run of failures is over
        if (!_reported) {
          _reported = true;
          _report('play', current, 0);
        }
      }
    }));
  }

  Track? get current => queue.current;
  double get position => _audio.state.position.inMilliseconds / 1000;
  double get duration {
    final d = _audio.state.duration.inMilliseconds / 1000;
    return d > 0 ? d : (current?.duration.toDouble() ?? 0);
  }

  /// One tick a second while playing: what the progress line and the times listen to (nothing else redraws).
  Stream<double> get positionTicks => Stream.periodic(const Duration(seconds: 1), (_) => position);

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  // MARK: queue

  void play(List<Track> tracks, {int startAt = 0, List<String>? keys, String? source, bool shuffled = false}) {
    _skipIfPlaying();
    queue.load(tracks, startAt, keys: keys, source: source, shuffled: shuffled);
    _start();
  }

  void playNext(Track t) {
    if (current == null) return play([t]);
    queue.insertNext(t);
    _announce();
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (current == null) return play([t]);
    queue.append(t);
    _announce();
    notifyListeners();
  }

  void next() {
    _skipIfPlaying();
    _go(queue.indexAfterNext());
  }

  void previous() {
    if (position > 3) return seek(0);
    _skipIfPlaying();
    _go(queue.indexAfterPrevious());
  }

  void jump(int i) {
    _skipIfPlaying();
    _go(i);
  }

  void moveUpNext(int from, int to) {
    queue.moveUpcoming(from, to);
    _announce();
    notifyListeners();
  }

  void removeFromUpNext(int offset) {
    queue.removeUpcoming(offset);
    _announce();
    notifyListeners();
  }

  void toggleShuffle() {
    queue.setShuffle(!queue.isShuffled);
    _announce();
    notifyListeners();
  }

  void cycleRepeat() => _set(() => queue.repeat = queue.repeat.next);

  void togglePlayPause() {
    if (current == null) return;
    _audio.playOrPause();
  }

  void seek(double seconds) => _audio.seek(Duration(milliseconds: (seconds * 1000).round()));
  void seekBy(double seconds) => seek((position + seconds).clamp(0, duration));

  void setVolume(double v) {
    volume = v.clamp(0, 1);
    _audio.setVolume(volume * 100);
    notifyListeners();
  }

  void setShowNowPlaying(bool on) => _set(() => showNowPlaying = on && current != null);

  // MARK: loading

  void _go(int? i) {
    if (i == null) {
      _audio.pause();
      seek(0);
      return;
    }
    queue.moveTo(i);
    _start();
  }

  void _start() {
    final t = current;
    if (t == null) return;
    _copy = 0;
    _reported = false;
    currentId.value = t.id;
    _load(t.listings[0]);
    _announce();
    notifyListeners();
  }

  void _load(Listing l, {bool fresh = false}) {
    _audio.open(mk.Media(Api.playUrl(l, fresh: fresh)));
  }

  /// A copy failed: the next copy at once (and the server told, so its cache fetches a fresh link); after the last
  /// copy, the next song. Three songs in a row that will not play stop the player instead of cycling the queue.
  void _failed() {
    final t = current;
    if (t == null) return;
    if (_copy + 1 < t.listings.length) {
      _copy++;
      _show("That ${t.listings[_copy - 1].sourceName} copy didn't load. Playing the ${t.listings[_copy].sourceName} copy.");
      _load(t.listings[_copy]);
      return;
    }
    _failuresInARow++;
    if (_failuresInARow >= 3) {
      _failuresInARow = 0;
      _audio.pause();
      _show("Stopped: “${t.title}” and the two before it didn't play. Press play to try again.");
      return;
    }
    _show("Couldn't play “${t.title}”.");
    _go(queue.indexAfterNext());
  }

  void _ended() {
    _report('finish', current, duration.round());
    _go(queue.indexAfterEnd());
  }

  void _skipIfPlaying() {
    final t = current;
    if (t == null || !_reported) return;
    final at = position;
    if (duration - at > 3) _report('skip', t, at.round());
  }

  void _report(String type, Track? t, int at) {
    if (t == null) return;
    Api.event(t.listings, type, at).catchError((_) {});
  }

  /// The next 5 songs start from the server's cache.
  void _announce() => Api.prefetch(queue.upNext.take(5).map((t) => t.best).toList()).catchError((_) {});

  void _show(String text) {
    message = text;
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 4), () => _set(() => message = null));
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _audio.dispose();
    super.dispose();
  }
}
