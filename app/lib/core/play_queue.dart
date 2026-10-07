import 'dart:math';

import 'models.dart';
import 'shuffle.dart';

/// Repeat: off → all → one → off, as in Apple Music.
enum Repeat {
  off,
  all,
  one;

  Repeat get next => switch (this) { Repeat.off => Repeat.all, Repeat.all => Repeat.one, Repeat.one => Repeat.off };
}

/// One place in the queue.
class Entry {
  final Track track;

  /// Its place in the order you chose: shuffle off sorts by it, so the order comes back.
  double n;

  /// Names this entry for later edits: a playlist item id, so a song added twice is two entries.
  final String key;

  /// Added by Play Next or Add to Queue: not one of the list's songs, so a playlist sync keeps it.
  final bool queued;

  /// Added by Add to Queue: its place is the end of Up Next, not right after the playing song.
  final bool atEnd;

  Entry(this.track, this.n, this.key, {this.queued = false, this.atEnd = false});
  Entry copyWith({double? n}) => Entry(track, n ?? this.n, key, queued: queued, atEnd: atEnd);
}

int _keys = 0;
String _newKey() => 'q${_keys++}-${DateTime.now().microsecondsSinceEpoch}';

/// The order songs play in, apart from the audio: shuffle, repeat, Play Next, Add to Queue, and keeping a playing
/// playlist's queue in step with edits to it. A plain value with no audio, so every rule has a unit test
/// (test/play_queue_test.dart). Ported rule for rule from the Mac app's PlayQueue.swift.
class PlayQueue {
  List<Entry> entries = [];
  int index = 0;
  bool isShuffled = false;
  Repeat repeat = Repeat.off;

  /// Where the queue came from (`playlist:<id>`): that playlist's edits reach the queue only then.
  String? source;

  /// Where it came from, for "From “Gym”": a change by hand keeps it.
  String? origin;

  List<Track> get tracks => entries.map((e) => e.track).toList();
  Track? get current => index >= 0 && index < entries.length ? entries[index].track : null;
  String? get currentKey => index >= 0 && index < entries.length ? entries[index].key : null;

  /// The entries after the current one, in play order: what Up Next shows.
  List<Entry> get upcoming => index + 1 < entries.length ? entries.sublist(index + 1) : [];
  List<Track> get upNext => upcoming.map((e) => e.track).toList();

  /// A new queue. `keys` name the entries (playlist item ids); without them each entry gets its own.
  void load(List<Track> tracks, int startAt, {List<String>? keys, String? source, required bool shuffled, Random? rng}) {
    entries = [
      for (var n = 0; n < tracks.length; n++)
        Entry(tracks[n], n.toDouble(), keys != null && n < keys.length ? keys[n] : _newKey()),
    ];
    index = startAt >= 0 && startAt < tracks.length ? startAt : 0;
    this.source = source;
    origin = source;
    isShuffled = false;
    if (shuffled && entries.isNotEmpty) {
      // your song first, then EVERY other song shuffled (the ones above it too), as in Apple Music
      final chosen = entries.removeAt(index);
      entries = [chosen, ...Shuffle.artistSpread(entries, _artist, rng ?? Random())];
      index = 0;
      isShuffled = true;
    }
  }

  static String _artist(Entry e) => e.track.artists.isEmpty ? '' : e.track.artists.first;

  /// On: the songs after the current one are shuffled; played ones and the current one stay. Off: your order, same song.
  void setShuffle(bool on, {Random? rng}) {
    if (on == isShuffled) return;
    isShuffled = on;
    final key = currentKey;
    if (key == null) return;
    if (on) {
      entries = [...entries.sublist(0, index + 1), ...Shuffle.artistSpread(entries.sublist(index + 1), _artist, rng ?? Random())];
    } else {
      entries.sort((a, b) => a.n.compareTo(b.n));
      index = entries.indexWhere((e) => e.key == key).clamp(0, entries.length);
    }
  }

  /// A song ends by itself: repeat one plays it again; at the end, repeat all starts over, repeat off stops (null).
  int? indexAfterEnd() => repeat == Repeat.one ? index : _step(1);

  /// ⏭: always another song (repeat one does not trap you), wrapping round unless repeat is off.
  int? indexAfterNext() => _step(1);

