// The search's word rule, as the server has it (backend services/matching.py: normalise, found, words_of), for a search
// without the server: the songs you have that it finds are the ones the server would (#26).
import 'dart:math' as math;

import 'models.dart';

/// A typed word this long or longer also matches a word this alike: a ratio from 0 to 100, rapidfuzz's (the server's
/// TYPO_MIN_LENGTH and TYPO_SIMILARITY, #25). Shorter words must be as typed.
const typoMinLength = 4, typoSimilarity = 85;

/// [text] as the server compares it: lower case, letters without their marks, anything else that is not a letter or a
/// digit a space, single spaces.
///
/// The server's is Unicode's NFKD, every mark of a nonzero combining class then dropped. Dart has no NFKD: [_bare] holds
/// what it does to Latin, Greek and Cyrillic letters and to ligatures, a Hangul syllable is split into its letters here
/// as NFKD splits it, and [_isCombining] knows the classes, so a title written with separate marks reads the same. Other
/// compatibility forms (full-width letters, circled numbers, kana's voicing marks) stay as written, on both sides of
/// a comparison. The tables are Python's unicodedata 15.1 (18 Oct).
String normalise(String text) {
  final letters = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (rune >= 0xAC00 && rune <= 0xD7A3) {
      final s = rune - 0xAC00;
      letters
        ..writeCharCode(0x1100 + s ~/ 588)
        ..writeCharCode(0x1161 + s % 588 ~/ 28);
      if (s % 28 > 0) letters.writeCharCode(0x11A7 + s % 28);
    } else if (!_isCombining(rune)) {
      letters.write(_bare[rune] ?? String.fromCharCode(rune));
    }
  }
  return letters.toString().replaceAll(_notLetterOrDigit, ' ').split(' ').where((w) => w.isNotEmpty).join(' ');
}

/// The words [found] looks among: a title's and its artists' (or any names'), normalised, each once.
Set<String> wordsOf(Iterable<String> names) => normalise(names.join(' ')).split(' ').where((w) => w.isNotEmpty).toSet();

/// Whether a typed word is among [have]: as typed, or, for [typoMinLength] letters or more, as a word [typoSimilarity]
/// alike.
bool found(String word, Set<String> have) =>
    have.contains(word) || (word.runes.length >= typoMinLength && have.any((other) => _alike(word, other)));

/// The songs among [mine] that a search for [query] finds as yours, each once, in the order given: those with a copy
/// that holds every typed word as [found] takes it (the server's library.matching_songs).
List<Track> matchingSongs(String query, Iterable<Track> mine) {
  final words = normalise(query).split(' ').where((w) => w.isNotEmpty).toSet();
  final songs = <Track>[];
  final listed = <String>{}; // the copies of the songs found: a song in both Downloads and Liked Songs is listed once
  if (words.isEmpty) return songs;
  for (final song in mine) {
    if (song.listings.any((l) => listed.contains(l.key))) continue;
    if (song.listings.any((l) => words.every((w) => found(w, _copyWords[l] ??= wordsOf([l.title, ...l.artists]))))) {
      songs.add(song);
      listed.addAll(song.listings.map((l) => l.key));
    }
  }
  return songs;
}

/// Each copy's words, worked out once per copy: a search without the server reads every song you have.
final _copyWords = Expando<Set<String>>();

/// rapidfuzz's ratio of two words is at least [typoSimilarity]: 200 times their longest common subsequence over both
/// lengths, in whole numbers (the server's floats agree, 85.0 included).
bool _alike(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  final both = x.length + y.length;
  if (200 * math.min(x.length, y.length) < typoSimilarity * both) return false; // lengths too far apart to be alike
  var previous = List<int>.filled(y.length + 1, 0);
  for (final c in x) {
    final row = List<int>.filled(y.length + 1, 0);
    for (var j = 0; j < y.length; j++) {
      row[j + 1] = c == y[j] ? previous[j] + 1 : math.max(previous[j + 1], row[j]);
    }
    previous = row;
  }
  return 200 * previous[y.length] >= typoSimilarity * both;
}

