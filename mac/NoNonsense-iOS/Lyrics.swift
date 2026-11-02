import SwiftUI
import Translation

/// The song's lyrics in place of its cover. Timed: the line being sung bright and large, the rest dim, kept in view as
/// it moves; a tap on a line goes there. Plain: just the text. Asked for when first shown. Translate (labelled, like
/// the Mac's) puts each line's translation under it; with Genius notes on (Settings › Lyrics), underlined lines open
/// their note and ⓘ opens About This Song.
struct LyricsPanel: View {
    @Environment(LyricsStore.self) private var lyrics
    @Environment(Player.self) private var player
    let track: Track
    @AppStorage("geniusNotes") private var genius = false              // Settings › Lyrics › Genius notes (experimental)
    @AppStorage("lyricsTranslated") private var translating = false    // stays on for the next song
    @AppStorage("translateInto") private var translateInto = ""        // Settings › Lyrics › Translate into; "" this device's own
    @State private var openNote: OpenNote?
    @State private var aboutShown = false

    var body: some View {
        let state = lyrics.state(for: track)
        let notes = genius ? lyrics.notes[track.id] : nil
        let target = LyricsTranslations.target(translateInto)
        let key = LyricsTranslations.Key(song: track.id, target: target)
        let store = LyricsTranslations.shared
        let found: Lyrics? = if case .found(let lyrics) = state, !lyrics.lines.isEmpty { lyrics } else { nil }
        // any lyrics can be translated; with it on, the language menu says "Already in English" when there is nothing
        // to translate into it, so another language is one pick away
        let already = found.map { store.isAlready(key, lines: $0.lines) } ?? false
        let translated = translating && !already && found != nil
        let byLine = found.flatMap { notes?.byLine($0.lines) } ?? [:]

        VStack(alignment: .leading, spacing: 4) {
            header(canTranslate: found != nil, already: found != nil && already && translating, notes: notes)
            caption(state, credit: translated ? store.credits[key] : nil)
            Group {
                if translated, let found {
                    // one view per song and language: another language chosen translates the song again
                    TranslationLoader(songID: track.id, found: found,
                                      language: store.language(of: track.id, lines: found.lines), target: target) { lines in
                        lyricsBody(found, byLine: byLine, translations: lines)
                    }
                    .id(key)
                } else {
                    content(state, byLine: byLine)
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: track.id) { if lyrics.state(for: track) == nil { lyrics.fetch(track) } }
        .sheet(item: $openNote) { opened in NoteSheet(note: opened.note, url: notes?.url, play: opened.playFromHere) }
        .sheet(isPresented: $aboutShown) { if let about = notes?.about { AboutSheet(about: about, url: notes?.url) } }
    }

    // MARK: header

    private func header(canTranslate: Bool, already: Bool, notes: GeniusNotes?) -> some View {
        HStack(spacing: 8) {
            if canTranslate {
                // a labelled toggle, filled while on: the bubble icon alone said nothing about what it did
                Button { translating.toggle() } label: {
                    Label("Translate", systemImage: "translate").pill(filled: translating)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(translating ? "On" : "Off")
                if translating {
                    Menu {
                        Picker("Translate into", selection: $translateInto) {
                            Text("System language").tag("")
                            ForEach(LyricsTranslations.choices, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        Text(already ? "Already in \(targetName)" : targetName).lineLimit(1).pill(filled: false)
                    }
                }
            }
            Spacer(minLength: 0)
            if let about = notes?.about, !about.isEmpty {
                Button { aboutShown = true } label: { Image(systemName: "info.circle").font(.title3) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About this song")
            }
        }
        .frame(minHeight: 30)
    }

    /// Who translated them ("Translated on this iPhone"); else where the lyrics are from.
    @ViewBuilder private func caption(_ state: LyricsStore.State?, credit: String?) -> some View {
        if let credit {
            Text(credit).font(.caption).opacity(0.6).lineLimit(1)
        } else if case .found(let found) = state, let source = found.sourceName {
            Text(found.synced ? "from \(source)" : "from \(source) · not timed").font(.caption).opacity(0.6).lineLimit(1)
        }
    }

    /// The language translated into, by its own name ("English", "हिन्दी"): the one chosen, else this device's.
    private var targetName: String {
        if let chosen = LyricsTranslations.choices.first(where: { $0.id == translateInto }) { return chosen.name }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? "Your language"
    }

    // MARK: body

    @ViewBuilder private func content(_ state: LyricsStore.State?, byLine: [Int: GeniusNote]) -> some View {
        switch state {
        case .found(let found) where found.lines.isEmpty:
            message("Couldn't find lyrics")
        case .found(let found):
            lyricsBody(found, byLine: byLine, translations: nil)
        case .unreachable:
            VStack(spacing: 10) {
                message("Couldn't reach the server")
                Button("Try Again") { lyrics.fetch(track) }.buttonStyle(.bordered).tint(.white)
            }
        case .loading, nil:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Finding lyrics…").font(.callout).opacity(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func lyricsBody(_ found: Lyrics, byLine: [Int: GeniusNote], translations: [String]?) -> some View {
        if found.synced {
            // one view per song: its loop lights lines by this song's times
            TimedLines(found: found, byLine: byLine, translations: translations, song: track.id) { index in openNoteAt(index, found, byLine) }
                .id(track.id)
        } else {
            PlainLines(found: found, byLine: byLine, translations: translations) { index in openNoteAt(index, found, byLine) }
        }
    }

    private func openNoteAt(_ index: Int, _ found: Lyrics, _ byLine: [Int: GeniusNote]) {
        guard let note = byLine[index] else { return }
        // timed lyrics: the note's own card offers Play from Here, since a tap on a noted line opens the note
        let from = found.lines[safe: index]?.startMs.map { Double($0) / 1000 }
        openNote = OpenNote(line: index, note: note, playFromHere: from.map { time in { player.seek(to: time); openNote = nil } })
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.headline).opacity(0.7).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Genius note a tap opened: the line it is about, and (timed lyrics) a way to play from there.
private struct OpenNote: Identifiable {
    let line: Int
    let note: GeniusNote
    let playFromHere: (() -> Void)?
    var id: Int { line }
}

// MARK: - the lines

private extension View {
    /// A capsule button's face on the cover's dark gradient: filled white while on, a faint white ground while off.
    func pill(filled: Bool) -> some View {
        self.font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(filled ? Color.white : Color.white.opacity(0.18), in: Capsule())
            .foregroundStyle(filled ? Color.black.opacity(0.85) : Color.white)
    }
}

/// Timed lyrics. The line being sung is looked at four times a second, but the view is drawn again only when it changes.
private struct TimedLines: View {
    @Environment(Player.self) private var player
    let found: Lyrics
    let byLine: [Int: GeniusNote]
    let translations: [String]?
    let song: String
    let openNote: (Int) -> Void
    @State private var current: Int?

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(found.lines.enumerated()), id: \.offset) { i, line in
                        let noted = byLine[i] != nil
                        Button {
                            if noted { openNote(i) } else if let ms = line.startMs { player.seek(to: Double(ms) / 1000) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title2.weight(.bold))
                                    .underline(noted, pattern: .dot)
                                if let translated = translations?[safe: i], !translated.isEmpty {
                                    Text(translated).font(.body).opacity(0.85)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(i == current ? 1 : 0.35)
                            .scaleEffect(i == current ? 1 : 0.96, anchor: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.vertical, 120)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { reader.scrollTo(line, anchor: .center) }
            }
            .animation(.easeOut(duration: 0.3), value: current)
        }
        .task(id: song) {
            current = nil
            while !Task.isCancelled {
                let now = found.line(at: player.livePosition)
                if now != current { current = now }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// Plain lyrics (no times): line by line, each with its translation under it when translated.
private struct PlainLines: View {
    let found: Lyrics
    let byLine: [Int: GeniusNote]
    let translations: [String]?
    let openNote: (Int) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: translations == nil ? 4 : 14) {
                ForEach(Array(found.lines.enumerated()), id: \.offset) { i, line in
                    if line.text.isEmpty {
                        Color.clear.frame(height: 10)
                    } else {
                        let noted = byLine[i] != nil
                        let translated = translations?[safe: i].flatMap { $0.isEmpty ? nil : $0 }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.text)
                                .font(translated == nil ? .title3.weight(.semibold) : .callout)
                                .opacity(translated == nil ? 1 : 0.6)
                                .underline(noted, pattern: .dot)
                            if let translated { Text(translated).font(.title3.weight(.semibold)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if noted { openNote(i) } }
                    }
                }
            }
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Genius

private struct NoteSheet: View {
    let note: GeniusNote
    let url: String?
    let play: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("“\(note.fragment)”").font(.subheadline.italic()).foregroundStyle(.secondary)
                    Text(note.text).textSelection(.enabled)
                    GeniusCredit(url: url, verified: note.verified)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Genius Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let play { ToolbarItem(placement: .cancellationAction) { Button("Play from Here", action: play) } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Genius's About this song: its description, who produced it, what it samples.
private struct AboutSheet: View {
    let about: GeniusAbout
    let url: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let description = about.description { Text(description).textSelection(.enabled) }
                    if !about.producedBy.isEmpty { fact("Produced by", about.producedBy.joined(separator: ", ")) }
                    if !about.samples.isEmpty { fact("Samples", about.samples.joined(separator: "\n")) }
                    GeniusCredit(url: url, verified: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("About This Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// "Genius", a link to the song's page there when there is one: the notes are theirs.
private struct GeniusCredit: View {
    let url: String?
    let verified: Bool

    var body: some View {
        let label = verified ? "Genius · Verified by the artist" : "Genius"
        if let url, let link = URL(string: url) {
            Link(label, destination: link).font(.caption)
        } else {
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - translating

/// Asks for the translation the first time it shows for a song in a language: straight from the installed language pack
/// when there is one (iOS 26), otherwise through the system's prompt to download the language; what Apple's framework
/// does not translate (Punjabi, Hinglish) goes to Google. Shows `content` with the lines once they are in. One view per
/// song and language (its configuration is per pair). The same flow as the Mac's TranslatedLyricsView.
private struct TranslationLoader<Content: View>: View {
    let songID: String
    let found: Lyrics
    /// The lyrics' language (nil: this device is unsure, and Google is asked), and the one to translate them into.
    let language: Locale.Language?
    let target: Locale.Language
    @ViewBuilder let content: ([String]) -> Content
    @State private var configuration: TranslationSession.Configuration?
    private var store: LyricsTranslations { .shared }
    private var key: LyricsTranslations.Key { .init(song: songID, target: target) }
    private var lyrics: [LyricLine] { found.lines }
    private var texts: [(Int, String)] { lyrics.enumerated().compactMap { i, line in line.text.isEmpty ? nil : (i, line.text) } }

    var body: some View {
        Group {
            if let translated = store.lines[key] {
                content(translated)
            } else if store.failed.contains(key) {
                VStack(spacing: 10) {
                    Image(systemName: "character.bubble").font(.system(size: 34)).opacity(0.7)
                    Text("Couldn't translate these lyrics").font(.callout).opacity(0.7)
                    Button("Try Again") { store.retry(key) }.buttonStyle(.bordered).tint(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Translating…").font(.callout).opacity(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) { await translate() }
            }
        }
        // only when the language still has to be downloaded: the system shows its prompt, then hands over a session
        .translationTask(configuration) { session in
            await finish(try? await LyricsTranslations.batch(texts, in: SessionBox(session: session)), credit: Self.onDevice)
        }
    }

    private static var onDevice: String { "Translated on this \(UIDevice.current.model)" }

    private func translate() async {
        // the uploader's own translation, when it is in the chosen language: nothing to compute
        if let provided = LyricsTranslations.provided(lyrics, in: target) {
            store.store(provided, for: key, credit: "Translation from the lyrics")
            return
        }
        // Hinglish, which Apple's framework does not write; or this device unsure of the lyrics' language (Hindi in
        // English letters): Google tells it, and translates
        guard let language, !OnlineTranslation.isHinglish(target) else { await online(); return }
        switch await LanguageAvailability().status(from: language, to: target) {
        case .installed:
            if #available(iOS 26, *) {
                let session = TranslationSession(installedSource: language, target: target)
                await finish(try? await LyricsTranslations.batch(texts, in: SessionBox(session: session)), credit: Self.onDevice)
            } else {
                // as on macOS 15, where an installed language is reachable only through .translationTask (which hung
                // inside Now Playing there): the online translation instead, credited
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
