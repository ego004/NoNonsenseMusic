// The last searches (RecentSearches), shown under the empty Search field: newest first, no repeats, kept, and one tap searches.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/recent_searches.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RecentSearches.shared.reset();
  });

  test('newest first, and the same words again move to the top instead of repeating', () async {
    final r = RecentSearches.shared;
    await r.add('shape of you');
    await r.add('kal ho naa ho');
    await r.add('Shape Of You');
    expect(r.items, ['Shape Of You', 'kal ho naa ho']);
  });

  test('a single letter is not a search worth keeping, and blanks are trimmed', () async {
    final r = RecentSearches.shared;
    await r.add('a');
    await r.add('   ');
    await r.add('  tum hi ho ');
    expect(r.items, ['tum hi ho']);
  });

  test('at most 8 are kept, the oldest go', () async {
    final r = RecentSearches.shared;
    for (var i = 0; i < 12; i++) {
      await r.add('search $i');
    }
    expect(r.items.length, RecentSearches.limit);
    expect(r.items.first, 'search 11');
    expect(r.items.last, 'search 4');
  });

  test('they are kept for the next launch, one can be removed, and all can be cleared', () async {
    final r = RecentSearches.shared;
    await r.add('one');
    await r.add('two');
    r.reset();
    await r.load();
    expect(r.items, ['two', 'one'], reason: 'read back from the saved list');
    await r.remove('two');
    expect(r.items, ['one']);
    r.reset();
    await r.load();
    expect(r.items, ['one'], reason: 'the removal was saved');
    await r.clear();
    r.reset();
    await r.load();
    expect(r.items, isEmpty);
  });
}
