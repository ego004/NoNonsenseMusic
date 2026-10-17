import 'dart:async';
import 'dart:io' show File, FileSystemException, Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'api.dart';
import 'audio_cache.dart';
import 'audio_download.dart';
import 'autoplay.dart';
import 'catalog.dart';
import 'download_store.dart';
import 'loopback_audio.dart';
import 'jam.dart';
import 'models.dart';
import 'mp4_defrag.dart';
import 'play_queue.dart';
import 'youtube.dart';

/// Playback: the queue (PlayQueue) plus the audio, the events the server records (play, skip, finish), copies that
/// fail falling back to the song's other copies, and the next songs prefetched. It has the same behaviour as the
/// Mac app's Player.swift.
///
/// The audio is each system's own player (just_audio): Media Foundation on Windows, ExoPlayer on Android, AVPlayer on
/// the Mac preview. A bundled engine (mpv, through media_kit) cost ~1.05% of a core on its own while playing, the
/// whole budget whatever its buffers; the system's player is what the Mac app uses at ~0.3% in all.
///
/// Footprint: listeners hear about changes of song, play/pause, buffering, the queue and Now Playing, never about
/// the position, which is read when needed (`readPosition`).
class Player extends ChangeNotifier implements JamPlayer {
  final ja.AudioPlayer _audio;
  final queue = PlayQueue();
  final List<StreamSubscription> _subs = [];

  /// The playing song's id, on its own: song rows listen to this, not to every play/pause and buffering change.
  final currentId = ValueNotifier<String?>(null);
  @override
  bool isPlaying = false;
  bool isBuffering = false;
  bool showNowPlaying = false;
  /// Beside the song in Now Playing: 'upNext', 'lyrics' or 'none'.
  String panel = 'upNext';
  double volume = 1;
  String? message; // "Couldn't play …", shown for a few seconds
  Timer? _messageTimer;

  /// Settings › Playback › Autoplay, applied by Settings: on by default.
  static bool autoplay = true;
  static bool autoplaySkipsRecent = true;

  final _autoplay = Autoplay();
  final AudioCache _cache;
  final AudioDownloads _fetches;
  final _downloads = DownloadStore.shared;

  /// How long the player may take to open a copy before it counts as one that will not load.
  @visibleForTesting
  static Duration loadTimeout = const Duration(seconds: 15);

  /// The file the loaded audio plays from (a download or a cached song), or null when it streams from the network. A
  /// file that will not play is deleted and the song is loaded again from the network.
  File? _fromFile;
  bool _fromDownload = false;

  int _copy = 0; // which of the current song's listings is loaded
  final Set<int> _tried = {}; // the copies of the current song already tried: a failed copy is not tried again
  int _failuresInARow = 0;
  bool _reported = false; // the current song's "play" was sent
  int _loads = 0; // each load's number: news about a replaced copy is ignored
  bool _loading = false;
  bool _ready = false; // the loaded copy has been ready: a "completed" before that is the replaced copy's
  // How long the loaded copy has really played, from _heardFrom (its start or the last seek). A copy that "finishes" far
  // sooner than its length did not play: Windows takes a fragmented MP4 with an edit list (YouTube Music's) as already
  // over, jumps to its end and reports it finished, which moved on to the next song without a word
  final _heard = Stopwatch();
  double _heardFrom = 0;
  bool _refetched = false; // this copy's file was already dropped and fetched again once: a second failure moves on

  /// [audio] and [fetches]: tests give fakes; the app uses the system's player and the shared cache.
  Player({ja.AudioPlayer? audio, AudioDownloads? fetches})
      : _audio = audio ?? ja.AudioPlayer(),
        _fetches = fetches ?? AudioDownloads.shared,
        _cache = (fetches ?? AudioDownloads.shared).cache {
    _subs.add(_audio.playerStateStream.listen((st) {
      final playing = st.playing && st.processingState != ja.ProcessingState.completed;
      final buffering = st.playing && (st.processingState == ja.ProcessingState.loading || st.processingState == ja.ProcessingState.buffering);
      playing ? _heard.start() : _heard.stop();
      if (playing != isPlaying || buffering != isBuffering) _set(() { isPlaying = playing; isBuffering = buffering; });
      if (st.processingState == ja.ProcessingState.ready && !_ready) {
        _ready = true;
        _heard.reset(); // heard from when it can be: not while it opened
      }
      if (st.processingState == ja.ProcessingState.ready && !_reported) {
        // the run of failures ends once a song is heard (_ended, _skipIfPlaying), not here: a copy can load and still
        // not play
        _reported = true;
        _report('play', current, 0);
      }
      // while a load runs, "completed" is the previous copy's state, not news: acting on it skipped the song loading.
      // Nor after it, until the new copy has been ready: Windows' player still reported the replaced copy's "completed"
      // once the load had returned, which ended the new copy before it started ("Couldn't play" with a copy that plays,
      // and a jam host skipped the room's song, 15 Oct, #30)
      if (st.processingState == ja.ProcessingState.completed && !_loading && _ready) {
        _endedTooSoon() ? _failed(playing: true) : _ended();
      }
    }));
    // a copy that dies while playing; a failed load is caught in _load (counted once, not twice)
    _subs.add(_audio.playbackEventStream.listen((_) {}, onError: (Object _, StackTrace _) { if (!_loading) _failed(); }));
  }

