import Foundation
import NaturalLanguage
import Observation
import Translation

/// Lyrics translated on this device by Apple's Translation framework: no server and no third party sees them. A song is
/// translated once per language, when asked, and kept until the app quits. The system offers to download a language the
/// first time it is needed. Shared by the Mac and the iPhone; each has its own view.
@MainActor
@Observable
final class LyricsTranslations {
    static let shared = LyricsTranslations()

    /// A song in one target language. Translations are kept by it, so another language in Settings › Lyrics ›
    /// Translate into translates the song again, and the first one chosen back shows without asking (#19: kept by
    /// song alone, the first language's translation stayed).
    nonisolated struct Key: Hashable, Sendable {
        let song: String
        let target: Locale.Language
    }
    /// One translated line per lyric line ("" for a gap).
    private(set) var lines: [Key: [String]] = [:]
    private(set) var failed: Set<Key> = []
    /// Who translated it, shown under the translation.
    private(set) var credits: [Key: String] = [:]

    /// Song id → the language its lyrics are written in (nil inside: unsure), worked out once per song.
    @ObservationIgnored private var languages: [String: Locale.Language?] = [:]
    /// Songs Google found already written in the language asked for: nothing to translate.
    private(set) var alreadyIn: Set<Key> = []

    /// The song's language when this Mac is sure of it and it is not `target`; nil when it is, or when unsure.
    func foreignLanguage(of song: String, lines: [LyricLine], to target: Locale.Language) -> Locale.Language? {
        language(of: song, lines: lines).flatMap { Self.same($0, target) ? nil : $0 }
    }

    /// The song's language when this Mac is sure of it; nil when unsure (Google is asked instead, and says).
    func language(of song: String, lines: [LyricLine]) -> Locale.Language? {
        if let known = languages[song] { return known }
        let language = Self.language(of: lines.map(\.text))
        languages[song] = language
        return language
    }

    /// Nothing to translate: the lyrics are already in the key's language, as this Mac is sure or Google said.
    func isAlready(_ key: Key, lines: [LyricLine]) -> Bool {
        alreadyIn.contains(key) || language(of: key.song, lines: lines).map { Self.same($0, key.target) } == true
    }

    func markAlready(_ key: Key) { alreadyIn.insert(key) }

    func store(_ translated: [String], for key: Key, credit: String) {
        lines[key] = translated
        credits[key] = credit
    }
    func fail(_ key: Key) { failed.insert(key) }
    /// Try Again: the next showing asks once more.
    func retry(_ key: Key) { failed.remove(key) }

    /// The language `texts` are written in; nil when it is unclear.
    /// The language of `texts` when Apple's recognizer is at least this sure. Hindi and Punjabi written in English
    /// letters read as Indonesian (52% and 62% sure, 20 Oct), which hid Translate or translated them as Indonesian;
    /// lyrics in their own script, and Spanish, read at 100%.
    static let sure = 0.9

    static func language(of texts: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.prefix(40).joined(separator: "\n"))
        guard let (found, likely) = recognizer.languageHypotheses(withMaximum: 1).first, found != .undetermined,
              likely >= sure else { return nil }
        return Locale.Language(identifier: found.rawValue)
    }

    /// The same language, whatever the script or region: simplified and traditional Chinese are one. Hinglish is Hindi
    /// in Latin letters, so it is not Hindi in Devanagari: the lyrics need romanizing.
    static func same(_ language: Locale.Language, _ other: Locale.Language) -> Bool {
        OnlineTranslation.isHinglish(language) == OnlineTranslation.isHinglish(other) && language.languageCode == other.languageCode
    }

    /// The uploader's own translation of each line (the server splits it off the line) when it is written in `target`;
    /// nil otherwise. On this Mac the language itself is recognised, so English is told apart from Spanish too (the
    /// Windows app can tell only scripts apart).
    static func provided(_ lyrics: [LyricLine], in target: Locale.Language) -> [String]? {
        let given = lyrics.map { $0.translation ?? "" }
        guard given.contains(where: { !$0.isEmpty }), let language = Self.language(of: given), Self.same(language, target) else { return nil }
        return given
    }

    /// Settings › Lyrics › Translate into (`translateInto`): one of `choices`, or "" for the Mac's own language. A
    /// language no longer offered is the Mac's own again.
    static func target(_ chosen: String) -> Locale.Language {
        choices.contains { $0.id == chosen } ? Locale.Language(identifier: chosen) : Locale.current.language
    }

    /// The languages offered in Settings › Lyrics › Translate into besides the Mac's own, with their own names, in the
    /// order of those names: those Apple's framework translates (NN_SELFTEST_TRANSLATEINTO checks each one) and Google's
    /// endpoint takes too, by the codes Google takes. The Windows and Android app offers the same list (#19). Hinglish
    /// is Google's only (`googleOnly`): Apple's framework does not write Hindi in Latin letters.
    static let choices: [(id: String, name: String)] = [
        ("id", "Bahasa Indonesia"), ("de", "Deutsch"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
        (OnlineTranslation.hinglish, "Hinglish"), ("it", "Italiano"), ("nl", "Nederlands"), ("pl", "Polski"), ("pt", "Português"), ("vi", "Tiếng Việt"),
        ("tr", "Türkçe"), ("ru", "Русский"), ("uk", "Українська"), ("ar", "العربية"), ("hi", "हिन्दी"), ("th", "ไทย"),
        ("ja", "日本語"), ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("ko", "한국어"),
    ]
    static let googleOnly: Set<String> = [OnlineTranslation.hinglish]
}

