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
    /// On: three moving bars on the playing song (Settings › Appearance). Core Animation bars, capped at 30 frames a
    /// second: no measurable cost in the app or WindowServer (7 Oct). Off: a still speaker.
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
                Toggle(isOn: $buttonFeedback) {
                    Text("Button feedback")
                    Text("A soft highlight under the pointer and a small press. Buttons take clicks around their icon either way.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $coverTilt) {
                    Text("Covers tilt toward the pointer")
                    Text("With a light that follows it. Redraws the window on every pointer move over a cover: CPU while you hover.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $animatedSpeaker) {
                    Text("Moving bars on the playing song")
                    Text("macOS animates them, not the app: no measurable cost.").foregroundStyle(.secondary)
                }
                Toggle(isOn: $animateBackdrop) {
                    Text("Moving background")
                    // measured 7 Oct, a debug build on an Apple silicon Mac, a song playing: still vs moving
                    Text("Uses more battery: about 5% more of one CPU core in the main window, 10–14% more in Now Playing.")
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
                    surfaceNote("Behind the lists and Home. The blur is of your desktop; the colour comes from Colours › Background.")
                case .sidebar:
                    LabeledContent("Blur") { RangeSlider(value: $sidebarBlur, low: "Glass", high: "Frosted") }
                    LabeledContent("Transparency") { RangeSlider(value: $sidebarSolid, low: "See-through", high: "Solid") }
                    surfaceNote("macOS draws the sidebar as glass; these add frost and colour over it. Both at the left: the glass alone.")
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
                    surfaceNote("The full-window view (⇧⌘F). With little blur, some colour always stays, so the words stay readable.")
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
                Text("Text in lists, cards, the player and Now Playing. The card is half its real size here.")
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
                Text("A light tick every 10% while you drag the volume, and at each minute while you drag the progress line. Macs play haptics only during a drag.")
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

    var body: some View {
        Form {
            Section {
                Picker("When a song has both", selection: $version) {
                    Text("Play the explicit version").tag("explicit")
                    Text("Play the clean version").tag("clean")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Explicit versions show 🅴. Open a song's versions to see each one and play any of them. Applies to songs listed from now on.")
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
                Text("The first time a song's lyrics are asked for, the server looks them up (about 1–2 seconds); after that it answers from its own store at once. Fetching when a song starts means Lyrics opens with them ready. Downloaded songs keep their lyrics, so they show offline.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPage()
    }
}

private struct DiscordSettings: View {
    @AppStorage("settings.open.share") private var openShare = true
    @AppStorage("settings.open.preview") private var openPreview = true
    @Environment(Presence.self) private var presence
    @State private var idDraft = ""                      // applied on Return: each change means a new Discord handshake
    @State private var messageDraft = ""                 // applied on Return: each change is a command to Discord

    var body: some View {
        @Bindable var presence = presence
        Form {
            Section {
                Toggle("Show what I'm listening to", isOn: Binding(get: { presence.enabled }, set: { presence.setEnabled($0) }))
                TextField("Application ID", text: $idDraft, prompt: Text("e.g. 1291000000000000000"))
                    .onSubmit { presence.setClientID(idDraft) }
                    .onAppear { idDraft = presence.clientID }
                LabeledContent("Status") { Text(presence.status).foregroundStyle(.secondary) }
                Button("Send a test status") {
                    presence.setClientID(idDraft)            // a pasted ID counts even without Return
                    presence.sendTest()
                }
                .disabled(idDraft.isEmpty)
            } footer: {
                Text("Needs the Discord app open. Create an application at discord.com/developers → New Application; its name is what people see after “Listening to”. Paste its Application ID here.")
                    .foregroundStyle(.secondary)
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
                Toggle("The NoNonsense logo", isOn: $presence.shareLogo)
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

            Section {
                EmptyView()
            } footer: {
                Text("The logo needs one upload: discord.com/developers › your application › Rich Presence › Art Assets › add the icon named “nononsense”. It shows as the picture while paused, and as a small badge on the cover while playing.")
                    .foregroundStyle(.secondary)
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
    @State private var serverOK: Bool?
    // drafts, saved on Return: a field bound to the setting saved whatever it showed, even a test window's
    // launch-argument address, when its window closed (that is how 8765 became your saved address, 7 Oct)
    @State private var addressDraft = ""
    @State private var folderDraft = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $addressDraft, prompt: Text(API.defaultServer))
                    .onSubmit { serverURL = addressDraft.trimmingCharacters(in: .whitespaces).isEmpty ? API.defaultServer : addressDraft }
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
                    Text("For writing the backend: the server restarts on every save. Uses about 140 MB more memory and three more processes (uv kept running, a file watcher and its helper; measured 7 Oct: 236 MB in 4 processes, against 97 MB in 1).")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start now") { Task { await server.ensureRunning(); serverOK = await API.health() } }
                        .disabled(serverOK == true)
                    Button("Restart") { Task { await server.restart(); serverOK = await API.health() } }
                        .disabled(server.state != .started)
                        .help("Stops the server the app started and starts it again, in the mode chosen above")
                    Button("Open server log") { NSWorkspace.shared.open(ServerLauncher.logURL) }
                }
            } footer: {
                Text("When nothing answers at a local address, the app starts the backend in this folder (one process, listening on this Mac only) and stops it when the app quits. A server you started yourself in a terminal is left alone. Press Return to apply a new address or folder.")
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

    var body: some View {
        Form {
            Section {
                FootprintReadings()
            } header: {
                Text("Right now")
            } footer: {
                Text("CPU is a share of one core, as Activity Monitor shows it; memory is what Activity Monitor counts. Read once a second while this page is open. Postgres runs on its own and is not counted.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $animateBackdrop) {
                    Text("Moving background")
                    Text("About 5% more of one core in the main window, 10–14% more in Now Playing, while music plays.")
                        .foregroundStyle(.secondary)
                }
                Picker(selection: $searchPrefetch) {
                    Text("None").tag(0)
                    Text("The top result").tag(1)
                    Text("The top 5").tag(5)
                } label: {
                    Text("Get search results ready")
                    Text("Each one is a YouTube lookup on your server (~2 s of its work) and one more request YouTube sees. The ones made ready start at once when clicked; others wait ~2 s.")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $reloads) {
                    Text("Reload the server when its code changes")
                    Text("About 140 MB more memory and three more processes. Applies when the server next starts (Server › Restart).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Costs more: off unless you turn it on")
            } footer: {
                Text("Measured 7 Oct on an Apple silicon Mac (Release build) with a song playing. Everything else is already at its lightest: the main window and Now Playing each use about 1% of one core.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPage()
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
