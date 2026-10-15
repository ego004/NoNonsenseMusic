import SwiftUI

/// The first screen: your music at a glance, laid out as in the Windows app (15 Oct). A one-line greeting over the song
/// playing and what comes next (NowHero); then recently played as a shelf of covers, your library (Liked Songs,
/// Downloads and every playlist) as a grid of small tiles, and liked songs as compact rows three high that scroll
/// sideways. Each section has See All. A new library shows one friendly step as well. Sections fade up one after
/// another (not with Reduce Motion).
struct HomeView: View {
    let open: (Destination) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(Account.self) private var account
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isEmpty: Bool { library.recent.isEmpty && library.liked.isEmpty && library.playlists.isEmpty }

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home")
        #endif
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // one quiet line, then the song playing: the song is the page's headline, not the greeting
                VStack(alignment: .leading, spacing: 18) {
                    Text(Self.greeting(hour: Calendar.current.component(.hour, from: .now), name: account.user?.username))
                        .tracking(-0.3)
                        .textStyle(size: 22, weight: .semibold)
                        .foregroundStyle(.primary.opacity(0.85))
                    NowHero()
                        .selfTestFrame("home.hero")
                }
                .padding(.bottom, 28)
                .appear(appeared, order: 0, reduceMotion: reduceMotion)
                if isEmpty {
                    Group {
                        // an empty library and an unreachable one look the same from here: say which
                        if Connectivity.shared.serverAnswers { firstStep }
                        else {
                            ContentUnavailableView("Can't reach your server", systemImage: "bolt.horizontal.circle",
                                                   description: Text("Your library lives on it. Downloads still play."))
                        }
                    }
                    .padding(.bottom, 32)
                    .appear(appeared, order: 1, reduceMotion: reduceMotion)
                }
                if !library.recent.isEmpty {
                    section("Jump Back In", seeAll: .section(.recent)) {
                        RecentShelf(tracks: Array(library.recent.prefix(20)), side: cardSize) { player.play(library.recent, startAt: $0) }
                    }
                    .padding(.bottom, 32)
                    .appear(appeared, order: 1, reduceMotion: reduceMotion)
                }
                // always there, with Liked Songs at least (even with no songs yet), as in the Windows app
                section("Your Library", seeAll: .section(.library), gap: 10) { LibraryGrid(open: open) }
                    .padding(.bottom, 32)
                    .appear(appeared, order: 2, reduceMotion: reduceMotion)
                if !library.liked.isEmpty {
                    section("Liked Songs", seeAll: .section(.liked)) { likedRows }
                        .appear(appeared, order: 3, reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)                               // the toolbar is above: the greeting sits just under it
            .padding(.bottom, 32)
            // at most maxPageWidth, centred: in a wide window the lines and shelves do not stretch across it (15 Oct)
            .pageColumn()
            // the page is a page, not a web page: it never stretches past its top or bottom. A swipe on a shelf moved
            // it (7 Oct); `.basedOnSize` below stopped that only while the page fitted the window
            .background(ScrollElasticity(vertical: .none, horizontal: .none))
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollTitle("Home")
        .task { await library.refreshIfStale() }
        .onAppear { appeared = true }
    }

    // MARK: sections