/// Google's public translation endpoint, for languages Apple's framework does not translate. One request per song: the
/// lines joined by newlines, which come back as one translated line each. No key and no account; the request carries
/// only the lyrics' text.
enum OnlineTranslation {
    private static let session = URLSession(configuration: .ephemeral)

    /// Each line's translation, and the language Google found the lines written in ("hi"), when it says.
    nonisolated static func translate(_ texts: [(Int, String)], to target: Locale.Language) async throws -> (lines: [(Int, String)], source: String?) {
        guard let code = Self.code(for: target),
              var parts = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else { return ([], nil) }
        // Hinglish: the Hindi translation, romanized (dt=rm), as the chunk [null, null, romanized, …] that ends the list
        let romanized = code == hinglish
        parts.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
                            URLQueryItem(name: "tl", value: romanized ? "hi" : code), URLQueryItem(name: "dt", value: "t")]
            + (romanized ? [URLQueryItem(name: "dt", value: "rm")] : [])
        guard let url = parts.url else { return ([], nil) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: texts.map(\.1).joined(separator: "\n"))]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // [[["translated", "original", …], …], null, "hi", …]: the translated pieces, joined, are the lines again; the
        // third item is the language they were written in
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [Any], let chunks = reply.first as? [Any] else { return ([], nil) }
        let source = reply.count > 2 ? reply[2] as? String : nil
        let joined = romanized
            ? chunks.compactMap { chunk in (chunk as? [Any]).flatMap { $0.count > 2 && $0[0] is NSNull ? $0[2] as? String : nil } }.joined()
            : chunks.compactMap { ($0 as? [Any])?.first as? String }.joined()
        let lines = joined.components(separatedBy: "\n")
        guard lines.count == texts.count else { throw URLError(.cannotParseResponse) }   // lines that no longer line up
        return (zip(texts, lines).map { ($0.0, $1.trimmingCharacters(in: .whitespaces)) }, source)
    }

    /// `language` as Google's endpoint takes it: "es", "hi"; Chinese as "zh-CN" or "zh-TW" by its script. Google reads a
    /// plain "zh" as simplified, so traditional Chinese (a Mac in Taiwan, or 繁體中文 chosen) needs its own code (#19).
    nonisolated static func code(for language: Locale.Language) -> String? {
        if isHinglish(language) { return hinglish }
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return code }
        return language.maximalIdentifier.contains("-Hant") ? "zh-TW" : "zh-CN"
    }

    /// Hindi in Latin letters, as most people text it: Google's Hindi translation romanized, and Hindi lyrics in
    /// Devanagari romanized. Its code says the script (BCP 47); Google is asked for "hi".
    nonisolated static let hinglish = "hi-Latn"

    nonisolated static func isHinglish(_ language: Locale.Language) -> Bool {
        language.languageCode?.identifier == "hi" && language.script?.identifier == "Latn"
    }

    /// Whether lyrics Google found written in `source` need no translating into `target`: the same language, or, for
    /// Hinglish, Hindi already in Latin letters (Google answers "hi" for Hindi in either script).
    nonisolated static func alreadyIn(_ source: String, _ texts: [String], target: Locale.Language) -> Bool {
        let base = source.split(separator: "-").first.map(String.init)
        if isHinglish(target) { return base == "hi" && latin(texts) }
        return base == code(for: target)?.split(separator: "-").first.map(String.init)
    }

    /// Whether most letters of `texts` (8 in 10, as on Windows) are Latin ones.
    nonisolated static func latin(_ texts: [String]) -> Bool {
        let letters = texts.joined().unicodeScalars.filter(\.properties.isAlphabetic)
        let latin = letters.filter { (0x41...0x24F).contains($0.value) || (0x1E00...0x1EFF).contains($0.value) }
        return !letters.isEmpty && latin.count * 10 >= letters.count * 8
    }
}

/// A session carried to `LyricsTranslations.batch`: each is used for one call, from one place, then let go.
nonisolated struct SessionBox: @unchecked Sendable { let session: TranslationSession }

extension LyricsTranslations {
    /// Every line in one batch, off the main actor; each answer comes back with its line's index.
    nonisolated static func batch(_ texts: [(Int, String)], in box: SessionBox) async throws -> [(Int, String)] {
        let requests = texts.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
        return try await box.session.translations(from: requests).compactMap { response in
            response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
        }
    }
}
