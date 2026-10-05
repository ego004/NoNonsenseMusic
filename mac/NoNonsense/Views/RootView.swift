import SwiftUI

/// The main window: glass sidebar, the selected screen over the artwork backdrop, the floating player,
/// and Now Playing on top when open.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ServerLauncher.self) private var server
    @State private var selection: SidebarItem? = .search
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity   // 0 = see-through, 1 = solid
    @AppStorage("artStrength") private var artStrength = Look.artStrength         // how strongly the cover colours the window
    @Environment(\.colorScheme) private var scheme
    @Environment(ThemeStore.self) private var theme
    @AppStorage("windowBlur") private var windowBlur = Look.windowBlur              // 0 = clear, 1 = frosted
    @Namespace private var glass                                    // lets the message and the player bar morph into each other

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch selection ?? .search {
                    case .search: SearchView()
                    case .liked: SongListView(item: .liked)
                    case .recent: SongListView(item: .recent)
                    }
                }
                .safeAreaPadding(.bottom, player.current == nil ? 0 : 88)   // lists scroll clear of the bar

                // One glass container: shapes closer than `spacing` blend like liquid, so the message
                // grows out of the player bar and sinks back into it.
                GlassEffectContainer(spacing: 24) {
                    VStack(spacing: 10) {
                        if let message = player.errorMessage ?? library.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                                .glassEffectID("message", in: glass)
                                .glassEffectTransition(.materialize)
                        }
                        PlayerBar(glass: glass)
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
        // sliders, the progress line and the heart take the playing cover's most vivid colour
        .tint(theme.color(.buttons))                                    // Settings › Appearance › Colours
        .task(id: [player.current?.image?.absoluteString ?? "", scheme == .dark ? "dark" : "light"]) {
            let next = await ArtworkCache.shared.accent(for: player.current?.image, dark: scheme == .dark)
            withAnimation(.easeInOut(duration: 0.8)) { theme.songColor = next }   // what "Song" means everywhere
        }
        .task {
            await server.ensureRunning()     // starts the backend if nothing answers (Services/ServerLauncher.swift)
            await library.refresh()
        }
    }
}
