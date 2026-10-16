import SwiftUI

/// The look's defaults, in one place: the window and Settings must agree on them.
enum Look {
    static let windowOpacity = 0.5      // half see-through
    /// The most see-through the window gets. At 0 only the blur was left behind the text, and a video call
    /// behind the window showed through enough to make the app unreadable (5 Oct).
    static let minWindowOpacity = 0.3
    static let artStrength = 0.7        // how strongly the cover colours the window
    static let windowBlur = 0.85        // 0 = clear (the desktop sharp), 1 = frosted
    static let cardSize: CGFloat = 148  // covers on Home and in shelves (Settings › Appearance › Card size)
    static let textScale: CGFloat = 1   // the Mac's own text sizes (Settings › Appearance › Text size)
    /// Off: a still background in the playing cover's colours. Moving costs CPU on every frame (see Settings).
    static let animateBackdrop = false
    /// Seconds a lyric line change takes, the fade and the scroll together (Settings › Lyrics). 0.5 felt quick (7 Oct)
    static let lyricsMotion = 0.9
    /// Off: covers on Home show ▶ on hover, nothing more. On: they tilt toward the pointer with a light (it redraws the
    /// window as the pointer moves over a cover)
    static let coverTilt = false
    /// On: a soft highlight under the pointer and a small press on the app's plain buttons (Settings › Appearance)
    static let buttonFeedback = true
    /// On: three moving bars on the playing song (Settings › Appearance). Core Animation bars: no measurable cost in the
    /// app or WindowServer (7 Oct). Off: a still speaker.
    static let animatedSpeaker = true

    // Settings › Appearance › Surfaces: each part's blur and fill. The sidebar and the bar start at 0 / 0: exactly
    // the look they had before these settings (the system's glass alone).
    static let sidebarBlur = 0.0
    static let sidebarSolid = 0.0
    static let barBlur = 0.9            // used when the bar is Frosted instead of Liquid Glass
    static let barSolid = 0.0
    static let nowPlayingBlur = 1.0     // with 0.75 fill, close to the thick material Now Playing had before
    static let nowPlayingSolid = 0.75
    static let nowPlayingColour = 0.98  // it was the window's colour strength × 1.4

    /// With little blur, a surface keeps some of the window's colour, so its text stays readable over whatever is
    /// under it: the same floor as the window's, fading out as the blur takes over.
    static func readable(solid: Double, blur: Double) -> Double { max(solid, minWindowOpacity * (1 - blur)) }
}

/// The player bar: Liquid Glass (the system's, reacts to the pointer), or Frosted (a plain blur you can thin).
enum BarStyle: String, CaseIterable, Identifiable {
    case glass, frosted
    var id: String { rawValue }
    var label: String { self == .glass ? "Liquid Glass" : "Frosted" }
}

/// The parts of the window Settings › Appearance › Surfaces can change one by one.
enum SurfacePart: String, CaseIterable, Identifiable {
    case main, sidebar, bar, nowPlaying
    var id: String { rawValue }
    var label: String {
        switch self { case .main: "Main area"; case .sidebar: "Sidebar"; case .bar: "Player bar"; case .nowPlaying: "Now Playing" }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// The Settings window (⌘,): tabs with symbols along the top, the way the Mac's own apps do it.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintbrush") }
            TrackpadSettings().tabItem { Label("Trackpad", systemImage: "hand.point.up.left") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            LyricsSettings().tabItem { Label("Lyrics", systemImage: "quote.bubble") }
            DiscordSettings().tabItem { Label("Discord", systemImage: "person.wave.2") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            ServerSettings().tabItem { Label("Server", systemImage: "server.rack") }
            FootprintSettings().tabItem { Label("Footprint", systemImage: "gauge.with.dots.needle.33percent") }
        }
        .frame(width: 620)
        .background(KeepOnScreen())
    }
}

/// Moves the Settings window up when a taller tab would push its bottom off the screen. The window grows downward
/// from where its top was left, so a window opened low ran 62 pt past the bottom (Appearance, 7 Oct) even though
/// every page fits the screen's height.
private struct KeepOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> KeepOnScreenView { KeepOnScreenView() }
    func updateNSView(_ view: KeepOnScreenView, context: Context) {}
}

final class KeepOnScreenView: NSView {
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        #if DEBUG
        SelfTest.keepOutOfSight(window)
        #endif
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
        nudge()
    }

    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func nudge() {
        guard let window, let screen = window.screen?.visibleFrame else { return }
        var frame = window.frame
        guard frame.minY < screen.minY else { return }
        frame.origin.y = min(screen.minY, screen.maxY - frame.height)
        window.setFrameOrigin(frame.origin)
    }
}

private struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity
    @AppStorage("windowBlur") private var windowBlur = Look.windowBlur
    @AppStorage("artStrength") private var artStrength = Look.artStrength
    @AppStorage("animateBackdrop") private var animateBackdrop = Look.animateBackdrop
    @AppStorage("buttonFeedback") private var buttonFeedback = Look.buttonFeedback
    @AppStorage("animatedSpeaker") private var animatedSpeaker = Look.animatedSpeaker
    @AppStorage("coverTilt") private var coverTilt = Look.coverTilt
    @AppStorage("textScale") private var textScale = Look.textScale
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)
    // which sections are open, remembered; Colours (seven rows) starts closed
    @AppStorage("settings.open.window") private var openWindow = true
    @AppStorage("settings.open.sizes") private var openSizes = true
    @AppStorage("settings.open.colours") private var openColours = false
    @AppStorage("settings.open.surfaces") private var openSurfaces = true
    @AppStorage("settings.surfacePart") private var part = SurfacePart.main
    @AppStorage("sidebarBlur") private var sidebarBlur = Look.sidebarBlur
    @AppStorage("sidebarSolid") private var sidebarSolid = Look.sidebarSolid
    @AppStorage("barStyle") private var barStyle = BarStyle.glass
    @AppStorage(GlassSetting.key) private var liquidGlass = true
    @AppStorage("barBlur") private var barBlur = Look.barBlur
    @AppStorage("barSolid") private var barSolid = Look.barSolid
    @AppStorage("nowPlayingBlur") private var nowPlayingBlur = Look.nowPlayingBlur
    @AppStorage("nowPlayingSolid") private var nowPlayingSolid = Look.nowPlayingSolid
    @AppStorage("nowPlayingColour") private var nowPlayingColour = Look.nowPlayingColour
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Form {
            Section(isExpanded: $openWindow) {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if #available(macOS 26, *) {
                    Toggle(isOn: $liquidGlass) {
                        Text("Liquid Glass")
                        Text("Off: the frosted materials of earlier macOS versions.")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $buttonFeedback) {
                    Text("Button feedback")
                    Text("A soft highlight and a small press on buttons.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $coverTilt) {
                    Text("Covers tilt toward the pointer")
                    Text("Covers tilt toward the pointer. Uses CPU while you hover.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $animatedSpeaker) {
                    Text("Moving bars on the playing song")
                    Text("macOS animates them, not the app: no measurable cost.").foregroundStyle(.secondary)
                }
                Toggle(isOn: $animateBackdrop) {
                    Text("Moving background")
                    // measured 7 Oct, a debug build on an Apple silicon Mac, a song playing: still vs moving
                    Text("Uses about 5% more CPU, and 10–14% more in Now Playing.")
                        .foregroundStyle(.secondary)
                }
                Text("Reduce Motion and Reduce Transparency in System Settings › Accessibility override these and the surfaces below.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Window")
            }

            // each part of the window on its own: pick a part, its blur and fill are under it
            Section(isExpanded: $openSurfaces) {
                Picker("Part", selection: $part) {
                    ForEach(SurfacePart.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch part {
                case .main:
                    LabeledContent("Blur") { RangeSlider(value: $windowBlur, low: "Clear", high: "Frosted") }
                    LabeledContent("Transparency") { RangeSlider(value: $windowOpacity, in: Look.minWindowOpacity...1, low: "See-through", high: "Solid") }
                    LabeledContent("Colour strength") { RangeSlider(value: $artStrength, low: "Soft", high: "Vivid") }
                    surfaceNote("Behind lists and Home. The colour comes from Colours › Background.")
                case .sidebar:
                    LabeledContent("Blur") { RangeSlider(value: $sidebarBlur, low: "Glass", high: "Frosted") }
                    LabeledContent("Transparency") { RangeSlider(value: $sidebarSolid, low: "See-through", high: "Solid") }
                    surfaceNote("Frost and colour over the sidebar's glass.")
                case .bar:
                    Picker("Style", selection: $barStyle) {
                        ForEach(BarStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if barStyle == .frosted {
                        LabeledContent("Blur") { RangeSlider(value: $barBlur, low: "Clear", high: "Frosted") }
                    }
                    LabeledContent("Transparency") { RangeSlider(value: $barSolid, low: "See-through", high: "Solid") }
                    surfaceNote(barStyle == .glass ? "Liquid Glass bends the light and reacts to the pointer. Its tint is in Colours › Player bar."
                                                   : "A plain blur of what scrolls under the bar. Its tint is in Colours › Player bar.")
                case .nowPlaying:
                    LabeledContent("Blur") { RangeSlider(value: $nowPlayingBlur, low: "Clear", high: "Frosted") }
                    LabeledContent("Transparency") { RangeSlider(value: $nowPlayingSolid, low: "See-through", high: "Solid") }
                    LabeledContent("Colour strength") { RangeSlider(value: $nowPlayingColour, low: "Soft", high: "Vivid") }
                    surfaceNote("The full-window view (⇧⌘F).")
                }
            } header: {
                Text("Surfaces")
            }

            Section(isExpanded: $openSizes) {
                LabeledContent("Text size") { RangeSlider(value: $textScale, in: 0.85...1.4, low: "Smaller", high: "Larger") }
                LabeledContent("Card size") { RangeSlider(value: $cardSize, in: 116...210, low: "Small", high: "Large") }
                // the sizes, live: a song row and a card as they will look
                HStack(alignment: .center, spacing: 16) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.linearGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: cardSize * 0.45, height: cardSize * 0.45)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Song title").textStyle(.body, weight: .medium)
                        Text("Artist").textStyle(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .environment(\.textScale, textScale)
                .animation(.snappy(duration: 0.2), value: textScale)
                .animation(.snappy(duration: 0.2), value: cardSize)
                Text("Lists, cards, the player and Now Playing. The card is shown at half size.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Sizes")
            }

            Section(isExpanded: $openColours) {
                ForEach(ThemeStore.Element.allCases) { ThemeRow(element: $0) }
                HStack(alignment: .firstTextBaseline) {
                    Text("Song: the playing cover's colour. Custom: type a hex code or click the swatch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Set all") {
                        ForEach(ThemeStore.Mode.allCases) { mode in Button("All \(mode.label)") { theme.setAll(mode) } }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Colours")
            }

            Section {
                HStack {
                    Text("Every setting on this page back to how it came").foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset all") {
                        windowOpacity = Look.windowOpacity
                        windowBlur = Look.windowBlur
                        artStrength = Look.artStrength
                        sidebarBlur = Look.sidebarBlur
                        sidebarSolid = Look.sidebarSolid
                        barStyle = .glass
                        barBlur = Look.barBlur
                        barSolid = Look.barSolid
                        nowPlayingBlur = Look.nowPlayingBlur
                        nowPlayingSolid = Look.nowPlayingSolid
                        nowPlayingColour = Look.nowPlayingColour
                        animateBackdrop = Look.animateBackdrop
                        buttonFeedback = Look.buttonFeedback
                        animatedSpeaker = Look.animatedSpeaker
                        coverTilt = Look.coverTilt
                        textScale = Look.textScale
                        cardSize = Double(Look.cardSize)
                        theme.reset()
                    }
                }
            }
        }
        .settingsPage()
        .animation(.snappy(duration: 0.25), value: [openWindow, openSizes, openColours, openSurfaces])
        .animation(.snappy(duration: 0.25), value: part)
        // Colours opens on its own: with everything open the page was 1,165 pt tall (measured 6 Oct). The page now
        // scrolls past the screen's height anyway (SettingsPage), but one long scroll is worse than a short page.
        .onChange(of: openColours) { _, open in if open { openWindow = false; openSizes = false; openSurfaces = false } }
        .onChange(of: openWindow) { _, open in if open { openColours = false } }
        .onChange(of: openSizes) { _, open in if open { openColours = false } }
        .onChange(of: openSurfaces) { _, open in if open { openColours = false } }
    }

    private func surfaceNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// One coloured element: System, Song or Custom. Song shows the colour it is taking now; Custom adds a hex code and a swatch.
private struct ThemeRow: View {
    let element: ThemeStore.Element
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                switch theme.mode(element) {
                case .custom:
                    HexColorControl(hex: Binding(get: { theme.hex(element) }, set: { theme.setHex($0, for: element) }))
                case .song:
                    Circle().fill(theme.songColor ?? Color.secondary.opacity(0.3)).frame(width: 14, height: 14)
                        .help(theme.songColor == nil ? "No colourful cover playing: the system's colour is used" : "The playing cover's colour")
                case .system:
                    EmptyView()
                }
                Picker(element.title, selection: Binding(get: { theme.mode(element) }, set: { theme.setMode($0, for: element) })) {
                    ForEach(ThemeStore.Mode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        } label: {
            Text(element.title)
            Text(element.detail)
        }
    }
}

private struct TrackpadSettings: View {
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        Form {
            Section {
                Toggle("Haptic ticks", isOn: $haptics)
            } footer: {
                Text("Light ticks while you drag the volume or the progress line.")
                    .foregroundStyle(.secondary)
            }
            Section("Gestures") {
                LabeledContent("Two-finger swipe on the player") { Text("Next / previous song").foregroundStyle(.secondary) }
                LabeledContent("Pinch out on the player") { Text("Open Now Playing").foregroundStyle(.secondary) }
                LabeledContent("Pinch in on Now Playing") { Text("Close it").foregroundStyle(.secondary) }
            }
        }
        .settingsPage()
    }
}

/// Settings › Playback.
private struct PlaybackSettings: View {
    @AppStorage("versionPreference") private var version = "explicit"
    @AppStorage("preferredSource") private var preferredSource = ""        // "" = Automatic (Track.preferredSource)
    @AppStorage("autoplay") private var autoplay = true                     // also ∞ in Up Next
    @AppStorage("autoplaySkipsRecent") private var skipsRecent = true       // Player.autoplaySkipsRecent
    @Environment(Player.self) private var player

    var body: some View {
        Form {
            Section {
                Toggle("Autoplay", isOn: $autoplay)
                    .onChange(of: autoplay) { _, on in if on { player.upNextChanged() } }
                Toggle("Skip songs I played or skipped lately", isOn: $skipsRecent)
                    .disabled(!autoplay)
            } header: {
                Text("Autoplay")
            } footer: {
                Text("When Up Next runs low, songs like the last one are added. They leave out your last 50 songs unless you switch that off.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Preferred Source", selection: $preferredSource) {
                    Text("Automatic").tag("")
                    Divider()
                    Text("YouTube Music").tag("ytmusic")
                    Text("JioSaavn").tag("jiosaavn")
                    Text("YouTube").tag("youtube")
                }
                Picker("Version", selection: $version) {
                    Text("Explicit").tag("explicit")
                    Text("Clean").tag("clean")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("For songs found on more than one source, or in both versions. Applies to songs listed from now on.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPage()
    }
}

/// When the app asks the server for lyrics (Settings › Lyrics).
enum LyricsFetch: String, CaseIterable, Identifiable {
    case songStart, onOpen
    var id: String { rawValue }
    var label: String { self == .songStart ? "When a song starts, and the next song's too" : "Only when I open Lyrics" }
}

private struct LyricsSettings: View {
    @AppStorage("lyricsFetch") private var fetch = LyricsFetch.songStart
    @AppStorage("lyricsMotion") private var motion = Look.lyricsMotion
    @AppStorage("geniusNotes") private var genius = false                // experimental, off by default (8 Oct)
    @AppStorage("translateInto") private var translateInto = ""          // LyricsTranslations.target: "" the Mac's own (#19)

    var body: some View {
        Form {
            Section {
                Picker("Fetch lyrics", selection: $fetch) {
                    ForEach(LyricsFetch.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent {
                    RangeSlider(value: $motion, in: 0.3...1.5, low: "Quick", high: "Slow")
                } label: {
                    Text("Line change")
                    Text(String(format: "%.1f s: the light and the scroll move together", motion)).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Fetching when a song starts has the lyrics ready when you open them. Downloaded songs keep their lyrics offline.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Translate into", selection: $translateInto) {
                    Text("System language").tag("")
                    Divider()
                    ForEach(LyricsTranslations.choices, id: \.id) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("For Translate in Lyrics. This Mac translates them (macOS asks to download a language the first time); what it can't goes to Google. The line under the translation says which.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $genius) {
                    Text("Genius notes")
                    Text("Underlined lines show Genius annotations, and ⓘ shows About This Song. Adds one lookup per song.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Experimental")
            }
        }
        .settingsPage()
    }
}

private struct DiscordSettings: View {
    @AppStorage("settings.open.share") private var openShare = true
    @AppStorage("settings.open.preview") private var openPreview = true
    @Environment(Presence.self) private var presence
    @State private var messageDraft = ""                 // applied on Return: each change is a command to Discord

    var body: some View {
        @Bindable var presence = presence
        Form {
            Section {
                Toggle("Show what I'm listening to", isOn: Binding(get: { presence.enabled }, set: { presence.setEnabled($0) }))
                LabeledContent("Status") { Text(presence.status).foregroundStyle(.secondary) }
                Button("Send a test status") { presence.sendTest() }
            } footer: {
                Text("Needs the Discord app open on this Mac.").foregroundStyle(.secondary)
            }

            Section(isExpanded: $openShare) {
                Picker("Your status line shows", selection: $presence.statusLine) {
                    Text("The song").tag(2)
                    Text("The artist").tag(1)
                    Text("The app's name").tag(0)
                }
                Toggle("The song", isOn: $presence.shareSong)
                Toggle("The artist", isOn: $presence.shareArtist)
                Toggle("The cover", isOn: $presence.shareArt)
                Toggle("The NoNonsenseMusic logo", isOn: $presence.shareLogo)
                Toggle(isOn: $presence.sharePlaylist) {
                    Text("The playlist's name")
                    Text("Adds “from Gym” after the artist when a song plays from a playlist").foregroundStyle(.secondary)
                }
                Toggle("The time bar", isOn: $presence.shareTime)
                Picker("When paused", selection: $presence.whenPaused) {
                    Text("Show a message").tag("message")
                    Text("Keep the song").tag("keep")
                    Text("Clear the status").tag("clear")
                }
                if presence.whenPaused == "message" {
                    TextField("Message", text: $messageDraft, prompt: Text("Nothing playing"))
                        .onSubmit { presence.pausedMessage = messageDraft }
                        .onAppear { messageDraft = presence.pausedMessage }
                }
            } header: {
                Text("Share")
            }



            Section(isExpanded: $openPreview) {
                DiscordPreview()
            } header: {
                Text("What friends see")
            }
        }
        .settingsPage()
    }
}

/// A sketch of the profile card and the member-list line, following the switches. Uses the last song played.
private struct DiscordPreview: View {
    @Environment(Presence.self) private var presence

    var body: some View {
        let track = presence.lastTrack
        let title = track?.title ?? "Blinding Lights"
        let artist = track?.artistLine ?? "The Weeknd"
        VStack(alignment: .leading, spacing: 10) {
            Text("LISTENING TO NONONSENSE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if presence.shareArt, let track {
                    ArtworkView(url: track.image, size: 60, radius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07))
                        .frame(width: 60, height: 60)
                        .overlay { Image(systemName: "music.note").foregroundStyle(.tertiary) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if presence.shareSong { Text(title).font(.callout.weight(.semibold)).lineLimit(1) }
                    let from = presence.sharePlaylist ? (presence.lastPlaylist ?? (track == nil ? "Gym" : nil)) : nil
                    let state = [presence.shareArtist ? "by \(artist)" : nil, from.map { "from “\($0)”" }].compactMap { $0 }.joined(separator: " · ")
                    if !state.isEmpty { Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if presence.shareTime {
                        HStack(spacing: 6) {
                            Text("1:12")
                            Capsule().fill(.primary.opacity(0.15))
                                .overlay(alignment: .leading) { Capsule().fill(.primary.opacity(0.6)).frame(width: 52) }
                                .frame(width: 140, height: 4)
                            Text(formatTime(Double(track?.duration ?? 200)))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Text("In the member list:").foregroundStyle(.secondary)
                Text("Listening to \(statusLine(title: title, artist: artist))").fontWeight(.medium)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func statusLine(title: String, artist: String) -> String {
        switch presence.statusLine {
        case 2 where presence.shareSong: title
        case 1 where presence.shareArtist: "by \(artist)"
        default: "NoNonsense"
        }
    }
}

private struct ServerSettings: View {
    @AppStorage("serverURL") private var serverURL = API.defaultServer
    @AppStorage("backendFolder") private var backendFolder = ServerLauncher.defaultBackendFolder
    @AppStorage("serverReload") private var reloads = false
    @Environment(ServerLauncher.self) private var server
    @Environment(LibraryStore.self) private var library
    @State private var serverOK: Bool?
    // drafts, saved on Return: a field bound to the setting saved whatever it showed, even a test window's
    // launch-argument address, when its window closed (that is how 8765 became your saved address, 7 Oct)
    @State private var addressDraft = ""
    @State private var folderDraft = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $addressDraft, prompt: Text(API.defaultServer))
                    .onSubmit {
                        serverURL = addressDraft.trimmingCharacters(in: .whitespaces).isEmpty ? API.defaultServer : addressDraft
                        // the library comes from the new server at once (it kept showing the old one's until a relaunch)
                        Task {
                            await server.ensureRunning()
                            if await Connectivity.shared.checkServer() { await library.refresh() }
                        }
                    }
                    .onAppear { addressDraft = serverURL }
                LabeledContent("Status") {
                    switch serverOK {
                    case .none: Text("Checking…").foregroundStyle(.secondary)
                    case .some(true): Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                TextField("Backend folder", text: $folderDraft)
                    .onSubmit { backendFolder = folderDraft }
                    .onAppear { folderDraft = backendFolder }
                LabeledContent("Auto-start") { Text(server.summary).foregroundStyle(.secondary) }
                Toggle(isOn: $reloads) {
                    Text("Reload when the backend's code changes")
                    Text("For developing the server: it restarts whenever its code changes. Uses about 140 MB more memory.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start now") { Task { await server.ensureRunning(); serverOK = await API.health() } }
                        .disabled(serverOK == true)
                    Button("Restart") { Task { await server.restart(); serverOK = await API.health() } }
                        .disabled(server.state != .started)
                        .help("Restart the server the app started")
                    Button("Open server log") { NSWorkspace.shared.open(ServerLauncher.logURL) }
                }
            } footer: {
                Text("With a local address, the app starts the server from this folder when none is running, and stops it when the app quits. Press Return to apply a change.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPage()
        .task(id: serverURL) {
            serverOK = nil
            serverOK = await API.health()
        }
    }
}

/// Settings › Account: who is signed in, this Mac's name in the device list, the recovery codes, and Sign Out.
private struct AccountSettings: View {
    @Environment(Account.self) private var account
    @Environment(LibraryStore.self) private var library
    @State private var choosingFiles = false
    @State private var importLink = ""
    @AppStorage("checkUpdates") private var checkUpdates = true      // UpdateCheck.enabled reads the same key
    private var importer: SpotifyImporter { .shared }
    @State private var signingOut = false
    @State private var deviceDraft = Account.deviceName      // saved on Return
    @State private var deviceProblem: String?
    @State private var codesLeft: Int?
    @State private var askingPassword = false
    @State private var newCodes: [String]?

    private var signedIn: Bool { account.state == .signedIn }

    var body: some View {
        Form {
            Section {
                LabeledContent("Username") {
                    Text(account.user?.username ?? "Not signed in").foregroundStyle(.secondary)
                }
                TextField("Device Name", text: $deviceDraft)
                    .onSubmit { Task { deviceProblem = await account.renameDevice(deviceDraft) } }
                    .onChange(of: deviceDraft) { deviceProblem = nil }
                    .disabled(!signedIn)
                if let deviceProblem {
                    Text(deviceProblem).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Unused Codes") {
                    if let codesLeft {
                        Text("\(codesLeft) of 10").foregroundStyle(codesLeft <= 3 ? .orange : .secondary)
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
                Button("New Recovery Codes…") { askingPassword = true }
                    .disabled(!signedIn)
            } header: {
                Text("Recovery Codes")
            }
            Section {
                Button(importer.running ? "Importing…" : "Choose Files…") { choosingFiles = true }
                    .disabled(!signedIn || importer.running)
                TextField("YouTube Playlist", text: $importLink, prompt: Text("music.youtube.com/playlist?list=…"))
                    .onSubmit {
                        guard !importLink.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        importer.start(link: importLink, library: library)
                        importLink = ""
                    }
                    .disabled(!signedIn || importer.running)
                if let status = importer.status {
                    if status.finished {
                        LabeledContent("Last Import") {
                            Text("\(status.added) of \(status.total) added").foregroundStyle(.secondary)
                        }
                        if !status.missing.isEmpty {
                            DisclosureGroup("Not Found (\(status.total - status.added))") {
                                ForEach(status.missing, id: \.self) { Text($0).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        ProgressView(value: Double(status.done), total: Double(max(status.total, 1))) {
                            Text("\(status.done) of \(status.total) songs")
                        }
                    }
                }
                if let problem = importer.problem {
                    Text(problem).foregroundStyle(.red)
                }
            } header: {
                Text("Import from Spotify or YouTube")
            } footer: {
                Text("Spotify: files from exportify.net, or from Spotify's Privacy settings (Download your data). YouTube: a playlist link (press Return), or Google Takeout's playlist files. Only song names and video ids leave this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version") { Text(UpdateCheck.current).foregroundStyle(.secondary) }
                Toggle(isOn: $checkUpdates) {
                    Text("Check for updates")
                    Text("At launch, asks GitHub whether a newer version exists.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            }
            Section {
                Button(signingOut ? "Signing Out…" : "Sign Out") {
                    signingOut = true
                    Task { await account.signOut(); signingOut = false }
                }
                .disabled(!signedIn || signingOut)
            }
        }
        .settingsPage()
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.commaSeparatedText, .json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
                importer.start(urls, library: library)
                opened.forEach { $0.stopAccessingSecurityScopedResource() }
            }
        }
        .task(id: account.user?.id) { codesLeft = try? await API.recoveryCodesLeft() }
        .sheet(isPresented: $askingPassword) {
            NewRecoveryCodesSheet(cancel: { askingPassword = false }) { codes in
                askingPassword = false
                newCodes = codes
                codesLeft = codes.count
            }
        }
        .sheet(isPresented: Binding(get: { newCodes != nil }, set: { if !$0 { newCodes = nil } })) {
            RecoveryCodesSheet(codes: newCodes ?? [], username: account.user?.username ?? "") { newCodes = nil }
        }
    }
}

/// A settings page: as tall as its content, but never taller than the screen; past that, it scrolls.
/// Pages used to take their full height (`fixedSize`): Discord with every section open was 983 pt on an 847 pt
/// screen, and its bottom rows were below the screen's edge (measured 6 Oct).
private struct SettingsPage: ViewModifier {
    /// The usable screen, less the Settings window's title bar and tabs (about 80 pt) and a margin.
    private var maxHeight: CGFloat { max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 120) }

    func body(content: Content) -> some View {
        CappedHeight(maxHeight: maxHeight) { content.formStyle(.grouped) }
    }
}

/// Gives its child the child's natural height, up to `maxHeight`; a taller child gets `maxHeight` and scrolls.
/// The natural height is asked with no height proposed (what `fixedSize` does), so it never depends on the frame
/// it produces. Measuring the Form's scroll content instead looped: the content is at least as tall as the frame,
/// so each pass grew it, until AppKit stopped the app (6 Oct).
private struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    fileprivate func settingsPage() -> some View { modifier(SettingsPage()) }
}

/// Settings › Footprint: what the app and its server use right now, and every choice that costs more, with what it
/// costs (measured) and its switch. The lightest setting is always the default.
private struct FootprintSettings: View {
    @AppStorage("animateBackdrop") private var animateBackdrop = Look.animateBackdrop
    @AppStorage("serverReload") private var reloads = false
    @AppStorage("searchPrefetch") private var searchPrefetch = Prefetcher.searchDefault
    @AppStorage("audioCacheMB") private var cacheMB = AudioCache.defaultLimitMB
    @State private var cacheUsed: Int?

    var body: some View {
        Form {
            Section {
                FootprintReadings()
            } header: {
                Text("Right now")
            } footer: {
                Text("Measured as Activity Monitor measures it, once a second while this page is open. The database is not included.")
                    .foregroundStyle(.secondary)
            }
            // on by default (your choice, 8 Oct): a song played before starts from its file (~0.15 s against ~0.8 s)
            Section {
                Picker(selection: $cacheMB) {
                    Text("Off").tag(0)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                } label: {
                    Text("Keep songs on this Mac")
                    Text("Songs you've played start at once and play offline. The least recently played are removed first.")
                }
                .onChange(of: cacheMB) { Task { await AudioCache.shared.evict(); cacheUsed = await AudioCache.shared.size() } }
                LabeledContent("Used") {
                    HStack {
                        Text(cacheUsed.map { formatBytes($0) } ?? "…").foregroundStyle(.secondary)
                        Button("Clear") { Task { await AudioCache.shared.clear(); cacheUsed = 0 } }
                            .disabled((cacheUsed ?? 0) == 0)
                    }
                }
            } header: {
                Text("Storage")
            }
            .task { cacheUsed = await AudioCache.shared.size() }

            Section {
                DownloadLocation()
            } header: {
                Text("Downloads")
            }

            Section {
                Toggle(isOn: $animateBackdrop) {
                    Text("Moving background")
                    Text("Uses about 5% more CPU while music plays, and 10–14% more in Now Playing.")
                        .foregroundStyle(.secondary)
                }
                Picker(selection: $searchPrefetch) {
                    Text("None").tag(0)
                    Text("The top result").tag(1)
                    Text("The top 5").tag(5)
                } label: {
                    Text("Get search results ready")
                    Text("Songs looked up ahead start sooner. Each lookup goes to YouTube from this Mac.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $reloads) {
                    Text("Reload the server when its code changes")
                    Text("Uses about 140 MB more memory. Takes effect when the server restarts.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Costs more: off unless you turn it on")
            } footer: {
                Text("Measured on an Apple silicon Mac with a song playing. At these defaults the main window and Now Playing each use about 1% of one core.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPage()
    }
}

/// Settings › Footprint › Downloads: the folder songs download to, and a way to choose another. Choosing one moves the
/// songs already downloaded there (DownloadStore.moveTo); the choice is saved only once every file is there, and the
/// app opens it at launch. The same row as the Windows app's Settings › Storage › Download location (15 Oct).
private struct DownloadLocation: View {
    @Environment(DownloadStore.self) private var downloads
    @AppStorage("downloadFolder") private var chosenFolder = ""    // a path; empty: the app's own (DownloadStore reads it)
    /// Why the last move failed, until the next one.
    @State private var failure: String?

    var body: some View {
        let busy = downloads.moving || !downloads.inProgress.isEmpty
        let note = self.note
        LabeledContent {
            HStack {
                Button("Change…") { choose() }
                    .disabled(busy)
                if let folder = downloads.folder {
                    Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                }
                if !chosenFolder.isEmpty {
                    Button("Use Default") { move(to: nil) }
                        .disabled(busy)
                }
            }
        } label: {
            Text("Download location")
            Text(note.text).foregroundStyle(note.warning ? .red : .secondary)
        }
        .selfTestFrame("settings.downloadLocation")
        #if DEBUG
        .onChange(of: note.text, initial: true) { SelfTest.downloadLocationNote = note.text }
        #endif
    }

    /// The folder (~ for your home folder), or what is happening to it.
    private var note: (text: String, warning: Bool) {
        let shown = downloads.folder ?? downloads.missingFolder ?? downloads.defaultFolder
        let path = (shown.path as NSString).abbreviatingWithTildeInPath
        if downloads.moving { return ("Moving your downloads…", false) }
        if let failure { return (failure, true) }
        if !downloads.available { return ("Not found: \(path). Connect its drive, or choose another folder.", true) }
        if !downloads.inProgress.isEmpty { return ("\(path)\nIt can be changed once the downloads in progress finish.", false) }
        return (path, false)
    }

    /// The system's folder picker, at the folder in use; the folder chosen takes every download.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloads.folder
        panel.prompt = "Choose"
        panel.message = "Download songs to"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        move(to: target)
    }

    /// `target` nil: back to the app's own folder, and the choice forgotten.
    private func move(to target: URL?) {
        failure = nil
        Task {
            do {
                try await downloads.moveTo(target ?? downloads.defaultFolder)
                chosenFolder = target?.path ?? ""
            } catch {
                failure = "Couldn't move your downloads there: \(error.localizedDescription)"
            }
        }
    }
}

/// The two live rows, in a view of their own with their own meter: once a second only these redraw. When the meter
/// lived in the page, every reading redrew the whole page, and the page's redrawing was most of what it measured
/// (Footprint said ~1.8% while `top` said 0.9% for the same app, 7 Oct).
private struct FootprintReadings: View {
    @Environment(ServerLauncher.self) private var server
    @State private var meter = FootprintMeter()

    var body: some View {
        Group {
            LabeledContent("This app") { reading(meter.app) }
            LabeledContent("Server") {
                if let s = meter.server { reading(s) }
                else { Text(server.state == .alreadyRunning ? "Started outside the app: not measured" : "Not running").foregroundStyle(.secondary) }
            }
        }
        .task {
            while !Task.isCancelled {
                meter.update(serverPIDs: server.serverPIDs)
                #if DEBUG
                SelfTest.footprint = (meter.app, meter.server)
                #endif
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reading(_ r: FootprintMeter.Reading?) -> some View {
        Group {
            if let r {
                Text(String(format: "%.1f%% CPU · %@", r.cpu, formatBytes(Int(r.memory))) + (r.processes > 1 ? " in \(r.processes) processes" : ""))
                    .monospacedDigit()
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
        }
    }
}

/// A slider with its two ends named: "See-through ⟷ Solid".
private struct RangeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, low: String, high: String) {
        _value = value
        self.range = range
        self.low = low
        self.high = high
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(low).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range)
            Text(high).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A colour as a hex code and a swatch (the system colour picker), kept in step: change either one.
/// A code that does not parse is put back to the current colour when you press Return.
struct HexColorControl: View {
    @Binding var hex: String
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Hex", text: $draft, prompt: Text("#RRGGBB"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: 92)
                .onSubmit { if let color = Color(hex: draft) { hex = color.hexString } else { draft = hex } }
            ColorPicker("Colour", selection: Binding(get: { Color(hex: hex) ?? .accentColor }, set: { hex = $0.hexString }),
                        supportsOpacity: false)
                .labelsHidden()
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { _, new in draft = new }
    }
}