  /// Where the song is now (the player keeps it: no reports per second).
  Future<double> readPosition() async => position;

  Track? get current => queue.current;

  /// The copy that is loaded: the song's best at first, then the one the user chose, or the next after a failure.
  Listing? get playingListing {
    final t = current;
    return t == null ? null : t.listings[_copy.clamp(0, t.listings.length - 1)];
  }

  @override
  double get position => _audio.position.inMilliseconds / 1000;
  /// The playing copy's length: its audio's, but never past its listed length + 1 s. Apple's player reports YouTube's
  /// AAC files at about twice their length (Blinding Lights, 3:20, showed 6:42 left); the listing's length is the
  /// song's.
  double get duration {
    final audio = (_audio.duration?.inMilliseconds ?? 0) / 1000;
    final t = current;
    final listed = t == null ? 0.0 : t.listings[_copy.clamp(0, t.listings.length - 1)].duration.toDouble();
    if (audio <= 0) return listed;
    return listed > 0 ? math.min(audio, listed + 1) : audio;
  }


  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  // MARK: queue

  /// [wholeList]: a list's own Play or Shuffle button. In a jam it plays the list (up to 50 songs) for the room; every
  /// other call is a tap on one song and plays just that one.
  Future<void> play(List<Track> tracks,
      {int startAt = 0, List<String>? keys, String? source, bool shuffled = false, bool wholeList = false}) async {
    if (jam != null) {
      if (startAt >= tracks.length) return;
      // the jam says what it did (JamSession.add)
      return jam!.add(
          wholeList ? (shuffled ? ([...tracks]..shuffle()) : tracks.sublist(startAt)).take(50).toList() : [tracks[startAt]],
          placement: 'now');
    }
    await _skipIfPlaying();
    queue.load(tracks, startAt, keys: keys, source: source, shuffled: shuffled);
    _autoplay.reset();
    _start();
  }

  void playNext(Track t) {
    if (jam != null) return jam!.add([t], placement: 'next');
    if (current == null) { play([t]); return; }
    queue.insertNext(t);
    _announce();
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (jam != null) return jam!.add([t]);
    if (current == null) { play([t]); return; }
    queue.append(t);
    _announce();
    notifyListeners();
  }

  Future<void> next() async {
    if (jam != null) return jam!.skip();
    await _skipIfPlaying();
    _go(queue.indexAfterNext());
  }

  Future<void> previous() async {
    if (jam != null) return jam!.seek(0); // a jam has no "previous": the song restarts
    if (await readPosition() > 3) return seek(0);
    await _skipIfPlaying();
    _go(queue.indexAfterPrevious());
  }

  Future<void> jump(int i) async {
    await _skipIfPlaying();
    _go(i);
  }

