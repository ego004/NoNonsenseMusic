import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The last searches, newest first, shown under the empty search field (as the iPhone's Recent). Kept on this device only.
class RecentSearches extends ChangeNotifier {
  RecentSearches._();
  static final shared = RecentSearches._();

  static const limit = 8;
  static const _key = 'recentSearches';
  List<String> items = const [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    items = p.getStringList(_key) ?? const [];
    notifyListeners();
  }

  /// Forgets what was loaded: the next [load] reads again (tests, a changed preference store).
  @visibleForTesting
  void reset() {
    _loaded = false;
    items = const [];
  }

  /// A search the user made: it goes to the top; the same words again (whatever the capitals) move there instead of repeating.
  Future<void> add(String query) async {
    final text = query.trim();
    if (text.length < 2) return;
    await load();
    items = [text, ...items.where((e) => e.toLowerCase() != text.toLowerCase())].take(limit).toList();
    notifyListeners();
    await _save();
  }

  Future<void> remove(String query) async {
    items = items.where((e) => e != query).toList();
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    items = const [];
    notifyListeners();
    await _save();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setStringList(_key, items);
}
