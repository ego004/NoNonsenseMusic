import SwiftUI

@main
struct NoNonsenseApp: App {
    @State private var library: LibraryStore
    @State private var presence: Presence
    @State private var player: Player
    @State private var downloads: DownloadStore
    @State private var lyrics: LyricsStore
    @State private var account: Account
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
        let lyrics = LyricsStore(downloads: downloads)
        downloads.downloaded = { [weak lyrics] track in Task { await lyrics?.keep(for: track) } }   // offline lyrics
        _lyrics = State(initialValue: lyrics)
        _library = State(initialValue: library)
        _presence = State(initialValue: presence)
        _downloads = State(initialValue: downloads)
        let player = Player(library: library, presence: presence, downloads: downloads)
        _player = State(initialValue: player)
        #if DEBUG
        let account = Account(persistent: !SelfTest.isRunning)        // a self-test never reads or replaces your token
        #else
        let account = Account()
        #endif
        // the session ended: nothing of that account plays on or stays on screen (Account.onEnded)
        account.onEnded = { [weak player, weak library] in
            player?.stop()
            library?.clear()
        }
        _account = State(initialValue: account)
    }

    var body: some Scene {
        WindowGroup("NoNonsenseMusic") {
            AccountGate {
                RootView()
                    #if DEBUG
                    // once signed in: every self-test talks to the server, which now needs an account (AUTH-1)
                    .onAppear { runSelfTests() }
                    #endif
            }
                .environment(account)
                .environment(server)
                .environment(theme)
                .environment(player)
                .environment(library)
                .environment(presence)
                .environment(downloads)
                .environment(lyrics)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear {
                    player.installKeyMonitor()
                    player.installSwipeMonitor()
                }
        }
        .windowToolbarStyle(.unified)
        // no "restore windows" snapshots: AppKit compressed (zlib) and encrypted an image of the window to disk,
        // again and again while playing (7 of 10 s in a profile, 7 Oct). The window's size and place are still kept
        // (frame autosave, in ClearWindow). Setting isRestorable on the NSWindow did not stick: SwiftUI owns it
        .restorationBehavior(.disabled)
        // the window can never be smaller than the content's minimum size (it was, and the player bar got cut off)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands { PlaybackCommands(player: player, library: library, account: account) }

        Settings {
            SettingsView()
                .environment(account)                       // Account › Sign Out
                .environment(presence)
                .environment(server)
                .environment(theme)
                .environment(library)                       // Server: a new address reloads the library
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

#if DEBUG
extension NoNonsenseApp {
    /// The self-test asked for at launch (NN_SELFTEST…), if any.
    private func runSelfTests() {
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
        SelfTest.runLyricsCheckIfAsked(player: player, lyrics: lyrics, downloads: downloads)
        SelfTest.runPerfIfAsked(player: player)
        SelfTest.runFootprintCheckIfAsked()
        SelfTest.runConnectionCheckIfAsked(player: player)
        SelfTest.runCoversCheckIfAsked()
        SelfTest.runExplicitCheckIfAsked()
        SelfTest.runHandsCheckIfAsked(player: player, library: library)
        SelfTest.runScrollCheckIfAsked(player: player, library: library)
        SelfTest.runLikeRaceCheckIfAsked(library: library)
        SelfTest.runSlowPlayCheckIfAsked(player: player)
        SelfTest.runAuthCheckIfAsked(account: account, library: library, player: player)
        SelfTest.runFullScreenCheckIfAsked()
        SelfTest.runYouTubeCheckIfAsked(player: player)
        SelfTest.runLatencyCheckIfAsked(player: player)
    }
}
#endif

/// The "Controls" menu in the menu bar, with the keyboard shortcuts.
struct PlaybackCommands: Commands {
    let player: Player
    let library: LibraryStore
    let account: Account

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { library.newPlaylistRequest = .init(track: nil) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(account.state != .signedIn)          // on the sign-in screen the sheet would wait, then pop up
        }
        CommandMenu("Controls") {
            // greyed out with nothing playing: they did nothing and said nothing (audit, 7 Oct)
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }   // Space: see Player.installKeyMonitor
                .disabled(player.current == nil)
            // ⌘← and ⌘→ while typing move the cursor instead: Player.installKeyMonitor hands them to the text field
            Button("Next") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.current == nil)
            Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.current == nil)
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
            .disabled(player.current == nil)
            // with nothing playing it set Now Playing on with nothing to show: the menu said "Close Now Playing", and
            // the next song opened it over the window (audit, 7 Oct)
            Button(player.showNowPlaying ? "Close Now Playing" : "Now Playing") { player.showNowPlaying.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(player.current == nil && !player.showNowPlaying)
        }
    }
}
