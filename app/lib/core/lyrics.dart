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

  /// Settings › Lyrics › Genius notes (experimental, off by default).
  static bool genius = false;
  final Map<String, GeniusNotes> _notes = {};
  final Set<String> _notesAsked = {};
  GeniusNotes? notesOf(Track t) => genius ? _notes[t.id] : null;

  /// This song's Genius notes, asked once beside its lyrics when the setting is on. A failure is asked again on the
  /// song's next start. The lyrics never wait for them.
  Future<void> fetchNotes(Track t) async {
    if (!genius || !_notesAsked.add(t.id)) return;
    try {
      _notes[t.id] = await Api.genius(t);
      notifyListeners();
    } catch (_) {
      _notesAsked.remove(t.id);
    }
  }
  bool isLoading(Track t) => _asking.contains(t.id);

  Player? _following;
  /// Settings › Lyrics: asked for when a song starts (true, the default) or only when the panel opens.
  static bool early = true;

  /// Asks for each song's lyrics (and the next one's) as it starts, as the Mac app does by default: asked only when the panel opened, it
  /// showed "Finding lyrics…" first (8 Oct). One request per song; the server answers repeats from its cache.
  void follow(Player player) {
    if (identical(_following, player)) return;
    _following = player;
    player.currentId.addListener(() {
      if (!early) return;
      final t = player.current;
      if (t != null) fetch(t);
      final next = player.queue.upNext.firstOrNull; // and the next song's, as the Mac app does
      if (next != null) fetch(next);
    });
  }

  Future<void> fetch(Track t) async {
    fetchNotes(t);
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
