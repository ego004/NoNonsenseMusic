import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// Each song's lyrics, asked for once per session (the Mac app's LyricsStore). null while loading; an empty `lines`
/// when nobody has them; `unreachable` when the server could not be asked.
class LyricsStore extends ChangeNotifier {
  final Map<String, Lyrics> _found = {};
  final Set<String> _asking = {};
  final Set<String> unreachable = {};

  Lyrics? of(Track t) => _found[t.id];
  bool isLoading(Track t) => _asking.contains(t.id);

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
