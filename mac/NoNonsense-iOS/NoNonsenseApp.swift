import AVFoundation
import SwiftUI

/// The iPhone app: the Mac app's engine (Models, Services) under a phone's own screens. Sign in, then four tabs (Home,
/// Search, Library, Settings) with the song playing in a bar above them; Now Playing opens from it.
@main
struct NoNonsensePhoneApp: App {
    @State private var library: LibraryStore
    @State private var player: Player
    @State private var downloads: DownloadStore
    @State private var account: Account
    @State private var lyrics: LyricsStore

    init() {
        // music, not a sound effect: plays on with the screen locked and through the silent switch, and stops others
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let library = LibraryStore()
        let downloads = DownloadStore()
        downloads.notify = { [weak library] text, symbol in library?.notify(text, symbol: symbol) }
        let lyrics = LyricsStore(downloads: downloads)
        downloads.downloaded = { [weak lyrics] track in Task { await lyrics?.keep(for: track) } }   // offline lyrics
        _lyrics = State(initialValue: lyrics)
        let player = Player(library: library, presence: Presence(), downloads: downloads)
        #if DEBUG && targetEnvironment(simulator)
        // test builds in the simulator play muted: the simulator's sound comes out of the Mac's speakers
        player.toggleMute()
        #endif
        let account = Account()
        account.onEnded = { [weak player, weak library] in
            player?.stop()
            library?.clear()
            Social.shared.stop()
            JamSession.shared.leaveLocally()
        }
        _library = State(initialValue: library)
        _downloads = State(initialValue: downloads)
        _player = State(initialValue: player)
        _account = State(initialValue: account)
        // loudness compensation follows the iPhone's own volume
        SoundChain.shared.volumeChanged(place: Double(AVAudioSession.sharedInstance().outputVolume))
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            let place = Double(session.outputVolume)
            Task { @MainActor in SoundChain.shared.volumeChanged(place: place) }
        }
    }

    private let volumeObservation: NSKeyValueObservation?

    var body: some Scene {
        WindowGroup {
            Gate()
                .environment(account)
                .environment(player)
                .environment(library)
                .environment(downloads)
                .environment(lyrics)
                .task { await account.start() }
        }
    }
}

/// Signing in, or the app once signed in.
private struct Gate: View {
    @Environment(Account.self) private var account
    @Environment(LibraryStore.self) private var library

    var body: some View {
        switch account.state {
        case .checking: ProgressView()
        case .signedOut: SignInScreen()
        case .signedIn:
            MainTabs()
                .task { if await Connectivity.shared.checkServer() { await library.refresh(); await library.refreshPlaylists() } }
        }
    }
}

private struct MainTabs: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { HomeScreen() }.playerBarBefore26() }
            Tab("Library", systemImage: "books.vertical") { NavigationStack { LibraryScreen() }.playerBarBefore26() }
            Tab(role: .search) { NavigationStack { SearchScreen() }.playerBarBefore26() }
        }
        .tabViewStyle(.sidebarAdaptable)                     // iPad: a sidebar (it folds to tabs); iPhone: the tab bar
        .playerAccessory26(playing: player.current != nil)
        .sheet(isPresented: $player.showNowPlaying) { NowPlayingScreen() }
    }
}

extension View {
    /// iOS 26.1+: the player on the tab bar (its bottom accessory, glass), shown only while a song is loaded (26.1's
    /// `isEnabled`; 26.0's accessory has no off, and showed as an empty pill). iOS 26: the tab bar shrinks as you scroll.
    @ViewBuilder
    func playerAccessory26(playing: Bool) -> some View {
        if #available(iOS 26.1, *) {
            self.tabViewBottomAccessory(isEnabled: playing) { MiniPlayer(docked: true) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 26, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Before iOS 26.1: the player as a glass bar of its own just above the tab bar, over each tab's content.
    @ViewBuilder
    func playerBarBefore26() -> some View {
        if #available(iOS 26.1, *) { self } else { safeAreaInset(edge: .bottom) { MiniPlayer(docked: false) } }
    }
}
