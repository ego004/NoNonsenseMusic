import SwiftUI

@main
struct NoNonsenseApp: App {
    @State private var library: LibraryStore
    @State private var presence: Presence
    @State private var player: Player
    @AppStorage("appearance") private var appearance = Appearance.system

    init() {
        let library = LibraryStore()
        let presence = Presence()
        _library = State(initialValue: library)
        _presence = State(initialValue: presence)
        _player = State(initialValue: Player(library: library, presence: presence))
    }

    var body: some Scene {
        WindowGroup("NoNonsense") {
            RootView()
                .environment(player)
                .environment(library)
                .environment(presence)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear { player.installKeyMonitor() }
        }
        .windowToolbarStyle(.unified)
        .commands { PlaybackCommands(player: player, library: library) }

        Settings {
            SettingsView()
                .environment(presence)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// The "Controls" menu in the menu bar, with the keyboard shortcuts.
struct PlaybackCommands: Commands {
    let player: Player
    let library: LibraryStore

    var body: some Commands {
        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }   // Space: see Player.installKeyMonitor
            Button("Next") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Like / Unlike") {
                if let track = player.current { Task { await library.toggleLike(track) } }
            }
            .keyboardShortcut("l", modifiers: .command)
            Button(player.showNowPlaying ? "Close Now Playing" : "Now Playing") { player.showNowPlaying.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