    /// A section's title, and See All with a chevron at its right (15 Oct, as in the Windows app).
    private func section<Content: View>(_ title: String, seeAll: Destination, gap: CGFloat = 8,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).tracking(-0.3).textStyle(size: 22, weight: .bold)
                Spacer()
                Button { open(seeAll) } label: {
                    HStack(spacing: 4) {
                        Text("See All")
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                }
                .buttonStyle(.quiet)
                .textStyle(size: 14, weight: .medium)
                .foregroundStyle(.primary.opacity(0.7))
            }
            content()
        }
    }

    private var likedRows: some View {
        let tracks = Array(library.liked.prefix(24))
        let rows = max(1, min(3, tracks.count))
        return ScrollView(.horizontal) {
            // three rows, filled down each column. Made once, not lazily (see RecentShelf); scrolls freely
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(Array(stride(from: row, to: tracks.count, by: rows)), id: \.self) { i in
                            CompactSongTile(track: tracks[i], width: 300) { player.play(library.liked, startAt: i) }
                                .frame(height: 60)
                        }
                    }
                }
            }
            .background(ScrollElasticity(vertical: .none))   // a shelf moves sideways only
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.leading)
        .shelf(margin: 32)
        .clipShape(SidewaysClip())                           // cut off at the page margins, as Jump Back In is
        .selfTestFrame("home.likedShelf")
    }

    private var firstStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your music lives here").textStyle(.title2, weight: .semibold)
            Text("Search for a song you love, then play it, like it, or add it to a playlist.")
                .foregroundStyle(.secondary)
            Button { open(.section(.search)) } label: { Label("Search", systemImage: "magnifyingglass") }
                .compatGlassButton(prominent: true)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// "Good evening, Sam" (15 Oct, as in the Windows app): night before 5, morning before 12, afternoon before 17,
    /// then evening; the username with its first letter a capital. No username: the greeting alone.
    static func greeting(hour: Int, name: String?) -> String {
        let part = hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        guard let name, let first = name.first else { return part }
        return "\(part), \(first.uppercased())\(name.dropFirst())"
    }
}

private extension View {
    /// Fades and lifts into place, one section after another: `order` sets the delay.
    func appear(_ on: Bool, order: Int, reduceMotion: Bool) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 16)
            .animation(.smooth(duration: 0.55).delay(Double(order) * 0.07), value: on)
    }
}

// MARK: - Jump Back In

/// Jump Back In: the songs played last, as covers in a row that scrolls sideways. Made once, not lazily: a lazy stack
/// threw away the covers scrolled past and made them again on the way back (that stuttered); it scrolls freely:
/// stopping on a cover felt like snapping (7 Oct). As in the Windows app (15 Oct) it is cut off at the page margins,
/// and a round More arrow over its right end, there while more lies that way, moves it on by 80% of its width. The
/// arrow's state is the shelf's own: it changes as you scroll, and redraws the shelf only.
private struct RecentShelf: View {
    let tracks: [Track]
    let side: CGFloat
    let play: (Int) -> Void
    @State private var position = ScrollPosition(edge: .leading)
    @State private var place = ShelfPlace()
    @State private var more = false

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home.shelf", more ? "more" : "end")
        #endif
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    CoverTile(track: track, side: side) { play(i) }
                        .selfTestFrame("home.cover:\(i)")
                }
            }
            .padding(.vertical, 12)                         // room for the hover lift and its shadow
            .background(ScrollElasticity(vertical: .none))   // a shelf moves sideways only
        }
        .scrollIndicators(.never)                           // .hidden still showed them with a mouse
        .defaultScrollAnchor(.leading)
        .scrollPosition($position)
        // each scroll step: where the shelf is, kept for the arrow without a redraw; the arrow only when it flips
        .onScrollGeometryChange(for: ShelfReading.self) { geometry in
            ShelfReading(offset: geometry.contentOffset.x, width: geometry.containerSize.width,
                         end: geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width)
        } action: { _, reading in
            place.reading = reading
            if more != reading.more { more = reading.more }
        }
        .shelf(margin: 32)
        // .shelf stops at the page column's edges: this cuts the covers off at the margins, as the rest of the page is
        .clipShape(SidewaysClip())
        .overlay(alignment: .trailing) {
            Button { moveOn() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .compatGlass(in: .circle, interactive: true)
            }
            .buttonStyle(.quiet(highlight: false))
            .help("More")
            .accessibilityLabel("More")
            .padding(.trailing, -20)                         // half over the margin, as in the Windows app
            .opacity(more ? 1 : 0)
            .allowsHitTesting(more)
            .animation(.easeOut(duration: 0.18), value: more)
        }
        .selfTestFrame("home.recentShelf")
        #if DEBUG
        .onAppear { SelfTest.homeShelfMore = { moveOn() } }   // the click, when a click cannot reach
        #endif
    }

    /// On by 80% of the shelf's width, or to its end: one animation (420 ms, ease-out cubic, as in the Windows app).
    private func moveOn() {
        let now = place.reading
        withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.42)) {
            position.scrollTo(x: min(now.offset + now.width * 0.8, now.end))
        }
    }
}