  /// ⏮ (after 3 s into a song the player restarts it instead).
  int? indexAfterPrevious() => _step(-1);

  int? _step(int by) {
    if (entries.isEmpty) return null;
    final target = index + by;
    if (target >= 0 && target < entries.length) return target;
    return repeat == Repeat.off ? null : (target + entries.length) % entries.length;
  }

  void moveTo(int i) {
    if (i >= 0 && i < entries.length) index = i;
  }

  /// Play Next: right after the current song, now and in your order (so it stays there when shuffle goes off).
  void insertNext(Track track) {
    if (current == null) return load([track], 0, shuffled: false);
    final here = entries[index].n;
    final following = entries.map((e) => e.n).where((n) => n > here).fold<double?>(null, (m, n) => m == null || n < m ? n : m);
    final n = following == null ? here + 1 : (here + following) / 2;
    entries.insert(index + 1, Entry(track, n, _newKey(), queued: true));
  }

  /// Add to Queue: after everything already queued, now and in your order.
  void append(Track track) {
    if (entries.isEmpty) return load([track], 0, shuffled: false);
    final last = entries.map((e) => e.n).reduce(max);
    entries.add(Entry(track, last + 1, _newKey(), queued: true, atEnd: true));
  }

  /// Up Next rearranged by hand. `from` and `to` count from the first song after the current one; `to` is the
  /// moved row's place once moved. The current song never moves.
  void moveUpcoming(int from, int to) {
    final list = upcoming;
    if (from < 0 || from >= list.length) return;
    final moving = list.removeAt(from);
    list.insert(to.clamp(0, list.length), moving);
    entries = [...entries.sublist(0, index + 1), ...list];
    _handEdited();
  }

  void removeUpcoming(int offset) {
    if (offset < 0 || offset >= upcoming.length) return;
    entries.removeAt(index + 1 + offset);
    _handEdited();
  }

  void clearUpcoming() {
    if (current == null) return;
    entries = entries.sublist(0, index + 1);
    _handEdited();
  }

  /// After a change by hand the queue is yours: its playlist no longer reorders it, and with shuffle off your order
  /// becomes the play order.
  void _handEdited() {
    source = null;
    if (!isShuffled) {
      for (var i = 0; i < entries.length; i++) {
        entries[i].n = i.toDouble();
      }
    }
  }

  /// The playlist this queue came from now has these items, in this order. Your order follows it; removed items
  /// leave (except the playing one); new items join at the end. Play Next songs stay next, Add to Queue songs last.
  void sync(String source, List<(String key, Track track)> items) {
    final playing = currentKey;
    if (this.source != source || playing == null) return;
    final queued = upcoming.where((e) => e.queued && !e.atEnd).toList();
    final atEnd = upcoming.where((e) => e.queued && e.atEnd).toList();
    final order = <String, double>{};
    for (var i = 0; i < items.length; i++) {
      order.putIfAbsent(items[i].$1, () => i.toDouble());
    }
    entries.removeWhere((e) => (e.queued || !order.containsKey(e.key)) && e.key != playing);
    for (final e in entries) {
      final n = order[e.key];
      if (n != null) e.n = n;
    }
    final known = entries.map((e) => e.key).toSet();
    for (var i = 0; i < items.length; i++) {
      if (!known.contains(items[i].$1)) entries.add(Entry(items[i].$2, i.toDouble(), items[i].$1));
    }
    if (!isShuffled) entries.sort((a, b) => a.n.compareTo(b.n));
    index = entries.indexWhere((e) => e.key == playing).clamp(0, entries.length);
    final last = entries.isEmpty ? 0.0 : entries.map((e) => e.n).reduce(max);
    for (var i = 0; i < atEnd.length; i++) {
      entries.add(atEnd[i].copyWith(n: last + i + 1));
    }
    if (queued.isEmpty || index >= entries.length) return;
    final here = entries[index].n;
    final following = entries.map((e) => e.n).where((n) => n > here).fold<double?>(null, (m, n) => m == null || n < m ? n : m) ?? here + 1;
    for (var i = 0; i < queued.length; i++) {
      entries.insert(index + 1 + i, queued[i].copyWith(n: here + (following - here) * (i + 1) / (queued.length + 1)));
    }
  }
}
