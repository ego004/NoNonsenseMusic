import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// What Google's public translate endpoint answered: the translated text and the language the lyrics were in.
class TranslateReply {
  /// The translated parts joined, in order. A line break in the question is a line break here.
  final String text;

  /// The detected source language ("es", "hi", "zh-CN"), or null when the reply names none.
  final String? language;
  const TranslateReply(this.text, this.language);

  /// Reads the reply of `translate_a/single?client=gtx&dt=t`: a list whose first element is a list of chunks
  /// `[translated, original, ...]` and whose element 2 is the detected language. Throws a [FormatException] for any
  /// other shape, so a changed reply shows as a failure instead of as wrong text.
  factory TranslateReply.parse(String body) {
    final Object? reply = jsonDecode(body);
    if (reply is! List || reply.isEmpty || reply.first is! List) throw const FormatException('no chunks');
    final out = StringBuffer();
    for (final chunk in reply.first as List) {
      if (chunk is! List || chunk.isEmpty) throw const FormatException('a chunk is not a list');
      final part = chunk.first;
      if (part is String) out.write(part);
    }
    final language = reply.length > 2 && reply[2] is String ? reply[2] as String : null;
    return TranslateReply(out.toString(), language);
  }

  /// The translation of each of [count] input lines. The reply splits on line breaks, one per input line; any other
  /// count means the lines no longer match, and a translation under the wrong line is worse than none, so null.
  List<String>? splitInto(int count) {
    final lines = text.split('\n');
    while (lines.length > count && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.length == count ? lines : null;
  }
}

/// A song in one target language: what [LyricsTranslations] keeps its answers by.
typedef _SongIn = (String songId, String language);

/// Translates the lyrics of a song once per session and language, from the app itself, with Google's public endpoint.
///
/// A song's lyrics go in one request: every non-empty line joined by line breaks. The answer is kept per song and target
/// language and never asked for again, so the cost is one request per song and language a person chooses to translate.
/// Another language in Settings › Lyrics › Translate into translates the song again, and the first one chosen back
/// shows its answer without a request (#19: kept per song only, the first language's answer stayed). Nothing is sent
/// until the Translate button is pressed.
class LyricsTranslations extends ChangeNotifier {
  /// [language] gives the target as Google takes it (one of [languages], or [deviceLanguage]); it is read at each use,
  /// so a change in Settings applies the next time the lyrics show.
  LyricsTranslations({String Function()? language}) : _language = language ?? deviceLanguage;

  final String Function() _language;
  final Map<_SongIn, List<String>> _lines = {};
  final Set<_SongIn> _sameLanguage = {}, _failed = {}, _asking = {};

  _SongIn _key(String songId) => (songId, _language());

  /// The translation of each lyric line of the song ('' for a gap), or null when not translated (yet).
  List<String>? linesOf(String songId) => _lines[_key(songId)];

  /// The song's lyrics are already in the reader's language: there is nothing to translate.
  bool inReadersLanguage(String songId) => _sameLanguage.contains(_key(songId));
  bool failed(String songId) => _failed.contains(_key(songId));
  bool isTranslating(String songId) => _asking.contains(_key(songId));

  /// Translates [lines] of [songId] into the reader's language. Returns at once when the song was answered or is
  /// being asked in that language; a failure is kept until [retry], so showing the panel again does not ask again.
  Future<void> translate(String songId, List<LyricLine> lines, {Future<TranslateReply> Function(String, String)? ask}) async {
    final key = _key(songId);
    if (_lines.containsKey(key) || _sameLanguage.contains(key) || _failed.contains(key) || _asking.contains(key)) {
      return;
    }
    final target = key.$2;
    final own = providedTranslations(lines, target);
    if (own != null) {
      _lines[key] = own;
      notifyListeners();
      return;
    }
    final spoken = [for (final (i, l) in lines.indexed) if (l.text.trim().isNotEmpty) i];
    if (spoken.isEmpty) return;
    _asking.add(key);
    notifyListeners();
    try {
      final reply = await (ask ?? GoogleTranslate.ask)([for (final i in spoken) lines[i].text.trim()].join('\n'), target);
      if (sameLanguage(reply.language, target)) {
        _sameLanguage.add(key);
      } else {
        final each = reply.splitInto(spoken.length);
        if (each == null) throw const FormatException('the lines did not match');
        final all = List.filled(lines.length, '');
        for (final (k, i) in spoken.indexed) {
          all[i] = each[k].trim();
        }
        _lines[key] = all;
      }
    } catch (_) {
      _failed.add(key);
    }
    _asking.remove(key);
    notifyListeners();
  }

  /// Lets a failed song be asked once more, on the person's request.
  void retry(String songId) {
    if (_failed.remove(_key(songId))) notifyListeners();
  }