/// Where a shelf has scrolled to, as its scroll view reports it (content offsets, its content margin included).
private nonisolated struct ShelfReading: Equatable {
    var offset: CGFloat = 0
    var width: CGFloat = 0                                  // what shows
    var end: CGFloat = 0                                    // the offset at the far end

    /// More lies to the right (with 4 pt to spare, as in the Windows app).
    var more: Bool { offset < end - 4 }
}

/// A shelf's last reading, kept for its More arrow: a class held in State, so storing a reading on every scroll step
/// redraws nothing.
private final class ShelfPlace {
    var reading = ShelfReading()
}

// MARK: - Your Library

/// Your Library (15 Oct, as in the Windows app): Liked Songs, Downloads and every playlist (yours, the albums you
/// pinned, those shared with you) as one grid of small tiles, each its picture, its name and how many songs; a click
/// opens it. Recently Played is above already, as Jump Back In.
private struct LibraryGrid: View {
    let open: (Destination) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home.library")
        #endif
        TileGrid {
            LibraryTile(name: SidebarItem.liked.title, detail: SongListView.count(library.liked.count)) {
                open(.section(.liked))
            } picture: {
                CollectionTile(item: .liked, size: 52)
            }
            if downloads.available {
                LibraryTile(name: SidebarItem.downloads.title, detail: SongListView.count(downloads.items.count)) {
                    open(.section(.downloads))
                } picture: {
                    CollectionTile(item: .downloads, size: 52)
                }
            }
            ForEach(library.ownPlaylists.filter { !$0.isAlbum } + library.pinnedAlbums + library.sharedPlaylists) { playlist in
                PlaylistTile(playlist: playlist) { open(.playlist(playlist.id)) }
            }
        }
        .selfTestFrame("home.library")
    }
}

/// Tiles in columns of one width, 12 apart both ways: floor(width / 300) columns, 2 to 5 (as in the Windows app).
struct TileGrid: Layout {
    static let gap: CGFloat = 12