  void moveUpNext(int from, int to, {bool? autoplay}) {
    queue.moveUpcoming(from, to, autoplay: autoplay);
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

  /// Autoplay was switched on: the queue may need songs now.
  void upNextChanged() => _refill();

  void toggleShuffle() {
    queue.setShuffle(!queue.isShuffled);
    _announce();
    notifyListeners();
  }

  void cycleRepeat() => _set(() => queue.repeat = queue.repeat.next);

  int _pauses = 0; // each pause the app asked for: a play retried by _play gives way to one

  /// Starts the audio. On Windows a play can be cancelled before it reaches the player: just_audio_windows reports
  /// what Media Foundation is doing ("not playing" while it opens a file) where just_audio expects what was asked
  /// for, and just_audio adopts the report. One that lands while play() is starting turns it back off, and play() then
  /// returns without telling the plugin (12 Oct: a JioSaavn song from the cache, and so a jam host's song, never
  /// started, with no error). So on Windows a play that has not taken is asked again for a moment, unless the song
  /// changed or something paused it meanwhile.
  void _play() {
    _audio.play();
    if (!Platform.isWindows) return;
    final load = _loads, pauses = _pauses;
    () async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (load != _loads || pauses != _pauses || _audio.playing) return;
        _audio.play();
      }
    }();
  }

  void _pause() {
    _pauses++;
    _audio.pause();
  }

  void togglePlayPause() {
    if (jam != null) return jam!.setPlaying(!isPlaying); // what the button shows, as on the Mac (docs/jam.md)
    if (current == null) return;
    _audio.playing ? _pause() : _play();
  }

  void seek(double seconds) {
    if (jam != null) return jam!.seek(seconds);
    _seekLocal(seconds);
  }

  void _seekLocal(double seconds) {
    _heard.reset();
    _heardFrom = seconds;
    _audio.seek(Duration(milliseconds: (seconds * 1000).round()));
    notifyListeners(); // the line and the lyrics follow at once
  }

  Future<void> seekBy(double seconds) async {
    seek((await readPosition() + seconds).clamp(0, duration));
  }

  /// Now Playing's source menu: the song now playing switches to another of its copies and carries on from the same
  /// second, paused if it was paused. The cover and the queue do not change, only the audio.
  void switchCopy(Listing listing) {
    final t = current;
    if (t == null) return;
    final i = t.listings.indexWhere((l) => l.key == listing.key);
    if (i < 0 || i == _copy) return;
    final at = position, wasPlaying = isPlaying;
    _tried
      ..clear()
      ..add(i);
    _copy = i;
    _refetched = false;
    _load(t.listings[i], start: wasPlaying, resumeAt: at);
    notifyListeners();
  }

  double _beforeMute = 1;
  void toggleMute() {
    if (volume > 0) {
      _beforeMute = volume;
      setVolume(0);
    } else {
      setVolume(_beforeMute > 0 ? _beforeMute : 1);
    }
  }

  /// [v] is the slider's place, 0…1; the player is given [gain] of it.
  void setVolume(double v) {
    volume = v.clamp(0, 1);
    _audio.setVolume(_jamSilent ? 0 : gain(volume));
    notifyListeners();
  }

  /// The gain for a slider place: its cube. Players take a linear gain, but loudness is heard in ratios, so a straight
  /// line put nearly all of the change in the slider's last stretch (a quarter of the way was still -12 dB, barely
  /// quieter than full). The cube spreads it out: half is -18 dB, a quarter -36 dB, a tenth -60 dB.
  static double gain(double place) => place * place * place;

  bool _jamSilent = false;
  @override
  void jamSetSilent(bool silent) {
    if (silent == _jamSilent) return;
    _jamSilent = silent;
    _audio.setVolume(silent ? 0 : gain(volume));
  }

  void setPanel(String p) => _set(() => panel = panel == p ? 'none' : p);

  void setShowNowPlaying(bool on) => _set(() => showNowPlaying = on && current != null);

  /// Signed out: the music stops and the queue empties (the next request would be refused anyway, and the next
  /// account must not inherit this one's queue).
  Future<void> stop() async {
    _loads++; // a load still asking the server says nothing now
    queue.load(const [], 0, shuffled: false);
    _autoplay.reset();
    currentId.value = null;
    _fetches.keep({});
    _messageTimer?.cancel();
    _resumeAt = null;
    _set(() {
      isPlaying = false;
      isBuffering = false;
      showNowPlaying = false;
      message = null;
    });
    await _audio.stop();
  }

  // MARK: jam (JamSession)

  /// In a jam the room decides what plays, and the transport sends it commands; null otherwise.
  @override
  JamSession? jam;
  double? _resumeAt; // where the room's song was when it was loaded: the room's playhead once ready (JamSession.playhead)
  bool _startPaused = false; // the room is paused: the loaded song waits

  @override
  bool get jamLoading => _loading;

  @override
  String? get jamPlayingKey => playingListing?.key;

  @override
  JamSong? get jamSong {
    final t = current, playing = playingListing;
    if (t == null || playing == null) return null;
    return JamSong(playing, position, playing: isPlaying, copies: JamCommand.otherCopies(t, playing: playing));
  }

  @override
  Future<List<Track>> jamRadio(Listing seed, List<Listing> exclude) async =>
      autoplay ? Catalog.radio(seed, exclude, limit: 10, skipRecent: autoplaySkipsRecent) : const <Track>[];

  @override
  void jamSay(String text) => _show(text);

  /// The host's player: the room's current song, from the room's playhead.
  @override
  Future<void> jamLoad(Track track, double at, {required bool playing}) async {
    await _skipIfPlaying();
    queue.load([track], 0, source: 'jam', shuffled: false);
    _startPaused = !playing;
    _start();
    _resumeAt = at;
    if (!playing) _pause();
  }

  /// The host's player: playing or paused as the room is. While a song loads, the load starts it or not.
  @override
  void jamFollowPlaying(bool playing) {
    _startPaused = !playing;
    if (_loading || _audio.playing == playing) return;
    playing ? _play() : _pause();
  }

  /// The host's player: the room's playhead after someone seeked.
  @override
  void jamFollowSeek(double seconds) => _seekLocal(seconds);

  // MARK: loading

  void _go(int? i) {
    if (i == null) {
      _pause();
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
    _tried
      ..clear()
      ..add(0);
    _reported = false;
    _refetched = false;
    currentId.value = t.id;
    _load(t.listings[0]);
    _announce();
    notifyListeners();
  }

  /// Loads [l] and plays it, or leaves it paused with [start] false. [resumeAt] is the second to carry on from when a
  /// copy is chosen in the middle of a song; a second or less, or the last two, start the copy from its beginning.
  Future<void> _load(Listing l, {bool fresh = false, bool start = true, double? resumeAt}) async {
    final mine = ++_loads;
    _loading = true;
    _ready = false;
    try {
      final uri = await _plan(l, fresh: fresh);
      if (mine != _loads) return; // replaced while asking
      final child = ja.AudioSource.uri(uri);
      // Bounded, so that a copy the player never finishes opening fails like any other and the next one is tried:
      // Windows' player, given a file that is not there, stayed "loading" with no error, and the song sat at 0:00
      // (15 Oct, #30). Only the player's own opening counts: a slow fetch in _plan is not timed.
      if (Platform.isMacOS || Platform.isIOS) {
        // Apple's player: the song ends at its listed length + 1 s, as in the Mac app (a misread length played on in
        // silence there); the clip is AVPlayer's own end time, nothing measured per second
        await _audio
            .setAudioSource(ja.ClippingAudioSource(child: child, end: l.duration > 0 ? Duration(seconds: l.duration + 1) : null))
            .timeout(loadTimeout);
      } else {
        await _audio.setAudioSource(child).timeout(loadTimeout);
      }
      if (mine != _loads) return;
      // a copy chosen mid-song (resumeAt) or the room's song in a jam (_resumeAt) carries on from that second; a second
      // or less, or the last two, start from the beginning
      final at = resumeAt ?? (_resumeAt != null ? jam?.playhead ?? _resumeAt : null);
      _resumeAt = null;
      var from = 0.0;
      if (at != null && at > 1) {
        final length = _audio.duration;
        if (length == null || at < length.inMilliseconds / 1000 - 2) {
          await _audio.seek(Duration(milliseconds: (at * 1000).round()));
          from = at;
        }
      }
      if (mine != _loads) return;
      _heard.reset();
      // where the copy starts, as asked, not as read back: Windows' player can still report the replaced copy's place
      // (224 s of a copy that had not started), which made a copy that ended at once look heard to its end (#30)
      _heardFrom = from;
      if (start && !(jam != null && _startPaused)) _play();
    } catch (e) {
      // why a copy did not load (on the Mac preview, YouTube copies fail with -1 "unknown error")
      debugPrint('copy did not load (${l.source}): ${e is ja.PlayerException ? 'code ${e.code}, ${e.message}' : e}');
      if (mine != _loads) return; // an older load's failure says nothing now
      // a file that will not play is deleted and the song fetched again, once, before any other copy is tried
      if (await _refetch(l, start: start, resumeAt: resumeAt)) return;
      if (mine == _loads) _failed(); // a copy that will not load
    } finally {
      if (mine == _loads) _loading = false;
    }
  }

  /// The address to play [l] from: its downloaded file, else its cached file, else the network. With the cache on, a
  /// song from the network is fetched whole in bounded ranges while it plays (LoopbackAudio serves it to the player)
  /// and kept; with it off, the player gets the audio's own address as before.
  Future<Uri> _plan(Listing l, {bool fresh = false}) async {
    _fromFile = null;
    final t = current;
    if (t != null && _downloads.folder != null) {
      // the default copy plays whichever copy of the song was downloaded; another copy only when it is the one downloaded
      final saved = _downloads.fileFor(t, copy: l.key == t.listings.first.key ? null : l);
      if (saved != null && saved.existsSync()) {
        // the user's own file: one that cannot be made playable is passed over for the next copy, never deleted
        await _plain(saved);
        _fromFile = saved;
        _fromDownload = true;
        return saved.uri;
      }
    }
    final cached = _cache.file(l.key);
    if (cached != null) {
      _fromFile = cached; // first: a cached file that cannot be made playable is deleted and fetched again
      _fromDownload = false;
      return (await _plain(cached)).uri;
    }
    final url = await Api.audioUrl(l, fresh: fresh);
    // Windows cannot play YouTube Music's fragmented MP4 as it arrives (see Mp4Defrag): a YouTube copy is fetched whole
    // first, with the cache off too (its file then goes at the next song's fetch, AudioCache.evict); given the link
    // instead, Windows ended a YouTube Music copy at once (15 Oct, #30). Bounded ranges come at full speed, so that is a
    // second or two on a good connection
    if (Platform.isWindows && YouTubeLookup.resolvesOnDevice(l.source) && _cache.folder != null) {
      final download = _fetches.fetch(l.key, Uri.parse(url))..start();
      _fetches.keep(_wanted(l.key));
      await download.whole();
      if (!download.isComplete) {
        throw StateError('The audio did not arrive whole: ${download.failure ?? (download.isCancelled ? 'cancelled' : 'unfinished')}');
      }
      final file = _cache.path(l.key);
      _fromFile = file;
      _fromDownload = false;
      return (await _plain(file)).uri;
    }
    if (!_cache.enabled) return Uri.parse(url);
    try {
      final download = _fetches.fetch(l.key, Uri.parse(url))..start();
      _fetches.keep(_wanted(l.key));
      return await LoopbackAudio.shared.serve(download);
    } catch (_) {
      return Uri.parse(url); // the loopback server could not start: the audio plays as it did without a cache
    }
  }

  /// [f], ready for the player: on Windows rewritten as a plain MP4 when it is a fragmented one (YouTube's, see
  /// Mp4Defrag). Throws when [f] is not there or cannot be rewritten, which fails the load. Both were handed to the
  /// player before: a YouTube Music copy left fragmented ended at once, and a missing file never finished opening, so
  /// the song sat at 0:00 with no word (15 Oct, #30).
  Future<File> _plain(File f) async {
    if (!f.existsSync()) throw FileSystemException('The audio file is not there', f.path);
    if (Platform.isWindows) await Mp4Defrag.ensurePlain(f);
    return f;
  }

  /// Whether the copy that just "finished" stopped far short of its length: heard for under half of what was left
  /// when it started or was last moved, on a song long enough to tell.
  bool _endedTooSoon() {
    final left = duration - _heardFrom;
    return left > 10 && _heard.elapsedMilliseconds / 1000 < left / 2;
  }

  /// Deletes the file the loaded audio plays from, when it plays from one. Returns whether there was one.
  Future<bool> _dropFile() async {
    final f = _fromFile;
    if (f == null) return false;
    _fromFile = null;
    try {
      if (_fromDownload) {
        await _downloads.dropFile(f);
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (e) {
      // another program has it open: the copy is loaded again all the same, and the next copy follows if it fails
      // again (unhandled, this error stopped the song from loading again at all)
      debugPrint('could not delete ${f.path}: $e');
    }
    return true;
  }

  /// A copy that would not play from its file: the file is deleted and the copy loaded again from the network, with a
  /// new link, once; then the next copy is tried. Returns whether it loaded it again.
  Future<bool> _refetch(Listing l, {required bool start, double? resumeAt}) async {
    if (_refetched || _fromFile == null) return false;
    _refetched = true;
    final load = _loads;
    await _dropFile();
    if (load != _loads) return true; // another copy or song was loaded meanwhile
    if (YouTubeLookup.resolvesOnDevice(l.source)) YouTubeLookup.instance.forget(l.id);
    await _load(l, start: start, resumeAt: resumeAt);
    return true;
  }

  /// The songs whose fetch is worth keeping: the playing one and the next.
  Set<String> _wanted(String? playing) {
    final next = queue.upNext.firstOrNull?.listings.first.key;
    return {?playing, ?next};
  }

  /// A copy failed: the next copy at once (and the server told, so its cache fetches a fresh link); after the last
  /// copy, the next song. Three songs in a row that will not play stop the player instead of cycling the queue.
  /// [playing]: the copy was meant to be playing, though the player no longer says so (it "finished" too soon).
  void _failed({bool playing = false}) {
    final t = current;
    if (t == null) return;
    final start = playing || isPlaying || _loading || !_reported;
    if (_fromFile != null && !_refetched) {
      // a file that stopped playing: deleted, and the same copy loaded again from the network, once
      unawaited(_refetch(t.listings[_copy], start: start));
      return;
    }
    // a YouTube link this device looked up and that would not play: never handed out again
    final failedCopy = t.listings[_copy];
    if (YouTubeLookup.resolvesOnDevice(failedCopy.source)) YouTubeLookup.instance.forget(failedCopy.id);
    _tried.add(_copy);
    final next = List.generate(t.listings.length, (i) => i).where((i) => !_tried.contains(i)).firstOrNull;
    if (next != null) {
      final failed = failedCopy.sourceName, to = t.listings[next].sourceName;
      _copy = next;
      _tried.add(next);
      _refetched = false;
      // "another" when both copies are from one source: "didn't load. Playing the YouTube Music copy" reads as nonsense
      _show(failed == to ? "That $failed copy didn't load. Playing another $to copy." : "That $failed copy didn't load. Playing the $to copy.");
      // paused by the user and then failing hands over paused; a copy that failed while loading was meant to play
      _load(t.listings[next], start: start);
      return;
    }
    // In a jam a copy failing is this device's alone: the room plays on, and this device waits for the next song
    // (docs/jam.md). A skip here moved the room on for everyone: a member's failure until 12 Oct, the host's until 17 Oct
    if (jam != null) return _show("Couldn't play “${t.title}”. The jam plays on.");
    _failuresInARow++;
    if (_failuresInARow >= 3) {
      _failuresInARow = 0;
      _pause();
      _show("Stopped: “${t.title}” and the two before it didn't play. Press play to try again.");
      return;
    }
    _show("Couldn't play “${t.title}”.");
    _go(queue.indexAfterNext());
  }

  void _ended() {
    _failuresInARow = 0; // a song played to its end
    _report('finish', current, duration.round());
    if (jam != null) return jam!.songEnded(); // the room moves on at the first device to finish (docs/jam.md)
    _go(queue.indexAfterEnd());
  }

  Future<void> _skipIfPlaying() async {
    final t = current;
    if (t == null || !_reported) return;
    if (_heard.elapsed >= const Duration(seconds: 3)) _failuresInARow = 0; // this one was heard before moving on
    final at = await readPosition();
    if (duration - at > 3) _report('skip', t, at.round());
  }

  void _report(String type, Track? t, int at) {
    if (t == null) return;
    Api.event(t.listings, type, at).catchError((_) {});
  }

  /// The next [prefetchAhead] songs are made ready: their audio links looked up, so they start at once.
  static const prefetchAhead = 2;

  void _announce() {
    Api.prefetch(queue.upNext.take(prefetchAhead).map((t) => t.best).toList()).catchError((_) {});
    // the next song whole, once the playing one is all in; a song that is neither is no longer fetched
    final playing = playingListing?.key;
    _fetches.keep(_wanted(playing));
    _fetches
        .prefetchNext(playingKey: playing, next: queue.upNext.firstOrNull?.listings.first,
            linkFor: (l) async => Uri.parse(await Api.audioUrl(l)))
        .catchError((_) {});
    _refill();
  }

  /// Asks the server's radio for songs like the last one the user chose when Up Next runs low (see [Autoplay]).
  Future<void> _refill() async {
    final due = _autoplay.due(queue, enabled: autoplay, blocked: jam != null);
    if (due == null) return;
    final List<Track> songs;
    try {
      songs = await Catalog.radio(due.seed, due.exclude, skipRecent: autoplaySkipsRecent);
    } catch (_) {
      return; // not asked again until the queue's last song changes, or a new queue
    }
    if (songs.isEmpty || queue.tracks.lastOrNull?.id != due.lastId) return; // the queue changed meanwhile
    final queued = {for (final t in queue.tracks) ...t.listings.map((l) => l.key)};
    final fresh = songs.where((t) => !t.listings.any((l) => queued.contains(l.key)));
    if (fresh.isEmpty) return;
    for (final t in fresh) {
      queue.appendAutoplay(t);
    }
    _announce();
    notifyListeners();
  }

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
