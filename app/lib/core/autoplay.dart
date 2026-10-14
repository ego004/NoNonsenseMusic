import 'models.dart';
import 'play_queue.dart';

/// What to ask the server's radio for when the queue runs low.
class RadioRequest {
  /// The copy the station follows.
  final Listing seed;

  /// Every listing already in the queue, newest last, so the same song does not come back.
  final List<Listing> exclude;

  /// The id of the queue's last song when the request was made; the answer is used only if it is still the last.
  final String lastId;
  const RadioRequest(this.seed, this.exclude, this.lastId);
}

/// Autoplay (Up Next › ∞): when two songs or fewer are left, songs like the last one are added so the music does not
/// stop. The decision is a plain value so each rule has a unit test; the Player makes the request.
///
/// The rules match the Mac app's Player.refillIfNeeded: never with repeat on (the queue never runs out), never while a
/// jam decides what plays, and one request per seed, so a station with nothing new is not asked again and again.
class Autoplay {
  /// Songs left in Up Next at or below which the queue is refilled.
  static const lowWater = 2;

  /// The most listings the server takes in `exclude`.
  static const maxExcluded = 100;

  String? _seed;

  /// Forgets the seed asked about last, for a new queue.
  void reset() => _seed = null;

  /// Returns the request to make now, or null. Calling it counts as asking: the same seed is not returned twice.
  RadioRequest? due(PlayQueue queue, {required bool enabled, bool blocked = false}) {
    if (!enabled || blocked || queue.repeat != Repeat.off || queue.upcoming.length > lowWater) return null;
    final tracks = queue.tracks;
    if (tracks.isEmpty) return null;
    final last = tracks.last;
    if (_seed == last.best.key) return null;
    _seed = last.best.key;
    // a video of the song first: the server starts YouTube Music's station from one, and a JioSaavn copy needs it
    // found first (#24)
    final seed = [for (final source in const ['ytmusic', 'youtube', 'jiosaavn']) ...last.listings.where((l) => l.source == source)]
            .firstOrNull ??
        last.best;
    final seen = <String>{};
    final all = [
      for (final t in tracks) ...t.listings,
    ].where((l) => seen.add(l.key)).toList();
    // the server takes 100: the newest, which are the ones a refill would otherwise repeat
    final exclude = all.length > maxExcluded ? all.sublist(all.length - maxExcluded) : all;
    return RadioRequest(seed, exclude, last.id);
  }
}
