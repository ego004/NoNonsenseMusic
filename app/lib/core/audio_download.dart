import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'audio_cache.dart';
import 'models.dart';
import 'range_fetcher.dart';

/// One song's audio, fetched once from its start to its end in bounded ranges and written to a file as the ranges
/// arrive, so a song is never held in memory. The player is fed from it while it arrives (see LoopbackAudio); a seek
/// far past what has arrived is fetched on its own. Complete, the `.part` file is renamed to [target].
class AudioDownload {
  AudioDownload({required this.key, required this.link, required this.target, required this.fetcher, this.onDone})
      : _length = int.tryParse(link.queryParameters['clen'] ?? ''); // YouTube's links say the length

  final String key;
  final Uri link;
  final File target;
  final RangeFetcher fetcher;

  /// Called once the file is in place.
  final void Function()? onDone;

  File get _part => File('${target.path}.part');
  int _received = 0;
  int? _length;
  bool _started = false, _finished = false, _cancelled = false, _renamed = false;
  Object? _failure;
  RandomAccessFile? _out;
  Future<void> _io = Future.value();
  final _waiting = <Completer<void>>[];

  bool get isComplete => _finished && _failure == null && !_cancelled && _renamed;
  bool get hasFailed => _failure != null;
  Object? get failure => _failure;
  bool get isCancelled => _cancelled;

  /// Starts fetching, once.
  void start() {
    if (_started) return;
    _started = true;
    _run();
  }

  void cancel() {
    if (_finished) return;
    _cancelled = true;
    if (!_started) {
      _started = true;
      _finished = true;
    }
    _wake();
  }

  /// Returns once the whole song is in or the fetch has stopped (failed or cancelled).
  Future<void> whole() async {
    start();
    while (!_finished) {
      await _wait();
    }
  }

  /// The whole file's length (the first range tells it when the link does not).
  Future<int> totalLength() async {
    start();
    while (_length == null) {
      final failure = _failure;
      if (failure != null) throw failure;
      if (_finished) throw StateError('The audio ended before its length was known.');
      await _wait();
    }
    return _length!;
  }

  /// Bytes [from] to [to], both included, as soon as the first of them has arrived (possibly fewer than asked); empty
  /// past the end.
  Future<Uint8List> bytes(int from, int to) async {
    start();
    while (true) {
      if (from < _received) return _read(from, math.min(to + 1, _received));
      final failure = _failure;
      if (failure != null) throw failure;
      if (_finished) return Uint8List(0);
      // a seek far ahead is fetched on its own, not waited for
      if (from > _received + 2 * RangeFetcher.range) return (await fetcher.fetchWithRetry(link, from, to)).data;
      await _wait();
    }
  }

  Future<void> _run() async {
    var size = RangeFetcher.firstRange;
    try {
      await _part.parent.create(recursive: true);
      _out = await _part.open(mode: FileMode.write);
      while (!_cancelled) {
        if (_length != null && _received >= _length!) break;
        final piece = await fetcher.fetchWithRetry(link, _received, _received + size - 1);
        if (_cancelled) break;
        _length ??= piece.total;
        if (piece.data.isEmpty) break;
        await _out!.writeFrom(piece.data);
        _received += piece.data.length;
        _wake();
        size = RangeFetcher.range;
      }
    } catch (e) {
      _failure = e;
    }
    await _finish();
  }

  Future<void> _finish() async {
    final done = _failure == null && !_cancelled && _length != null && _received >= _length!;
    try {
      await _out?.close();
    } catch (_) {}
    await _exclusive(() async {
      try {
        if (done) {
          await _rename();
          _renamed = true;
        } else {
          if (_failure == null && !_cancelled) _failure = StateError('The audio ended early.');
          if (await _part.exists()) await _part.delete();
        }
      } catch (e) {
        _failure ??= e;
      }
    });
    _finished = true;
    if (_renamed) onDone?.call();
    _wake();
  }

  /// Windows refuses to rename a file that is open; the last reader closes within moments.
  Future<void> _rename() async {
    for (var attempt = 1;; attempt++) {
      try {
        await _part.rename(target.path);
        return;
      } on FileSystemException {
        if (attempt >= 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
      }
    }
  }

  Future<Uint8List> _read(int from, int end) => _exclusive(() async {
        try {
          final f = await (_renamed ? target : _part).open();
          try {
            await f.setPosition(from);
            return await f.read(end - from);
          } finally {
            await f.close();
          }
        } on FileSystemException {
          return Uint8List(0); // the file went with a cancelled fetch
        }
      });

  /// Reads and the final rename run one at a time.
  Future<T> _exclusive<T>(Future<T> Function() job) {
    final result = _io.then((_) => job());
    _io = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _wait() {
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _wake() {
    final all = [..._waiting];
    _waiting.clear();
    for (final c in all) {
      c.complete();
    }
  }
}

/// The songs being fetched into the cache: the playing one and the next, never more. A fetch whose song is neither is
/// cancelled, and its partial file deleted.
class AudioDownloads {
  AudioDownloads({AudioCache? cache, RangeFetcher? fetcher})
      : cache = cache ?? AudioCache.shared,
        fetcher = fetcher ?? RangeFetcher(http.Client());

  static final shared = AudioDownloads();

  final AudioCache cache;
  final RangeFetcher fetcher;
  final _running = <String, AudioDownload>{};
  int _generation = 0;
  Future<void> _gate = Future.value();

  /// The fetch of this song, started if there is none; a failed or cancelled one is replaced, and so is a finished one
  /// whose file is gone. The player deletes a file that would not play and fetches the song again: handed back the
  /// finished fetch, it was given the deleted file, which Windows' player never finishes opening, and the song sat at
  /// 0:00 with no word (15 Oct, #30).
  AudioDownload fetch(String key, Uri link) {
    final known = _running[key];
    if (known != null && !known.hasFailed && !known.isCancelled && !(known.isComplete && !known.target.existsSync())) {
      return known;
    }
    final download = AudioDownload(
        key: key, link: link, target: cache.path(key), fetcher: fetcher, onDone: () => cache.evict(keep: key));
    _running[key] = download;
    return download;
  }

  /// Stops every fetch but these songs'.
  void keep(Set<String> keys) {
    _running.removeWhere((key, download) {
      if (keys.contains(key)) return false;
      download.cancel();
      return true;
    });
  }

  bool isFetching(String key) => _running.containsKey(key);

  /// Returns when this song's fetch is done; at once when none is running (it played from a file).
  Future<void> finished(String key) async => _running[key]?.whole();

  /// Runs [job] when no other background fetch (the next song's, a download's) is running: one whole-song fetch at a
  /// time besides the playing one.
  Future<T> background<T>(Future<T> Function() job) {
    final result = _gate.then((_) => job());
    _gate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Fetches [next] whole into the cache, but only once the playing song's own audio has all arrived (or it played from
  /// a file): started at once, it competed with the song that had just begun. A newer call replaces this one.
  Future<void> prefetchNext({String? playingKey, Listing? next, required Future<Uri> Function(Listing) linkFor}) async {
    final mine = ++_generation;
    if (!cache.enabled || next == null || cache.peek(next.key) != null) return;
    if (playingKey != null) await finished(playingKey);
    if (mine != _generation) return;
    final running = _running[next.key];
    final link = running?.link ?? await linkFor(next);
    if (mine != _generation) return;
    await background(() async {
      if (mine != _generation) return;
      await fetch(next.key, link).whole();
    });
  }
}
