import SwiftUI

/// The main window: glass sidebar, the selected screen over the artwork backdrop, the floating player,
/// and Now Playing on top when open.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ServerLauncher.self) private var server
    @State private var selection: Destination? = .section(.home)
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity   // 0 = see-through, 1 = solid
    @AppStorage("artStrength") private var artStrength = Look.artStrength         // how strongly the cover colours the window
    @Environment(\.colorScheme) private var scheme
    @Environment(ThemeStore.self) private var theme
    @AppStorage("windowBlur") private var windowBlur = Look.windowBlur              // 0 = clear, 1 = frosted
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
                    case .section(.search): SearchView()
                    case .section(.liked): SongListView(item: .liked)
                    case .section(.recent): SongListView(item: .recent)
                    case .playlist(let id): PlaylistView(id: id).id(id)
                    }
                }
                .safeAreaPadding(.bottom, player.current == nil ? 0 : 88)   // lists scroll clear of the bar

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
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.errorMessage ?? library.message)
            // a background takes the size of what it is behind and can never enlarge it
            // the desktop, blurred (WindowBlur), under a wash of the playing song's artwork (Backdrop)
            .background {
                ZStack {
                    ClearWindow()                                   // the window itself see-through, so the blur can be thinned
                    WindowBlur(amount: windowBlur)
                    // Everything over the blur is ONE layer with ONE opacity: playing a song changes the colour,
                    // never how see-through the window is (stacked layers made it nearly opaque before, 5 Oct).
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        Backdrop(track: player.current, strength: artStrength)
                    }
                    .opacity(max(windowOpacity, Look.minWindowOpacity))   // a value saved before the floor existed may be lower
                }
                .ignoresSafeArea()
            }
            // see-through title bar: the backdrop shows under it, and lists fade softly as they scroll beneath it
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: player.current == nil)
        }
        .overlay {
            if player.showNowPlaying && player.current != nil {
                NowPlayingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: player.showNowPlaying)
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
            withAnimation(.easeInOut(duration: 0.8)) { theme.songColor = next }   // what "Song" means everywhere
        }
        .modifier(PlaylistSheets(selection: $selection))
        .environment(\.textScale, textScale)              // every textStyle in the window, Now Playing included
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .selfTestOpen)) { note in
            if let id = note.object as? UUID { selection = .playlist(id) }
            if let destination = note.object as? Destination { selection = destination }
        }
        #endif
        .task {
            await server.ensureRunning()     // starts the backend if nothing answers (Services/ServerLauncher.swift)
            await library.refresh()
        }
    }
}

/// The playlist sheets and questions, wherever they were asked for (sidebar, playlist screen, a song's menu, ⌘N):
/// New Playlist, Rename, and "Delete …?". Deleting the open playlist goes back to Search.
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
    }
}