    static func columns(for width: CGFloat) -> Int { min(5, max(2, Int(width / 300))) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600                   // asked for an ideal size: two columns' worth
        return CGSize(width: width, height: frames(width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Row by row; a row as tall as its tallest tile.
    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let columns = Self.columns(for: width)
        let tile = (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        var frames: [CGRect] = [], top: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            let height = row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            for column in 0..<row.count {
                frames.append(CGRect(x: CGFloat(column) * (tile + Self.gap), y: top, width: tile, height: height))
            }
            top += height + Self.gap
        }
        return frames
    }
}

/// One tile: its picture, name and detail on a panel. The pointer over it shades it, at once and in this view only:
/// a playlist tile's menu, outside it, is not built again on every hover.
private struct LibraryTile<Picture: View>: View {
    let name: String
    let detail: String
    let open: () -> Void
    @ViewBuilder let picture: () -> Picture
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            picture()
            VStack(alignment: .leading, spacing: 2) {
                Text(name).textStyle(size: 14.5, weight: .semibold).lineLimit(1)
                Text(detail).textStyle(size: 12.5).foregroundStyle(.primary.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .homePanel(radius: 14, highlighted: hovering)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(name)")
        .selfTestFrame("home.tile:\(name)")
    }
}

/// A playlist's tile: its 2×2 cover is made from its songs, loaded as the playlist cards load theirs.
private struct PlaylistTile: View {
    let playlist: PlaylistSummary
    let open: () -> Void
    @Environment(LibraryStore.self) private var library

    var body: some View {
        LibraryTile(name: playlist.name, detail: SongListView.count(playlist.songCount), open: open) {
            PlaylistCover(images: PlaylistCard.covers(library.details[playlist.id]), size: 52, seed: playlist.name)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .modifier(PlaylistLoadsAndMenu(playlist: playlist, open: open))
    }
}

// MARK: - Cards and rows

/// A playlist as a card: its cover (loaded on first sight), name and length. Click opens it; the glass ▶ plays it.
struct PlaylistCard: View {
    let playlist: PlaylistSummary
    let side: CGFloat
    let open: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let detail = library.details[playlist.id]
        VStack(alignment: .leading, spacing: 9) {
            TiltCard(side: side, play: Self.play(detail, on: player)) {
                PlaylistCover(images: Self.covers(detail), size: side, seed: playlist.name)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).textStyle(.callout, weight: .medium).lineLimit(1)
                Text(PlaylistView.stats(count: playlist.songCount, seconds: playlist.duration))
                    .textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .modifier(PlaylistLoadsAndMenu(playlist: playlist, open: open))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(playlist.name)")
        #if DEBUG
        .onAppear { SelfTest.appeared["playlist card", default: 0] += 1 }
        #endif
    }

    /// The covers of a playlist's first four songs, for its 2×2 picture (none until its songs are loaded).
    static func covers(_ detail: PlaylistDetail?) -> [URL] {
        PlaylistCover.images(of: (detail?.items ?? []).lazy.map {
            Track.coverURL(image: $0.song.image, listings: [$0.song.best] + $0.song.listings)
        })
    }

    /// Plays a playlist in its order; nil until its songs are loaded, or when it has none.
    static func play(_ detail: PlaylistDetail?, on player: Player) -> (() -> Void)? {
        detail.flatMap { d in d.items.isEmpty ? nil : { player.playInOrder(d.tracks, keys: d.keys, source: d.queueSource) } }
    }
}

/// What a playlist's card and its tile share: its songs load when it first shows, and again when the count changes
/// (its cover is made from them); a right-click offers Open, Play and what your role allows.
private struct PlaylistLoadsAndMenu: ViewModifier {
    let playlist: PlaylistSummary
    let open: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content
            .task(id: playlist.songCount) {
                if library.details[playlist.id]?.items.count != playlist.songCount { await library.loadPlaylist(playlist.id) }
            }
            .contextMenu {
                Button("Open", action: open)
                if let play = PlaylistCard.play(library.details[playlist.id], on: player) { Button("Play", action: play) }
                Divider()
                PlaylistRoleActions(playlist: playlist)
            }
    }
}

/// A song as a compact row (cover, title, artists) for the sideways grids on Home. Click plays it; right-click
/// has the same menu as a full row.
struct CompactSongTile: View {
    let track: Track
    let width: CGFloat
    let play: () -> Void
    @Environment(Player.self) private var player

    var body: some View {
        CompactSongFace(track: track, width: width)
            .contentShape(.rect)
            .onTapGesture(perform: play)
            .contextMenu {
                Button("Play", action: play)
                Button("Play Next") { player.playNext(track) }
                Button("Add to Queue") { player.addToQueue(track) }
                Divider()
                SongLibraryActions(track: track)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Play \(track.title)")
            #if DEBUG
            .onAppear { SelfTest.appeared["compact song row", default: 0] += 1 }
            #endif
    }
}

/// What a compact tile shows, and the hover, in a view of their own: a hover redraws only this, not the tile and its
/// menu (built again on every redraw). The overlay is always there and only fades in and out: added and removed on
/// each hover, it laid the tile out again, and tiles passing under the pointer while a shelf scrolled did that
/// over and over (8% of a core while hovering, 7 Oct). Sizes as in the Windows app (15 Oct).
private struct CompactSongFace: View {
    let track: Track
    let width: CGFloat
    @Environment(Player.self) private var player
    @State private var hovering = false

    var body: some View {
        let current = player.current.map { $0.isSameSong(as: track) } ?? false
        HStack(spacing: 10) {
            ArtworkView(url: track.image, size: 48, radius: 6)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.35))
                        PlayingSpeaker(playing: current && player.isPlaying, font: .caption)
                    }
                    .opacity(hovering || current ? 1 : 0)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).textStyle(size: 14, weight: .medium).lineLimit(1)
                Text(track.artistLine).textStyle(size: 12).foregroundStyle(.primary.opacity(0.66)).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
    }
}
