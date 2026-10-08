import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'player.dart';

/// Each song's lyrics, asked for once per session (the Mac app's LyricsStore). null while loading; an empty `lines`
/// when nobody has them; `unreachable` when the server could not be asked.
class LyricsStore extends ChangeNotifier {
  final Map<String, Lyrics> _found = {};
  final Set<String> _asking = {};
  final Set<String> unreachable = {};

  Lyrics? of(Track t) => _found[t.id];
  bool isLoading(Track t) => _asking.contains(t.id);

  Player? _following;

  /// Asks for each song's lyrics as it starts, as the Mac app does by default: asked only when the panel opened, it
  /// showed "Finding lyrics…" first (8 Oct). One request per song; the server answers repeats from its cache.
  void follow(Player player) {
    if (identical(_following, player)) return;
    _following = player;
    player.currentId.addListener(() {
      final t = player.current;
      if (t != null) fetch(t);
    });
  }

  Future<void> fetch(Track t) async {
    if (_found.containsKey(t.id) || _asking.contains(t.id)) return;
    _asking.add(t.id);
    unreachable.remove(t.id);
    notifyListeners();
    try {
      _found[t.id] = await Api.lyrics(t);
    } catch (_) {
      unreachable.add(t.id);
    }
    _asking.remove(t.id);
    notifyListeners();
  }
}
