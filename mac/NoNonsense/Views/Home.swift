import SwiftUI

/// The first screen: your music at a glance. Recently played as a shelf of covers, your playlists as a grid,
/// liked songs as compact rows three high that scroll sideways. Each section has See All. A new library shows
/// one friendly step instead of empty space. Sections fade up one after another (not with Reduce Motion).
struct HomeView: View {
    let open: (Destination) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isEmpty: Bool { library.recent.isEmpty && library.liked.isEmpty && library.playlists.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text(Self.greeting(at: .now))
                    .textStyle(size: 34, weight: .bold)
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
                    .appear(appeared, order: 1, reduceMotion: reduceMotion)
                }
                if !library.recent.isEmpty {
                    section("Jump back in", seeAll: .section(.recent)) { recentShelf }
                        .appear(appeared, order: 1, reduceMotion: reduceMotion)
                }
                if !library.playlists.isEmpty {
                    section("Your playlists", seeAll: nil) { playlistGrid }
                        .appear(appeared, order: 2, reduceMotion: reduceMotion)
                }
                if !library.liked.isEmpty {
                    section("Liked Songs", seeAll: .section(.liked)) { likedRows }
                        .appear(appeared, order: 3, reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            // the page is a page, not a web page: it never stretches past its top or bottom. A swipe on a shelf moved
            // it (7 Oct); `.basedOnSize` below stopped that only while the page fitted the window
            .background(ScrollElasticity(vertical: .none, horizontal: .none))
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Home")
        .task { await library.refresh() }
        .onAppear { appeared = true }
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, seeAll: Destination?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).textStyle(.title2, weight: .bold)
                Spacer()
                if let seeAll {
                    Button("See All") { open(seeAll) }
                        .buttonStyle(.quiet)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private var recentShelf: some View {
        let tracks = Array(library.recent.prefix(20))
        return ScrollView(.horizontal) {
            // made once, not lazily: a lazy stack threw away the covers scrolled past and made them again on the way back
            // (that stuttered). Scrolls freely: stopping on a cover felt like snapping (7 Oct)
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    CoverTile(track: track, side: cardSize) { player.play(library.recent, startAt: i) }
                        .selfTestFrame("home.cover:\(i)")
                }
            }
            .padding(.vertical, 12)                         // room for the hover lift and its shadow
            .background(ScrollElasticity(vertical: .none))   // a shelf moves sideways only
        }
        .scrollIndicators(.never)                           // .hidden still showed them with a mouse
        .defaultScrollAnchor(.leading)
        .scrollClipDisabled()
        .selfTestFrame("home.recentShelf")
    }

    private var playlistGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize + 10), spacing: 22, alignment: .topLeading)],
                  alignment: .leading, spacing: 26) {
            ForEach(library.playlists) { playlist in
                PlaylistCard(playlist: playlist, side: cardSize) { open(.playlist(playlist.id)) }
            }
        }
        .padding(.top, 8)
    }

    private var likedRows: some View {
        let tracks = Array(library.liked.prefix(24))
        let rows = max(1, min(3, tracks.count))
        return ScrollView(.horizontal) {
            // three rows, filled down each column. Made once, not lazily (see recentShelf); scrolls freely
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(Array(stride(from: row, to: tracks.count, by: rows)), id: \.self) { i in
                            CompactSongTile(track: tracks[i], width: 300) { player.play(library.liked, startAt: i) }
                                .frame(height: 58)
                        }
                    }
                }
            }
            .background(ScrollElasticity(vertical: .none))   // a shelf moves sideways only
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.leading)
        .selfTestFrame("home.likedShelf")
    }

    private var firstStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your music lives here").textStyle(.title2, weight: .semibold)
            Text("Search for a song you love, then play it, like it, or add it to a playlist.")
                .foregroundStyle(.secondary)
            Button { open(.section(.search)) } label: { Label("Search", systemImage: "magnifyingglass") }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
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

/// A playlist on Home: its cover (loaded on first sight), name and length. Click opens it; the glass ▶ plays it.
struct PlaylistCard: View {
    let playlist: PlaylistSummary
    let side: CGFloat
    let open: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    private var detail: PlaylistDetail? { library.details[playlist.id] }

    var body: some View {
        let play: (() -> Void)? = detail.flatMap { d in
            d.items.isEmpty ? nil : { player.playInOrder(d.tracks, keys: d.keys, source: d.queueSource) }
        }
        VStack(alignment: .leading, spacing: 9) {
            TiltCard(side: side, play: play) {
                PlaylistCover(images: PlaylistCover.images(of: detail?.tracks ?? []), size: side, seed: playlist.name)
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
        // the cover needs the songs: load them once, and again when the count changes
        .task(id: playlist.songCount) {
            if detail?.items.count != playlist.songCount { await library.loadPlaylist(playlist.id) }
        }
        .contextMenu {
            Button("Open") { open() }
            if let play { Button("Play", action: play) }
            Divider()
            Button("Rename…") { library.renameRequest = playlist }
            Button("Delete…", role: .destructive) { library.deleteRequest = playlist }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(playlist.name)")
        #if DEBUG
        .onAppear { SelfTest.appeared["playlist card", default: 0] += 1 }
        #endif
    }
}

/// A song as a compact row (cover, title, artists) for the sideways grids on Home. Click plays it; right-click
/// has the same menu as a full row.
struct CompactSongTile: View {
    let track: Track
    let width: CGFloat
    let play: () -> Void
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        CompactSongFace(track: track, width: width)
            .contentShape(.rect)
            .onTapGesture(perform: play)
            .contextMenu {
                Button("Play", action: play)
                Button("Play Next") { player.playNext(track) }
                Button("Add to Queue") { player.addToQueue(track) }
                Divider()
                Button(library.isLiked(track) ? "Remove from Liked" : "Like") { Task { await library.toggleLike(track) } }
                AddToPlaylistMenu(track: track)
                if downloads.isDownloading(track) {
                    Button("Downloading…") {}.disabled(true)
                } else if downloads.isDownloaded(track) {
                    Button("Remove Download") { downloads.remove(track) }
                } else {
                    Button("Download") { Task { await downloads.download(track) } }
                }
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
/// over and over (8% of a core while hovering, 7 Oct).
private struct CompactSongFace: View {
    let track: Track
    let width: CGFloat
    @Environment(Player.self) private var player
    @State private var hovering = false

    var body: some View {
        let current = player.current.map { $0.isSameSong(as: track) } ?? false
        HStack(spacing: 11) {
            ArtworkView(url: track.image, size: 46, radius: 7)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.35))
                        PlayingSpeaker(playing: current && player.isPlaying, font: .caption)
                    }
                    .opacity(hovering || current ? 1 : 0)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).textStyle(.callout, weight: .medium).lineLimit(1)
                Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
    }
}
