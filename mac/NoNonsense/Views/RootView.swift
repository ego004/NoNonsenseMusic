import SwiftUI

/// The main window: glass sidebar, the selected screen over the artwork backdrop, the floating player,
/// and Now Playing on top when open.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ServerLauncher.self) private var server
    @Environment(LyricsStore.self) private var lyrics
    @AppStorage("lyricsFetch") private var lyricsFetch = LyricsFetch.songStart     // Settings › Lyrics
    @State private var selection: Destination? = .section(.home)
    @State private var searchRequests = 0                 // ⌘F presses: Search focuses its bar on each
    @AppStorage("artStrength") private var artStrength = Look.artStrength         // how strongly the cover colours the window
    @Environment(\.colorScheme) private var scheme
    @Environment(ThemeStore.self) private var theme
    @AppStorage("textScale") private var textScale = Look.textScale                 // Settings › Appearance › Text size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass                                    // lets the message and the player bar morph into each other

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch selection ?? .section(.home) {
                    case .section(.home): HomeView { selection = $0 }
                    case .section(.search): SearchView(focusRequests: searchRequests)
                    case .section(.liked): SongListView(item: .liked)
                    case .section(.recent): SongListView(item: .recent)
                    case .section(.downloads): SongListView(item: .downloads)
                    case .playlist(let id): PlaylistView(id: id) { selection = .section(.home) }.id(id)
                    }
                }
                .safeAreaPadding(.bottom, player.current == nil ? 0 : 100)  // lists scroll clear of the bar (72 pt + its 18 pt margin)

                // One glass container: shapes closer than `spacing` blend like liquid, so the message
                // grows out of the player bar and sinks back into it.
                GlassEffectContainer(spacing: 24) {
                    VStack(spacing: 10) {
                        if let message = player.errorMessage ?? library.message {
                            // the player's problems always warn; the library's messages bring their own symbol (✓ for "Added to …")
                            Label(message, systemImage: player.errorMessage != nil ? "exclamationmark.triangle.fill" : library.messageSymbol)
                                .textStyle(.callout)
                                .symbolEffect(.bounce, value: message)          // the icon hops when a new message arrives
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                                .glassEffectID("message", in: glass)
                                .glassEffectTransition(.materialize)
                        }
                        PlayerBar(glass: glass)
                            // a song that would not play: one short sideways shake, like a wrong password (not with Reduce Motion)
                            .keyframeAnimator(initialValue: 0.0, trigger: player.problems) { bar, x in
                                bar.offset(x: reduceMotion ? 0 : x)
                            } keyframes: { _ in
                                KeyframeTrack {
                                    SpringKeyframe(-10, duration: 0.07)
                                    SpringKeyframe(8, duration: 0.08)
                                    SpringKeyframe(-5, duration: 0.08)
                                    SpringKeyframe(0, duration: 0.14)
                                }
                            }
                            .sensoryFeedback(.error, trigger: player.problems)
                    }
                }
                // the message's spring on the message and the bar only: on the whole area, it animated the list too
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.errorMessage ?? library.message)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            // a background takes the size of what it is behind and can never enlarge it
            // the desktop, blurred (WindowBlur), under a wash of the playing song's artwork (Backdrop)
            .background {
                // playing a song changes the wash's colour, never how see-through the window is
                WindowSurface { IsolatedBackdrop(track: player.current, strength: artStrength, underNowPlaying: true) }
            }
            // see-through title bar: the backdrop shows under it, and lists fade softly as they scroll beneath it
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // Now Playing covers the window: the toolbar (the sidebar button, the title) went on showing over it, and
            // its buttons answered clicks that did nothing there. The traffic lights stay
            .toolbarVisibility(player.showNowPlaying && player.current != nil ? .hidden : .visible, for: .windowToolbar)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: player.current == nil)
        }
        // Now Playing in its own host, faded in and out by Core Animation: see NowPlayingLayer
        .overlay { NowPlayingLayer(shown: player.showNowPlaying && player.current != nil).ignoresSafeArea() }
        // no internet, or no server: said once, at the top, for as long as it lasts (not a message per failed song).
        // Above Now Playing: under it, as the player bar's message line is, playback could stop with no reason in
        // sight (audit, 7 Oct). So while Now Playing is open, that message shows up here too
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ConnectionBanner()
                if player.showNowPlaying && player.current != nil, let message = player.errorMessage ?? library.message {
                    Label(message, systemImage: player.errorMessage != nil ? "exclamationmark.triangle.fill" : library.messageSymbol)
                        .textStyle(.callout)
                        .symbolEffect(.bounce, value: message)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                }
            }
            .padding(.top, 10)
            .animation(.snappy(duration: 0.3), value: player.showNowPlaying ? player.errorMessage ?? library.message : nil)
        }
        #if DEBUG
        // a self-test window opens on your screen too: this says it is not your app, and not your library (6 Oct)
        .overlay(alignment: .top) {
            if SelfTest.isRunning {
                Label("Self-test · test library", systemImage: "testtube.2")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.orange.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        #endif
        // sliders, the progress line and the heart take the playing cover's most vivid colour
        .tint(theme.color(.buttons))                                    // Settings › Appearance › Colours
        .task(id: [player.current?.image?.absoluteString ?? "", scheme == .dark ? "dark" : "light"]) {
            let next = await ArtworkCache.shared.accent(for: player.current?.image, dark: scheme == .dark)
            guard !Task.isCancelled else { return }                  // the song changed again meanwhile: its own task sets it
            // what "Song" means everywhere. At once: fading it 0.8 s redrew the whole window every frame. Only when it
            // differs: the same colour again (the same album) would still redraw everything tinted by it
            if theme.songColor != next { theme.songColor = next }
        }
        .modifier(PlaylistSheets(selection: $selection))
        // ⌘F from any screen: Search, with the bar focused (an invisible button that only holds the shortcut)
        .background {
            Button("") {
                player.showNowPlaying = false
                selection = .section(.search)
                searchRequests += 1                      // already on Search: SearchView focuses the bar on this
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .environment(\.textScale, textScale)              // every textStyle in the window, Now Playing included
        // a shared playlist's link (PlaylistLink): it opens here; one you may not see says so and closes (PlaylistView)
        .onOpenURL { url in
            if let id = PlaylistLink.playlistID(in: url) {
                player.showNowPlaying = false
                selection = .playlist(id)
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .selfTestOpen)) { note in
            if let id = note.object as? UUID { selection = .playlist(id) }
            if let destination = note.object as? Destination { selection = destination }
        }
        #endif
        .task {
            await server.ensureRunning()     // starts the backend if nothing answers (Services/ServerLauncher.swift)
            await Connectivity.shared.checkServer()
            await library.refresh()
        }
        // Settings › Lyrics › when a song starts: this song's lyrics, and the next one's, so Lyrics opens ready.
        // Each song is asked for once (LyricsStore); the id also changes when Up Next is reordered
        .task(id: [player.current?.id, player.upNext.first?.id, lyricsFetch.rawValue]) {
            guard lyricsFetch == .songStart, let current = player.current else { return }
            lyrics.fetch(current)
            if let next = player.upNext.first { lyrics.fetch(next) }
        }
    }
}

/// Now Playing, drawn by its own NSHostingView over the window and shown and hidden by Core Animation (a fade with a
/// slight zoom, 0.3 s, played by macOS's render server).
///
/// Why: as a SwiftUI overlay with a SwiftUI transition, every frame of opening or closing rebuilt the whole window's
/// drawing (the list under it, the sidebar, the bar): about 250 ms of CPU per open or close, 16% of a core when
/// opened and closed every 2 s (measured 7 Oct). Here the window's own view does not change at all when Now Playing
/// opens. Now Playing is built the first time it opens and then kept, hidden, while closed: building it again on
/// every opening was a 23% spike each time (7 Oct). Everything in it waits for events, so hidden it costs nothing.
private struct NowPlayingLayer: NSViewRepresentable {
    let shown: Bool
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ThemeStore.self) private var theme
    @Environment(LyricsStore.self) private var lyrics
    @Environment(DownloadStore.self) private var downloads
    @Environment(ServerLauncher.self) private var server
    @Environment(Presence.self) private var presence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> NowPlayingContainer { NowPlayingContainer() }

    func updateNSView(_ view: NowPlayingContainer, context: Context) {
        view.show(shown, zoom: !reduceMotion) {
            // everything the window's views can ask for; what changes (colours, text size) is read inside, so
            // this is set once per opening and never replaced while open
            AnyView(NowPlayingRoot()
                .environment(player).environment(library).environment(theme).environment(lyrics)
                .environment(downloads).environment(server).environment(presence))
        }
    }
}

/// What RootView gives every screen, given again inside Now Playing's own host: the tint and the text size.
private struct NowPlayingRoot: View {
    @Environment(ThemeStore.self) private var theme
    @AppStorage("textScale") private var textScale = Look.textScale

    var body: some View {
        NowPlayingView()
            .tint(theme.color(.buttons))
            .environment(\.textScale, textScale)
    }
}

final class NowPlayingContainer: NSView {
    private var host: NSHostingView<AnyView>?
    private(set) var shown = false

    // closed (or closing): clicks go through to the window under it
    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }

    func show(_ shown: Bool, zoom: Bool, content: () -> AnyView) {
        guard shown != self.shown else { return }
        self.shown = shown
        if shown {
            if self.host == nil {
                let made = NSHostingView(rootView: content())             // built once, on the first opening
                made.sizingOptions = []                                 // takes the frame it is given; asks for none
                made.frame = bounds
                made.autoresizingMask = [.width, .height]
                made.wantsLayer = true
                addSubview(made)
                self.host = made
            }
            guard let host else { return }
            host.isHidden = false
            animate(host, in: true, zoom: zoom)
        } else if let host {
            animate(host, in: false, zoom: zoom) { [weak self] in
                guard self?.shown == false else { return }              // opened again while it was closing
                host.isHidden = true                                    // kept: the next opening is only the fade
            }
        }
    }

    /// A fade, and a zoom from 98.5% around the middle (no zoom with Reduce Motion), on the host's layer.
    private func animate(_ host: NSView, in opening: Bool, zoom: Bool, done: (() -> Void)? = nil) {
        guard let layer = host.layer else { done?(); return }
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ s: CGFloat) -> CATransform3D {
            CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-mid.x, -mid.y, 0), CATransform3DMakeScale(s, s, 1)),
                                CATransform3DMakeTranslation(mid.x, mid.y, 0))
        }
        let (from, to): (Float, Float) = opening ? (0, 1) : (1, 0)
        let small = scaled(zoom ? 0.985 : 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done?() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? from    // from where it is, if it was mid-way
        fade.toValue = to
        let end = opening ? CATransform3DIdentity : small
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? (opening ? small : CATransform3DIdentity))
        grow.toValue = NSValue(caTransform3D: end)
        let both = CAAnimationGroup()
        both.animations = [fade, grow]
        both.duration = opening ? 0.3 : 0.22
        both.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
        host.alphaValue = CGFloat(to)                             // AppKit keeps the layer's opacity from this
        layer.transform = end
        layer.add(both, forKey: "showing")
        CATransaction.commit()
    }
}