final _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Letters NFKD takes apart, lower case (the text is lowered first), each with what is left once the marks go:
/// [_from]'s n-th letter becomes [_to]'s, and a few become two or three.
final Map<int, String> _bare = () {
  final from = _from.runes.toList(), to = _to.runes.toList();
  return {
    for (var i = 0; i < from.length; i++) from[i]: String.fromCharCode(to[i]),
    0x133: 'ij', 0x140: 'l·', 0x149: 'ʼn', 0x1c6: 'dz', 0x1c9: 'lj', 0x1cc: 'nj', 0x1f3: 'dz', 0x1e9a: 'aʾ',
    0xfb00: 'ff', 0xfb01: 'fi', 0xfb02: 'fl', 0xfb03: 'ffi', 0xfb04: 'ffl', 0xfb05: 'st', 0xfb06: 'st',
  };
}();

const _from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏőŕŗřśŝşšţťũūŭůűųŵŷźżžſơưǎǐǒǔǖǘǚǜǟǡǣǧǩǫǭǯǰ'
              'ǵǹǻǽǿȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧȩȫȭȯȱȳʹͺΐάέήίΰϊϋόύώϐϑϒϓϔϕϖϰϱϲϵйѐёѓїќѝўѷӂӑӓӗӛӝӟӣӥӧӫӭӯӱӳӵӹḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭ'
              'ḯḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙẛạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵ'
              'ỷỹἀἁἂἃἄἅἆἇἐἑἒἓἔἕἠἡἢἣἤἥἦἧἰἱἲἳἴἵἶἷὀὁὂὃὄὅὐὑὒὓὔὕὖὗὠὡὢὣὤὥὦὧὰάὲέὴήὶίὸόὺύὼώᾀᾁᾂᾃᾄᾅᾆᾇᾐᾑᾒᾓᾔᾕᾖᾗᾠᾡᾢᾣᾤᾥᾦᾧᾰᾱᾲᾳᾴᾶᾷι'
              'ῂῃῄῆῇῐῑῒΐῖῗῠῡῢΰῤῥῦῧῲῳῴῶῷ';
const _to = 'aaaaaaceeeeiiiinooooouuuuyyaaaccccdeeeeegggghiiiijklllnnnooorrrssssttuuuuuuwyzzzsouaiouuuuuaaægkooʒj'
            'gnaæøaaeeiioorruusthaeooooyʹ ιαεηιυιυουωβθΥΥΥφπκρςεиеегікиуѵжааеәжзииоөэууучыabbbcdddddeeeeefghhhhhi'
            'ikkkllllmmmnnnnoooopprrrrsssssttttuuuuuvvwwwwwxxyzzzhtwysaaaaaaaaaaaaeeeeeeeeiioooooooooooouuuuuuuyy'
            'yyααααααααεεεεεεηηηηηηηηιιιιιιιιοοοοοουυυυυυυυωωωωωωωωααεεηηιιοουυωωααααααααηηηηηηηηωωωωωωωωαααααααι'
            'ηηηηηιιιιιιυυυυρρυυωωωωω';

