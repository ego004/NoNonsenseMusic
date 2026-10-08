import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'api.dart';
import 'models.dart';
import 'play_queue.dart';

/// Playback: the queue (PlayQueue) plus the audio, the events the server records (play, skip, finish), copies that
/// fail falling back to the song's other copies, and the next songs prefetched. The same behaviour as the Mac app's
/// Player.swift.
///
/// The audio is each system's own player (just_audio): Media Foundation on Windows, ExoPlayer on Android, AVPlayer on
/// the Mac preview. A bundled engine (mpv, through media_kit) cost ~1.05% of a core on its own while playing, the
/// whole budget, whatever its buffers (measured 8 Oct with the kernel's CPU account); the system's player is what
/// the Mac app uses at ~0.3% in all.
///
/// Footprint: listeners hear about changes of song, play/pause, buffering, the queue and Now Playing, never about
/// the position, which is read when needed (`readPosition`).
class Player extends ChangeNotifier {
  final _audio = ja.AudioPlayer();
  final queue = PlayQueue();
  final List<StreamSubscription> _subs = [];

  /// The playing song's id, on its own: song rows listen to this, not to every play/pause and buffering change.
  final currentId = ValueNotifier<String?>(null);
  bool isPlaying = false;
  bool isBuffering = false;
  bool showNowPlaying = false;
  /// Beside the song in Now Playing: 'upNext', 'lyrics' or 'none'.
  String panel = 'upNext';
  double volume = 1;
  String? message; // "Couldn't play …", shown for a few seconds
  Timer? _messageTimer;

  int _copy = 0; // which of the current song's listings is loaded
  int _failuresInARow = 0;
  bool _reported = false; // the current song's "play" was sent
  int _loads = 0; // each load's number: news about a replaced copy is ignored
  bool _loading = false;

  Player() {
    _subs.add(_audio.playerStateStream.listen((st) {
      final playing = st.playing && st.processingState != ja.ProcessingState.completed;
      final buffering = st.playing && (st.processingState == ja.ProcessingState.loading || st.processingState == ja.ProcessingState.buffering);
      if (playing != isPlaying || buffering != isBuffering) _set(() { isPlaying = playing; isBuffering = buffering; });
      if (st.processingState == ja.ProcessingState.ready && !_reported) {
        _reported = true;
        _failuresInARow = 0; // this song loads: the run of failures is over
        _report('play', current, 0);
      }
      if (st.processingState == ja.ProcessingState.completed) _ended();
    }));
    // a copy that dies while playing; a failed load is caught in _load (counted once, not twice)
    _subs.add(_audio.playbackEventStream.listen((_) {}, onError: (Object _, StackTrace _) { if (!_loading) _failed(); }));
  }

  /// Where the song is now (the player keeps it: no reports per second).
  Future<double> readPosition() async => position;

  Track? get current => queue.current;
  double get position => _audio.position.inMilliseconds / 1000;
  double get duration {
    final d = (_audio.duration?.inMilliseconds ?? 0) / 1000;
    return d > 0 ? d : (current?.duration.toDouble() ?? 0);
  }


  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  // MARK: queue

  Future<void> play(List<Track> tracks, {int startAt = 0, List<String>? keys, String? source, bool shuffled = false}) async {
    await _skipIfPlaying();
    queue.load(tracks, startAt, keys: keys, source: source, shuffled: shuffled);
    _start();
  }

  void playNext(Track t) {
    if (current == null) { play([t]); return; }
    queue.insertNext(t);
    _announce();
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (current == null) { play([t]); return; }
    queue.append(t);
    _announce();
    notifyListeners();
  }

  Future<void> next() async {
    await _skipIfPlaying();
    _go(queue.indexAfterNext());
  }

  Future<void> previous() async {
    if (await readPosition() > 3) return seek(0);
    await _skipIfPlaying();
    _go(queue.indexAfterPrevious());
  }

  Future<void> jump(int i) async {
    await _skipIfPlaying();
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

  /// A playlist changed: if the queue came from it, the queue follows (PlayQueue.sync).
  void playlistChanged(PlaylistDetail d) {
    if (queue.source != d.queueSource) return;
    queue.sync(d.queueSource, d.items);
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
    _audio.playing ? _audio.pause() : _audio.play();
  }

  void seek(double seconds) {
    _audio.seek(Duration(milliseconds: (seconds * 1000).round()));
    notifyListeners(); // the line and the lyrics follow at once
  }

  Future<void> seekBy(double seconds) async => seek((await readPosition() + seconds).clamp(0, duration));

  double _beforeMute = 1;
  void toggleMute() {
    if (volume > 0) {
      _beforeMute = volume;
      setVolume(0);
    } else {
      setVolume(_beforeMute > 0 ? _beforeMute : 1);
    }
  }

  void setVolume(double v) {
    volume = v.clamp(0, 1);
    _audio.setVolume(volume);
    notifyListeners();
  }

  void setPanel(String p) => _set(() => panel = panel == p ? 'none' : p);

  void setShowNowPlaying(bool on) => _set(() => showNowPlaying = on && current != null);

  /// Signed out: the music stops and the queue empties (the next request would be refused anyway, and the next
  /// account must not inherit this one's queue).
  Future<void> stop() async {
    _loads++; // a load still asking the server says nothing now
    queue.load(const [], 0, shuffled: false);
    currentId.value = null;
    _messageTimer?.cancel();
    _set(() {
      isPlaying = false;
      isBuffering = false;
      showNowPlaying = false;
      message = null;
    });
    await _audio.stop();
  }

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

  Future<void> _load(Listing l, {bool fresh = false}) async {
    final mine = ++_loads;
    _loading = true;
    try {
      // the audio's own address, asked with the token; the player never sees the token (Api.audioUrl)
      final url = await Api.audioUrl(l, fresh: fresh);
      if (mine != _loads) return; // replaced while asking
      await _audio.setUrl(url);
      if (mine == _loads) _audio.play();
    } catch (e) {
      // why a copy did not load (on the Mac preview, YouTube copies fail with -1 "unknown error": TICKETS WIN)
      debugPrint('copy did not load (${l.source}): ${e is ja.PlayerException ? 'code ${e.code}, ${e.message}' : e}');
      if (mine == _loads) _failed(); // a copy that will not load; an older load's failure says nothing now
    } finally {
      if (mine == _loads) _loading = false;
    }
  }

  /// A copy failed: the next copy at once (and the server told, so its cache fetches a fresh link); after the last
  /// copy, the next song. Three songs in a row that will not play stop the player instead of cycling the queue.
  void _failed() {
    final t = current;
    if (t == null) return;
    if (_copy + 1 < t.listings.length) {
      _copy++;
      final failed = t.listings[_copy - 1].sourceName, next = t.listings[_copy].sourceName;
      // "another" when both are from one source: "didn't load. Playing the YouTube Music copy" read as nonsense (8 Oct)
      _show(failed == next ? "That $failed copy didn't load. Playing another $next copy." : "That $failed copy didn't load. Playing the $next copy.");
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

  Future<void> _skipIfPlaying() async {
    final t = current;
    if (t == null || !_reported) return;
    final at = await readPosition();
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
