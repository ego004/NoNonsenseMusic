import SwiftUI

/// The main window: glass sidebar, the selected screen over the artwork backdrop, the floating player,
/// and Now Playing on top when open.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ServerLauncher.self) private var server
    @State private var selection: SidebarItem? = .search

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

                PlayerBar()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // a background takes the size of what it is behind and can never enlarge it
            .background { Backdrop(track: player.current) }
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
        .task {
            await server.ensureRunning()     // starts the backend if nothing answers (Services/ServerLauncher.swift)
            await library.refresh()
        }
    }
}
