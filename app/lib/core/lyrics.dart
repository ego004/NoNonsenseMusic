import 'package:flutter/foundation.dart';

import 'api.dart';
import 'download_store.dart';
import 'models.dart';
import 'player.dart';
import 'translation.dart';

/// Hold each song's lyrics for one session, asking for each song once, as the Mac app's LyricsStore does.
///
/// [of] returns null while a song loads, and lyrics with empty `lines` when nobody has them. The song's id is in
/// [unreachable] when the server could not be asked.
class LyricsStore extends ChangeNotifier {
  final Map<String, Lyrics> _found = {};
  final Set<String> _asking = {};
  final Set<String> unreachable = {};

  Lyrics? of(Track t) => _found[t.id];

  /// The translations of the lyrics, made on request and kept for the session, into [translateInto].
  final translations = LyricsTranslations(language: () => translateInto.isEmpty ? LyricsTranslations.deviceLanguage() : translateInto);

  /// Settings › Lyrics › Translate into: one of [LyricsTranslations.languages], or '' for the device's language.
  static String translateInto = '';

  /// Settings › Lyrics › Genius notes: whether the notes are fetched (experimental, off by default).
  static bool genius = false;
  final Map<String, GeniusNotes> _notes = {};
  final Set<String> _notesAsked = {};
  GeniusNotes? notesOf(Track t) => genius ? _notes[t.id] : null;

  /// Fetch this song's Genius notes alongside its lyrics when the setting is on, asking once per song.
  ///
  /// A failure is asked again the next time the song starts. The lyrics never wait for the notes.
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
  /// Settings › Lyrics: whether lyrics are asked for when a song starts (true, the default) or only when the panel
  /// opens.
  static bool early = true;

  /// Follow [player] and ask for each song's lyrics, and the next song's, as it starts, as the Mac app does by
  /// default. Asking only when the panel opens shows "Finding lyrics…" first. One request per song; the server
  /// answers repeats from its cache.
  void follow(Player player) {
    if (identical(_following, player)) return;
    _following = player;
    player.currentId.addListener(() {
      if (!early) return;
      final t = player.current;
      if (t != null) fetch(t);
      final next = player.queue.upNext.firstOrNull; // prefetch the next song so its lyrics are ready in time
      if (next != null) fetch(next);
    });
  }

  /// A song was just downloaded: keep its lyrics beside the file (asking the server if this session has not).
  Future<void> keep(Track t) async {
    var found = _found[t.id];
    if (found == null) {
      try {
        found = await Api.lyrics(t);
        _found[t.id] = found;
      } catch (_) {
        return; // no lyrics offline for this one; nothing else changes
      }
    }
    await DownloadStore.shared.keepLyrics(t, found);
  }

  /// Fetch [t]'s lyrics once and cache them, adding the id to [unreachable] when the server fails.
  Future<void> fetch(Track t) async {
    fetchNotes(t);
    if (_found.containsKey(t.id) || _asking.contains(t.id)) return;
    _asking.add(t.id);
    unreachable.remove(t.id);
    notifyListeners();
    final kept = await DownloadStore.shared.keptLyrics(t); // a downloaded song answers from its file, also offline
    if (kept != null) {
      _found[t.id] = kept;
      _asking.remove(t.id);
      notifyListeners();
      return;
    }
    try {
      _found[t.id] = await Api.lyrics(t);
    } catch (_) {
      unreachable.add(t.id);
    }
    _asking.remove(t.id);
    notifyListeners();
  }
}