  /// The lyrics' own translations (the uploader included them) when they are in the reader's language, the one chosen
  /// in Settings › Lyrics › Translate into or else the device's; null otherwise.
  ///
  /// The device cannot tell languages apart, only scripts: the translations count as the reader's when most of their
  /// letters are in the script of [target] (an English or Spanish reader with translations written in Hindi gets a
  /// request instead). Between two languages in one script, the uploader's translation is trusted.
  static List<String>? providedTranslations(List<LyricLine> lines, String target) {
    final given = [for (final l in lines) l.translation?.trim() ?? ''];
    if (!given.any((t) => t.isNotEmpty)) return null;
    return inScript(given.join('\n'), target) ? given : null;
  }

  /// Whether most letters of [text] are written in the script the language [target] uses.
  static bool inScript(String text, String target) {
    final script = RegExp(_scriptPattern(target), unicode: true);
    final letter = RegExp(r'\p{L}', unicode: true);
    var letters = 0, inTarget = 0;
    for (final m in letter.allMatches(text)) {
      letters++;
      if (script.hasMatch(m.group(0)!)) inTarget++;
    }
    return letters > 0 && inTarget * 10 >= letters * 8;
  }

  static String _scriptPattern(String language) => switch (language.split('-').first) {
        'hi' || 'mr' || 'ne' || 'sa' => r'\p{Script=Devanagari}',
        'bn' || 'as' => r'\p{Script=Bengali}',
        'ta' => r'\p{Script=Tamil}',
        'te' => r'\p{Script=Telugu}',
        'kn' => r'\p{Script=Kannada}',
        'ml' => r'\p{Script=Malayalam}',
        'gu' => r'\p{Script=Gujarati}',
        'pa' => r'\p{Script=Gurmukhi}',
        'ar' || 'fa' || 'ur' => r'\p{Script=Arabic}',
        'he' || 'iw' || 'yi' => r'\p{Script=Hebrew}',
        'ru' || 'uk' || 'bg' || 'sr' || 'be' || 'mk' => r'\p{Script=Cyrillic}',
        'el' => r'\p{Script=Greek}',
        'th' => r'\p{Script=Thai}',
        'ko' => r'\p{Script=Hangul}',
        'ja' => r'[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]',
        'zh' => r'\p{Script=Han}',
        _ => r'\p{Script=Latin}',
      };

  /// Whether the language Google detected is the one asked for: 'zh-CN' and 'zh' match, and so do the two codes
  /// Google uses for Hebrew.
  static bool sameLanguage(String? detected, String target) {
    String base(String code) {
      final b = code.toLowerCase().split(RegExp('[-_]')).first;
      return b == 'iw' ? 'he' : b;
    }

    return detected != null && base(detected) == base(target);
  }

  /// Settings › Lyrics › Translate into: the languages offered besides the device's own, by Google's code, with their
  /// own names, in the order of those names. Those Apple's on-device translation also takes, so the Mac app offers the
  /// same list (#19); not all of Google's 240.
  static const languages = {
    'id': 'Bahasa Indonesia',
    'de': 'Deutsch',
    'en': 'English',
    'es': 'Español',
    'fr': 'Français',
    'it': 'Italiano',
    'nl': 'Nederlands',
    'pl': 'Polski',
    'pt': 'Português',
    'vi': 'Tiếng Việt',
    'tr': 'Türkçe',
    'ru': 'Русский',
    'uk': 'Українська',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'th': 'ไทย',
    'ja': '日本語',
    'zh-CN': '简体中文',
    'zh-TW': '繁體中文',
    'ko': '한국어',
  };

  /// The device's language as Google's translate takes it: "en", "hi", "zh-CN" or "zh-TW".
  static String deviceLanguage() {
    final l = PlatformDispatcher.instance.locale;
    if (l.languageCode != 'zh') return l.languageCode;
    return l.scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(l.countryCode) ? 'zh-TW' : 'zh-CN';
  }
}

/// Google's public translate endpoint (`translate_a/single`, the client "gtx" of its web widgets).
class GoogleTranslate {
  static const _endpoint = 'https://translate.googleapis.com/translate_a/single';

  static const _wait = Duration(seconds: 15);

  /// Longest encoded question sent in the address; longer ones go in a form body, which has no such limit.
  static const maxQueryLength = 1800;

  /// Translates [text] (lines joined by line breaks) into [target], detecting the source language.
  static Future<TranslateReply> ask(String text, String target) async {
    final fixed = {'client': 'gtx', 'sl': 'auto', 'tl': target, 'dt': 't'};
    final http = Api.client;
    final response = Uri.encodeQueryComponent(text).length <= maxQueryLength
        ? await http.get(Uri.parse(_endpoint).replace(queryParameters: {...fixed, 'q': text})).timeout(_wait)
        : await http.post(Uri.parse(_endpoint).replace(queryParameters: fixed), body: {'q': text}).timeout(_wait);
    if (response.statusCode != 200) throw FormatException('translate answered ${response.statusCode}');
    return TranslateReply.parse(utf8.decode(response.bodyBytes));
  }
}