/// The playlist sheets and questions, wherever they were asked for (sidebar, playlist screen, a song's menu, ⌘N):
/// New Playlist, Rename, Share, "Delete …?" and "Leave …?". Deleting the open playlist goes back to Search; leaving
/// it, to Home.
private struct PlaylistSheets: ViewModifier {
    @Binding var selection: Destination?
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        @Bindable var library = library
        content
            .sheet(item: $library.newPlaylistRequest) { request in
                NamePlaylistSheet(title: request.track.map { "New Playlist with “\($0.title)”" } ?? "New Playlist", action: "Create") {
                    await library.createPlaylist(named: $0, adding: request.track)
                }
            }
            .sheet(item: $library.renameRequest) { playlist in
                NamePlaylistSheet(title: "Rename Playlist", action: "Rename", initial: playlist.name) {
                    await library.renamePlaylist(playlist, to: $0)
                }
            }
            .confirmationDialog("Delete “\(library.deleteRequest?.name ?? "")”?",
                                isPresented: Binding(get: { library.deleteRequest != nil }, set: { if !$0 { library.deleteRequest = nil } }),
                                presenting: library.deleteRequest) { playlist in
                Button("Delete", role: .destructive) {
                    if selection == .playlist(playlist.id) { selection = .section(.search) }
                    Task { await library.deletePlaylist(playlist) }
                }
            } message: { _ in
                Text("Its songs stay in your library.")
            }
            .sheet(item: $library.shareRequest) { playlist in
                SharePlaylistSheet(playlist: playlist) { await library.share(playlist, with: $0, role: $1) }
            }
            .confirmationDialog("Leave “\(library.leaveRequest?.name ?? "")”?",
                                isPresented: Binding(get: { library.leaveRequest != nil }, set: { if !$0 { library.leaveRequest = nil } }),
                                presenting: library.leaveRequest) { playlist in
                Button("Leave", role: .destructive) {
                    if selection == .playlist(playlist.id) { selection = .section(.home) }
                    Task { await library.leave(playlist) }
                }
            }
    }
}

/// "No internet" or "Server not connected", at the top of the window while it lasts; Try Again for the server.
private struct ConnectionBanner: View {
    @Environment(ServerLauncher.self) private var server
    @Environment(LibraryStore.self) private var library
    @State private var retrying = false
    private var connectivity: Connectivity { .shared }

    var body: some View {
        Group {
            if !connectivity.online {
                banner("No internet · downloaded songs still play", symbol: "wifi.slash")
            } else if !connectivity.serverAnswers {
                banner("Server not connected", symbol: "bolt.horizontal.circle") {
                    Button(retrying ? "Trying…" : "Try Again") {
                        retrying = true
                        Task {
                            await server.ensureRunning()
                            if await Connectivity.shared.checkServer() { await library.refresh() }
                            retrying = false
                        }
                    }
                    .disabled(retrying)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: [connectivity.online, connectivity.serverAnswers])
    }

    private func banner(_ text: String, symbol: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Label(text, systemImage: symbol).textStyle(.callout, weight: .medium)
            action()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
