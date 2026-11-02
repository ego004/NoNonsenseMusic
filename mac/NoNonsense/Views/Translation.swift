import SwiftUI
import Translation

/// The lyrics with each line's translation under it. Asks for the translation the first time it shows for a song in
/// a language: straight from the installed language pack when there is one (no view involved), otherwise through the
/// system's prompt to download the language. One view per song and language (its configuration is per pair).
struct TranslatedLyricsView: View {
    let songID: String
    let found: Lyrics
    /// The lyrics' language (nil: this Mac is unsure, and Google is asked), and the one to translate them into
    /// (Settings › Lyrics › Translate into).
    let language: Locale.Language?
    let target: Locale.Language
    /// For timed lyrics, translated as they are shown: the panel showing, and the Genius notes by line.
    var active = true
    var notes: [Int: GeniusNote] = [:]
    var notesURL: String?
    @Environment(Player.self) private var player
    private var lyrics: [LyricLine] { found.lines }
    @State private var configuration: TranslationSession.Configuration?
    private var store: LyricsTranslations { .shared }
    private var key: LyricsTranslations.Key { .init(song: songID, target: target) }

    var body: some View {
        Group {
            if let translated = store.lines[key], found.synced {
                // timed lyrics stay timed once translated: the line being sung lit and followed, a click plays from it,
                // each line's translation under it (20 Oct, as in the Windows app). Its credit is in the panel's header
                TimedLyricsView(lyrics: found, startLine: found.line(at: player.livePosition + 0.1), active: active,
                                notes: notes, notesURL: notesURL, translations: translated)
                    .selfTestFrame("lyrics.translation")
                    .selfTestShown("translation")
            } else if let translated = store.lines[key] {
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
                        // the stack's last row: below the stack, it went where the stack's estimated height ended and
                        // was drawn over the second line of four (CI's pictures, 17 Oct)
                        if let credit = store.credits[key] {
                            Text(credit).textStyle(.caption).foregroundStyle(.secondary)     // text: tertiary is for symbols (#20)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .selfTestFrame("lyrics.translation")
                .selfTestShown("translation")
            } else if store.failed.contains(key) {
                VStack(spacing: 10) {
                    Image(systemName: "character.bubble").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Couldn't translate these lyrics").textStyle(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { store.retry(key) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .selfTestShown("translation failed")
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").textStyle(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .selfTestShown("translating")
                .task(id: key) { await translate() }
            }
        }
        // only when the language still has to be downloaded: the system shows its prompt, then hands over a session
        .translationTask(configuration) { session in
            await finish(try? await LyricsTranslations.batch(texts, in: SessionBox(session: session)), credit: Self.onDevice)
        }
    }

    private var texts: [(Int, String)] { lyrics.enumerated().compactMap { i, line in line.text.isEmpty ? nil : (i, line.text) } }

    private static let onDevice = "Translated on this Mac"

    private func translate() async {
        // the uploader's own translation, when it is in the chosen language: nothing to compute
        if let provided = LyricsTranslations.provided(lyrics, in: target) {
            store.store(provided, for: key, credit: "Translation from the lyrics")
            return
        }
        // Hinglish, which Apple's framework does not write; or this Mac unsure of the lyrics' language (Hindi in English
        // letters): Google tells it, and translates
        guard let language, !OnlineTranslation.isHinglish(target) else { await online(); return }
        // on this Mac when it has the pair of languages (or can download it: the system asks); otherwise, for pairs
        // Apple's framework does not translate (from Punjabi, among others), Google's public translation service
        switch await LanguageAvailability().status(from: language, to: target) {
        case .installed:
            if #available(macOS 26, *) {
                let session = TranslationSession(installedSource: language, target: target)
                await finish(try? await LyricsTranslations.batch(texts, in: SessionBox(session: session)), credit: Self.onDevice)
            } else {
                // macOS 15 can reach an installed language only through .translationTask, which hung inside Now
                // Playing (10 Oct): the online translation instead, credited
                await online()
            }
        case .supported:
            configuration = TranslationSession.Configuration(source: language, target: target)
        default:
            await online()
        }
    }

    /// Google's translation, which also says what the lyrics were written in: already the language asked for, there is
    /// nothing to translate, and the panel says so.
    private func online() async {
        let answer = try? await OnlineTranslation.translate(texts, to: target)
        if let source = answer?.source, OnlineTranslation.alreadyIn(source, texts.map(\.1), target: target) {
            store.markAlready(key)
            return
        }
        await finish(answer?.lines, credit: "Translated by Google")
    }

    private func finish(_ answers: [(Int, String)]?, credit: String) async {
        guard let answers, !answers.isEmpty else { store.fail(key); return }
        var translated = Array(repeating: "", count: lyrics.count)
        for (i, text) in answers where translated.indices.contains(i) { translated[i] = text }
        store.store(translated, for: key, credit: credit)
    }
}
