import NaturalLanguage
import SwiftUI
import Translation

/// Lyrics translated on this Mac by Apple's Translation framework: no server and no third party sees them. A song is
/// translated once, when asked, and kept until the app quits. macOS offers to download a language the first time it
/// is needed.
@MainActor
@Observable
final class LyricsTranslations {
    static let shared = LyricsTranslations()
    /// Song id → one translated line per lyric line ("" for a gap).
    private(set) var lines: [String: [String]] = [:]
    private(set) var failed: Set<String> = []
    /// Song id → who translated it, shown under the translation.
    private(set) var credits: [String: String] = [:]

    /// Song id → the lyrics' language when it is not the reader's (nil inside: the reader's own or unclear).
    @ObservationIgnored private var languages: [String: Locale.Language?] = [:]

    /// The song's foreign language, worked out once per song.
    func language(of song: String, lines: [LyricLine]) -> Locale.Language? {
        if let known = languages[song] { return known }
        let found = Self.foreignLanguage(of: lines)
        languages[song] = found
        return found
    }

    func store(_ translated: [String], for song: String, credit: String) {
        lines[song] = translated
        credits[song] = credit
    }
    func fail(_ song: String) { failed.insert(song) }
    /// Try Again: the next showing asks once more.
    func retry(_ song: String) { failed.remove(song) }

    /// The language the lyrics are written in, when it is not the reader's own; nil when they match or it is unclear.
    static func foreignLanguage(of lines: [LyricLine]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.prefix(40).map(\.text).joined(separator: "\n"))
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return nil }
        let language = Locale.Language(identifier: found.rawValue)
        let mine = Locale.current.language
        return language.languageCode == mine.languageCode ? nil : language
    }
}

/// The lyrics with each line's translation under it. Asks for the translation the first time it shows for a song:
/// straight from the installed language pack when there is one (no view involved), otherwise through the system's
/// prompt to download the language.
struct TranslatedLyricsView: View {
    let songID: String
    let lyrics: [LyricLine]
    let language: Locale.Language
    @State private var configuration: TranslationSession.Configuration?
    private var store: LyricsTranslations { .shared }

    var body: some View {
        Group {
            if let translated = store.lines[songID] {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(zip(lyrics.indices, translated)), id: \.0) { i, line in
                            if !lyrics[i].text.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(lyrics[i].text).textStyle(.callout).foregroundStyle(.secondary)
                                    Text(line).lyricsStyle()
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    if let credit = store.credits[songID] {
                        Text(credit).textStyle(.caption).foregroundStyle(.secondary)         // text: tertiary is for symbols (#20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
                .selfTestFrame("lyrics.translation")
            } else if store.failed.contains(songID) {
                VStack(spacing: 10) {
                    Image(systemName: "character.bubble").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Couldn't translate these lyrics").textStyle(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { store.retry(songID) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").textStyle(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: songID) { await translate() }
            }
        }
        // only when the language still has to be downloaded: the system shows its prompt, then hands over a session
        .translationTask(configuration) { session in
            await finish(try? await Self.translate(texts, in: SessionBox(session: session)), credit: Self.onDevice)
        }
    }

    private var texts: [(Int, String)] { lyrics.enumerated().compactMap { i, line in line.text.isEmpty ? nil : (i, line.text) } }

    private static let onDevice = "Translated on this Mac"

    private func translate() async {
        // the uploader's own translation, when it is in the reader's language: nothing to compute
        let provided = lyrics.map { $0.translation ?? "" }
        if provided.contains(where: { !$0.isEmpty }),
           LyricsTranslations.foreignLanguage(of: provided.map { LyricLine(startMs: nil, text: $0) }) == nil {
            store.store(provided, for: songID, credit: "Translation from the lyrics")
            return
        }
        // on this Mac when it has the language (or can download it: the system asks); otherwise, for languages Apple's
        // framework does not translate (Punjabi, among others), Google's public translation service
        let target = Locale.current.language
        switch await LanguageAvailability().status(from: language, to: target) {
        case .installed:
            if #available(macOS 26, *) {
                let session = TranslationSession(installedSource: language, target: target)
                await finish(try? await Self.translate(texts, in: SessionBox(session: session)), credit: Self.onDevice)
            } else {
                // macOS 15 can reach an installed language only through .translationTask, which hung inside Now
                // Playing (10 Oct): the online translation instead, credited
                await finish(try? await OnlineTranslation.translate(texts, to: target), credit: "Translated by Google")
            }
        case .supported:
            configuration = TranslationSession.Configuration(source: language, target: target)
        default:
            await finish(try? await OnlineTranslation.translate(texts, to: target), credit: "Translated by Google")
        }
    }

    private func finish(_ answers: [(Int, String)]?, credit: String) async {
        guard let answers, !answers.isEmpty else { store.fail(songID); return }
        var translated = Array(repeating: "", count: lyrics.count)
        for (i, text) in answers where translated.indices.contains(i) { translated[i] = text }
        store.store(translated, for: songID, credit: credit)
    }
}

/// A session carried to the call below: each is used for one call, from one place, then let go.
private nonisolated struct SessionBox: @unchecked Sendable { let session: TranslationSession }

extension TranslatedLyricsView {
    /// Every line in one batch, off the main actor; each answer comes back with its line's index.
    fileprivate nonisolated static func translate(_ texts: [(Int, String)], in box: SessionBox) async throws -> [(Int, String)] {
        let requests = texts.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
        return try await box.session.translations(from: requests).compactMap { response in
            response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
        }
    }
}

/// Google's public translation endpoint, for languages Apple's framework does not translate. One request per song: the
/// lines joined by newlines, which come back as one translated line each. No key and no account; the request carries
/// only the lyrics' text.
enum OnlineTranslation {
    private static let session = URLSession(configuration: .ephemeral)

    nonisolated static func translate(_ texts: [(Int, String)], to target: Locale.Language) async throws -> [(Int, String)] {
        guard let code = target.languageCode?.identifier,
              var parts = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else { return [] }
        parts.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
                            URLQueryItem(name: "tl", value: code), URLQueryItem(name: "dt", value: "t")]
        guard let url = parts.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: texts.map(\.1).joined(separator: "\n"))]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // [[["translated", "original", …], …], …]: the translated pieces, joined, are the lines again
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [Any], let chunks = reply.first as? [Any] else { return [] }
        let joined = chunks.compactMap { ($0 as? [Any])?.first as? String }.joined()
        let lines = joined.components(separatedBy: "\n")
        guard lines.count == texts.count else { throw URLError(.cannotParseResponse) }   // lines that no longer line up
        return zip(texts, lines).map { ($0.0, $1.trimmingCharacters(in: .whitespaces)) }
    }
}
