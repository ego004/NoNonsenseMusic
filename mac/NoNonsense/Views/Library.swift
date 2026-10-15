import SwiftUI

/// Library (15 Oct, as in the Windows app): everything you have in one place, reached from the sidebar, Home's "Your
/// Library" and the command bar. Liked Songs, Recently Played and Downloads as coloured cards, then your playlists,
/// the albums pinned to Home and the playlists shared with you, as Home's cards. A click on a card opens it.
struct LibraryView: View {
    let open: (Destination) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)       // Settings › Appearance › Sizes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Library").tracking(-1).textStyle(size: 40, weight: .bold).selfTestFrame("library.title")
                section("Collections") {
                    ForEach(SidebarItem.collections(downloads)) { item in
                        CollectionCard(item: item, count: item.songCount(library: library, downloads: downloads), side: cardSize) {
                            open(.section(item))
                        }
                    }
                }
                let mine = library.ownPlaylists.filter { !$0.isAlbum }
                if !mine.isEmpty { section("Playlists") { cards(mine) } }
                if !library.pinnedAlbums.isEmpty { section("Pinned Albums") { cards(library.pinnedAlbums) } }
                if !library.sharedPlaylists.isEmpty { section("Shared with You") { cards(library.sharedPlaylists) } }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageColumn()
            .background(ScrollElasticity(vertical: .none, horizontal: .none))   // a page, not a web page (as Home)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollTitle("Library")
        .task { await library.refreshIfStale() }
    }

    /// A heading over cards that wrap onto new lines, as on Home.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tracking(-0.3).textStyle(size: 22, weight: .bold)
            FlowLayout(spacing: 22, lineSpacing: 22) { content() }
        }
    }

    private func cards(_ playlists: [PlaylistSummary]) -> some View {
        ForEach(playlists) { playlist in
            PlaylistCard(playlist: playlist, side: cardSize) { open(.playlist(playlist.id)) }
                .selfTestFrame("library.card:\(playlist.name)")
        }
    }
}

/// Liked Songs, Recently Played or Downloads as a card: its coloured tile, its name and how many songs. A click opens it.
private struct CollectionCard: View {
    let item: SidebarItem
    let count: Int
    let side: CGFloat
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TiltCard(side: side, radius: side * 0.18, play: nil) { CollectionTile(item: item, size: side) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).textStyle(.callout, weight: .medium).lineLimit(1)
                Text(SongListView.count(count)).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(item.title)")
        .selfTestFrame("library.collection:\(item.title)")
    }
}

/// Liked Songs, Recently Played or Downloads as a square picture (15 Oct, as in the Windows app): a gradient in the
/// collection's own colours, top left to bottom right, with its symbol in white. The sidebar's rows, Library's cards
/// and Home's tiles.
struct CollectionTile: View {
    let item: SidebarItem
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var colours: [Color] {
        switch item {
        case .liked: Self.liked
        case .recent: Self.recent
        default: Self.downloads
        }
    }

    private var symbol: String {
        switch item {
        case .liked: "heart.fill"
        case .recent: "clock.arrow.circlepath"
        default: "arrow.down.circle.fill"
        }
    }

    private static let liked = [Color(red: 242 / 255, green: 107 / 255, blue: 155 / 255),       // #F26B9B
                                Color(red: 155 / 255, green: 77 / 255, blue: 224 / 255)]        // #9B4DE0
    private static let recent = [Color(red: 91 / 255, green: 141 / 255, blue: 239 / 255),       // #5B8DEF
                                 Color(red: 53 / 255, green: 87 / 255, blue: 183 / 255)]        // #3557B7
    private static let downloads = [Color(red: 138 / 255, green: 143 / 255, blue: 152 / 255),   // #8A8F98
                                    Color(red: 75 / 255, green: 80 / 255, blue: 88 / 255)]      // #4B5058
}

extension SidebarItem {
    /// The collections, in order: Liked Songs, Recently Played, and Downloads while there is a place to keep them.
    static func collections(_ downloads: DownloadStore) -> [SidebarItem] {
        downloads.available ? [.liked, .recent, .downloads] : [.liked, .recent]
    }

    /// How many songs a collection holds (none for the places).
    func songCount(library: LibraryStore, downloads: DownloadStore) -> Int {
        switch self {
        case .liked: library.liked.count
        case .recent: library.recent.count
        case .downloads: downloads.items.count
        case .home, .library, .search, .friends: 0
        }
    }
}