/// Whether a character is a mark of a nonzero combining class, which NFKD's text loses here: one of [_combiningRanges].
bool _isCombining(int rune) {
  if (rune < 0x300) return false;
  var low = 0, high = _combiningRanges.length ~/ 2 - 1;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (rune < _combiningRanges[2 * mid]) {
      high = mid - 1;
    } else if (rune > _combiningRanges[2 * mid + 1]) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// The characters of the Basic Multilingual Plane with a nonzero combining class, as first, last pairs.
const _combiningRanges = [
  0x300, 0x34e, 0x350, 0x36f, 0x483, 0x487, 0x591, 0x5bd, 0x5bf, 0x5bf, 0x5c1, 0x5c2, 0x5c4, 0x5c5, 0x5c7, 0x5c7,
  0x610, 0x61a, 0x64b, 0x65f, 0x670, 0x670, 0x6d6, 0x6dc, 0x6df, 0x6e4, 0x6e7, 0x6e8, 0x6ea, 0x6ed, 0x711, 0x711,
  0x730, 0x74a, 0x7eb, 0x7f3, 0x7fd, 0x7fd, 0x816, 0x819, 0x81b, 0x823, 0x825, 0x827, 0x829, 0x82d, 0x859, 0x85b,
  0x898, 0x89f, 0x8ca, 0x8e1, 0x8e3, 0x8ff, 0x93c, 0x93c, 0x94d, 0x94d, 0x951, 0x954, 0x9bc, 0x9bc, 0x9cd, 0x9cd,
  0x9fe, 0x9fe, 0xa3c, 0xa3c, 0xa4d, 0xa4d, 0xabc, 0xabc, 0xacd, 0xacd, 0xb3c, 0xb3c, 0xb4d, 0xb4d, 0xbcd, 0xbcd,
  0xc3c, 0xc3c, 0xc4d, 0xc4d, 0xc55, 0xc56, 0xcbc, 0xcbc, 0xccd, 0xccd, 0xd3b, 0xd3c, 0xd4d, 0xd4d, 0xdca, 0xdca,
  0xe38, 0xe3a, 0xe48, 0xe4b, 0xeb8, 0xeba, 0xec8, 0xecb, 0xf18, 0xf19, 0xf35, 0xf35, 0xf37, 0xf37, 0xf39, 0xf39,
  0xf71, 0xf72, 0xf74, 0xf74, 0xf7a, 0xf7d, 0xf80, 0xf80, 0xf82, 0xf84, 0xf86, 0xf87, 0xfc6, 0xfc6, 0x1037, 0x1037,
  0x1039, 0x103a, 0x108d, 0x108d, 0x135d, 0x135f, 0x1714, 0x1715, 0x1734, 0x1734, 0x17d2, 0x17d2, 0x17dd, 0x17dd,
  0x18a9, 0x18a9, 0x1939, 0x193b, 0x1a17, 0x1a18, 0x1a60, 0x1a60, 0x1a75, 0x1a7c, 0x1a7f, 0x1a7f, 0x1ab0, 0x1abd,
  0x1abf, 0x1ace, 0x1b34, 0x1b34, 0x1b44, 0x1b44, 0x1b6b, 0x1b73, 0x1baa, 0x1bab, 0x1be6, 0x1be6, 0x1bf2, 0x1bf3,
  0x1c37, 0x1c37, 0x1cd0, 0x1cd2, 0x1cd4, 0x1ce0, 0x1ce2, 0x1ce8, 0x1ced, 0x1ced, 0x1cf4, 0x1cf4, 0x1cf8, 0x1cf9,
  0x1dc0, 0x1dff, 0x20d0, 0x20dc, 0x20e1, 0x20e1, 0x20e5, 0x20f0, 0x2cef, 0x2cf1, 0x2d7f, 0x2d7f, 0x2de0, 0x2dff,
  0x302a, 0x302f, 0x3099, 0x309a, 0xa66f, 0xa66f, 0xa674, 0xa67d, 0xa69e, 0xa69f, 0xa6f0, 0xa6f1, 0xa806, 0xa806,
  0xa82c, 0xa82c, 0xa8c4, 0xa8c4, 0xa8e0, 0xa8f1, 0xa92b, 0xa92d, 0xa953, 0xa953, 0xa9b3, 0xa9b3, 0xa9c0, 0xa9c0,
  0xaab0, 0xaab0, 0xaab2, 0xaab4, 0xaab7, 0xaab8, 0xaabe, 0xaabf, 0xaac1, 0xaac1, 0xaaf6, 0xaaf6, 0xabed, 0xabed,
  0xfb1e, 0xfb1e, 0xfe20, 0xfe2f,
];
