import SwiftUI

@main
struct NoNonsenseApp: App {
    @State private var library: LibraryStore
    @State private var presence: Presence
    @State private var player: Player
    @State private var downloads: DownloadStore
    @State private var server = ServerLauncher.shared
    @State private var theme = ThemeStore()
    @AppStorage("appearance") private var appearance = Appearance.system

    init() {
        #if DEBUG
        if SelfTest.isRunning { SelfTest.returnDefaults() }    // a self-test that died last time: put your settings back first
        #endif
        let library = LibraryStore()
        let presence = Presence()
        let downloads = DownloadStore()
        downloads.notify = { [weak library] text, symbol in library?.notify(text, symbol: symbol) }
        _library = State(initialValue: library)
        _presence = State(initialValue: presence)
        _downloads = State(initialValue: downloads)
        _player = State(initialValue: Player(library: library, presence: presence, downloads: downloads))
    }

    var body: some Scene {
        WindowGroup("NoNonsense") {
            RootView()
                .environment(server)
                .environment(theme)
                .environment(player)
                .environment(library)
                .environment(presence)
                .environment(downloads)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear {
                    player.installKeyMonitor()
                    player.installSwipeMonitor()
                    #if DEBUG
                    SelfTest.runIfAsked()
                    SelfTest.runPlaybackIfAsked(player: player)
                    SelfTest.runPresenceCheckIfAsked(presence: presence)
                    SelfTest.runThemeCheckIfAsked(theme: theme)
                    SelfTest.runLikeCheckIfAsked()
                    SelfTest.runSearchCheckIfAsked(player: player)
                    SelfTest.runQueueCheckIfAsked()
                    SelfTest.runPlaylistCheckIfAsked(library: library, player: player)
                    SelfTest.runHomeCheckIfAsked(library: library, player: player)
                    SelfTest.runNowPlayingCheckIfAsked(library: library, player: player, theme: theme)
                    SelfTest.runSizesCheckIfAsked()
                    SelfTest.runIdleIfAsked(player: player)
                    SelfTest.runPrefetchCheckIfAsked(player: player)
                    SelfTest.runUpNextCheckIfAsked(player: player)
                    SelfTest.runDownloadsCheckIfAsked(player: player, downloads: downloads)
                    SelfTest.runSidebarCheckIfAsked(library: library)
                    SelfTest.runSettingsFitCheckIfAsked()
                    SelfTest.runBarCheckIfAsked(player: player)
                    #endif
                }
        }
        .windowToolbarStyle(.unified)
        // the window can never be smaller than the content's minimum size (it was, and the player bar got cut off)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands { PlaybackCommands(player: player, library: library) }

        Settings {
            SettingsView()
                .environment(presence)
                .environment(server)
                .environment(theme)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// The "Controls" menu in the menu bar, with the keyboard shortcuts.
struct PlaybackCommands: Commands {
    let player: Player
    let library: LibraryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { library.newPlaylistRequest = .init(track: nil) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }   // Space: see Player.installKeyMonitor
            Button("Next") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.isShuffled }, set: { _ in player.toggleShuffle() }))
                .keyboardShortcut("s", modifiers: .command)
            Button("Repeat: \(player.repeatMode.label)") {
                player.cycleRepeat()
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Volume Up") { player.setVolume(player.volume + 0.1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.setVolume(player.volume - 0.1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
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
