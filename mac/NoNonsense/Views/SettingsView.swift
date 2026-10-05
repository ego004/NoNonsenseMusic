import SwiftUI

/// The look's defaults, in one place: the window and Settings must agree on them.
enum Look {
    static let windowOpacity = 0.5      // half see-through
    static let artStrength = 0.7        // how strongly the cover colours the window
}

/// Colours: taken from the playing song's cover, or the three you choose (Settings › Appearance).
enum Theme {
    static let modeKey = "colorMode"                 // "song" or "custom"
    static let accentKey = "customAccent"            // sliders, the progress line, the playing song, buttons
    static let heartKey = "customHeart"              // the liked heart
    static let backgroundKey = "customBackground"    // the window's wash
    static let defaultAccent = "#0A84FF"             // the system blue
    static let defaultHeart = "#FF375F"              // the system pink
    static let defaultBackground = "#5E5CE6"         // the system indigo
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
            DiscordSettings().tabItem { Label("Discord", systemImage: "person.wave.2") }
            ServerSettings().tabItem { Label("Server", systemImage: "server.rack") }
        }
        .frame(width: 540)
    }
}

private struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity
    @AppStorage("artStrength") private var artStrength = Look.artStrength
    @AppStorage("animateBackdrop") private var animateBackdrop = true
    @AppStorage(Theme.modeKey) private var colorMode = "song"
    @AppStorage(Theme.accentKey) private var customAccent = Theme.defaultAccent
    @AppStorage(Theme.heartKey) private var customHeart = Theme.defaultHeart
    @AppStorage(Theme.backgroundKey) private var customBackground = Theme.defaultBackground

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Transparency") { RangeSlider(value: $windowOpacity, low: "See-through", high: "Solid") }
                LabeledContent("Colour strength") { RangeSlider(value: $artStrength, low: "None", high: "Vivid") }
                Toggle("Moving background", isOn: $animateBackdrop)
            } footer: {
                Text("Reduce Motion and Reduce Transparency in System Settings › Accessibility override these.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Colours", selection: $colorMode) {
                    Text("From the song").tag("song")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented)
                if colorMode == "custom" {
                    HexColorField(title: "Accent", hex: $customAccent)
                    HexColorField(title: "Heart", hex: $customHeart)
                    HexColorField(title: "Background", hex: $customBackground)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(colorMode == "song"
                         ? "The volume, the progress line, the playing song, the heart and the background take the cover's colours."
                         : "Type a hex code (#RRGGBB) or click a swatch to pick.")
                    Spacer()
                    Button("Reset all") {
                        windowOpacity = Look.windowOpacity
                        artStrength = Look.artStrength
                        animateBackdrop = true
                        colorMode = "song"
                        customAccent = Theme.defaultAccent
                        customHeart = Theme.defaultHeart
                        customBackground = Theme.defaultBackground
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DiscordSettings: View {
    @Environment(Presence.self) private var presence

    var body: some View {
        @Bindable var presence = presence
        Form {
            Section {
                Toggle("Show what I'm listening to", isOn: Binding(get: { presence.enabled }, set: { presence.setEnabled($0) }))
                TextField("Application ID", text: Binding(get: { presence.clientID }, set: { presence.setClientID($0) }),
                          prompt: Text("e.g. 1291000000000000000"))
                LabeledContent("Status") { Text(presence.status).foregroundStyle(.secondary) }
                Button("Send a test status") { presence.sendTest() }
                    .disabled(presence.clientID.isEmpty)
            } footer: {
                Text("Needs the Discord app open. Create an application at discord.com/developers → New Application; its name is what people see after “Listening to”. Paste its Application ID here.")
                    .foregroundStyle(.secondary)
            }

            Section("Share") {
                Picker("Your status line shows", selection: $presence.statusLine) {
                    Text("The song").tag(2)
                    Text("The artist").tag(1)
                    Text("The app's name").tag(0)
                }
                Toggle("The song", isOn: $presence.shareSong)
                Toggle("The artist", isOn: $presence.shareArtist)
                Toggle("The cover", isOn: $presence.shareArt)
                Toggle("The time bar", isOn: $presence.shareTime)
                Toggle("Keep it while paused", isOn: $presence.showWhenPaused)
            }

            Section("What friends see") {
                DiscordPreview()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
                    if presence.shareArtist { Text("by \(artist)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
    @Environment(ServerLauncher.self) private var server
    @State private var serverOK: Bool?

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $serverURL)
                LabeledContent("Status") {
                    switch serverOK {
                    case .none: Text("Checking…").foregroundStyle(.secondary)
                    case .some(true): Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                TextField("Backend folder", text: $backendFolder)
                LabeledContent("Auto-start") { Text(server.summary).foregroundStyle(.secondary) }
                HStack {
                    Button("Start now") { Task { await server.ensureRunning(); serverOK = await API.health() } }
                        .disabled(serverOK == true)
                    Button("Open server log") { NSWorkspace.shared.open(ServerLauncher.logURL) }
                }
            } footer: {
                Text("When nothing answers at a local address, the app starts the backend in this folder (uv run fastapi dev) and stops it when the app quits. A server you started yourself in a terminal is left alone.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: serverURL) {
            serverOK = nil
            serverOK = await API.health()
        }
    }
}

/// A slider with its two ends named: "See-through ⟷ Solid".
private struct RangeSlider: View {
    @Binding var value: Double
    let low: String
    let high: String

    var body: some View {
        HStack(spacing: 8) {
            Text(low).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: 0...1)
            Text(high).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A colour as a swatch (the system colour picker) and as a hex code, kept in step: change either one.
/// A hex code that does not parse is put back to the current colour when you press Return.
struct HexColorField: View {
    let title: String
    @Binding var hex: String
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                TextField(title, text: $draft, prompt: Text("#RRGGBB"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(width: 96)
                    .onSubmit { if let color = Color(hex: draft) { hex = color.hexString } else { draft = hex } }
                ColorPicker(title, selection: Binding(get: { Color(hex: hex) ?? .accentColor }, set: { hex = $0.hexString }),
                            supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { _, new in draft = new }
    }
}

