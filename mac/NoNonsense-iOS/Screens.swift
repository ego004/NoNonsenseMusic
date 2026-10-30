import SwiftUI

// MARK: - Home

/// What you were playing (when nothing plays), what you played lately as covers, and your playlists as a grid.
struct HomeScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.horizontalSizeClass) private var width
    private var tile: CGFloat { width == .regular ? 176 : 132 }          // larger covers on an iPad

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if player.current == nil, let last = library.recent.first {
                    ResumeCard(track: last) { player.play(Array(library.recent.prefix(20)), startAt: 0) }
                }
                if !library.recent.isEmpty {
                    Shelf(title: "Recently played") {
                        ForEach(Array(library.recent.prefix(20).enumerated()), id: \.offset) { i, track in
                            CoverTile(url: track.image, title: track.title, subtitle: track.artistLine, size: tile) {
                                player.play(Array(library.recent.prefix(20)), startAt: i)
                            }
                            .songMenu(track)
                        }
                    }
                }
                if !library.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Playlists").font(.title3.weight(.bold)).padding(.horizontal)
                        // two columns on an iPhone, more as the width allows (an iPad)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 18) {
                            ForEach(library.playlists) { playlist in
                                NavigationLink(value: playlist) { PlaylistTile(playlist: playlist) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if library.recent.isEmpty && library.playlists.isEmpty {
                    // an empty library and an unreachable one look the same from here: say which (as the Mac does)
                    if Connectivity.shared.serverAnswers {
                        ContentUnavailableView("Nothing played yet", systemImage: "music.note", description: Text("Search for a song to start."))
                            .padding(.top, 80)
                    } else {
                        ContentUnavailableView("Can't reach your server", systemImage: "bolt.horizontal.circle",
                                               description: Text("Your library is on the server. Pull down to try again."))
                            .padding(.top, 80)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PhoneSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .refreshable { if await Connectivity.shared.checkServer() { await library.refresh(); await library.refreshPlaylists() } }
    }
}

/// The last song you played, large, to pick up where you left off.
private struct ResumeCard: View {
    let track: Track
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                Cover(url: track.image, size: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resume").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(track.title).font(.headline).lineLimit(1)
                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.title2)
                    .frame(width: 52, height: 52)
                    .compatGlass(in: Circle(), interactive: true)
            }
            .padding(12)
            .compatGlass(in: RoundedRectangle(cornerRadius: 22))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityLabel("Resume \(track.title), \(track.artistLine)")
    }
}

/// A titled row of tiles that scrolls sideways.
private struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .padding(.horizontal)
            }
        }
    }
}

/// A cover with its title under it; a tap plays.
struct CoverTile: View {
    let url: URL?
    let title: String
    let subtitle: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Cover(url: url, size: size)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

private struct PlaylistTile: View {
    let playlist: PlaylistSummary

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                Cover(url: playlist.thumbnail.flatMap(URL.init(string:)), size: geo.size.width,
                      symbol: playlist.isAlbum ? "square.stack" : "music.note.list")
                Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(playlist.songCount) songs").font(.caption).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(0.78, contentMode: .fit)
    }
}

// MARK: - Search

/// Your recent searches until you type; then, a moment after you stop: the top result, artists, albums and songs.
/// A song plays on its own, then Autoplay (as on the Mac).
struct SearchScreen: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var found: SearchResponse?
    @State private var searching = false
    @State private var problem: String?
    @FocusState private var typing: Bool
    @AppStorage("recentSearches") private var recentText = ""

    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }
    private var songs: [Track] { found?.songs.map(Track.init) ?? [] }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.self) { text in
                            Button { query = text } label: {
                                Label(text, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            var all = recent
                            all.remove(atOffsets: offsets)
                            recentText = all.joined(separator: "\n")
                        }
                    }
                }
            } else {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if let top = songs.first {
                    Section {
                        TopResult(track: top) { remember(); player.play([top], source: "search") }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                if let artists = found?.artists, !artists.isEmpty {
                    Section("Artists") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(artists, id: \.best) { artist in
                                    NavigationLink(value: artist.best) { ArtistBubble(name: artist.name, image: artist.image) }
                                        .buttonStyle(.plain)
                                        .simultaneousGesture(TapGesture().onEnded { remember() })
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                if let albums = found?.albums, !albums.isEmpty {
                    Section("Albums") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(albums, id: \.best) { album in
                                    NavigationLink(value: album.best) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Cover(url: album.best.image.flatMap(URL.init(string:)), size: 120, symbol: "square.stack")
                                            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text(album.best.artists.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 120, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture().onEnded { remember() })
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                if songs.count > 1 {
                    Section("Songs") {
                        ForEach(songs.dropFirst()) { track in
                            TrackRow(track: track) { remember(); player.play([track], source: "search") }
                        }
                    }
                }
            }
        }
        .overlay { if searching && found == nil { ProgressView() } }
        .navigationTitle("Search")
        .navigationDestination(for: ArtistRef.self) { ArtistScreen(ref: $0) }
        .navigationDestination(for: AlbumRef.self) { AlbumScreen(ref: $0) }
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .searchFocused($typing)
        .scrollDismissesKeyboard(.immediately)                  // the results scroll: the keyboard goes
        // opening Search with nothing typed: straight to typing. Straight away is too early on iOS 26, where the field
        // is still moving into the tab bar (seen on 26.4 in the simulator, 29 Oct), so a moment later
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            if query.isEmpty { typing = true }
        }
        .onSubmit(of: .search) { remember() }
        .task(id: query) {
            let typed = query.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { found = nil; problem = nil; return }
            try? await Task.sleep(for: .milliseconds(350))                    // the rest of the word first
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let answer = try await API.search(typed)
                guard !Task.isCancelled else { return }
                found = answer
                problem = answer.songs.isEmpty && (answer.artists ?? []).isEmpty ? "Nothing found for “\(typed)”." : nil
            } catch {
                if !Task.isCancelled { problem = "Couldn't search. Check your connection or the server in Settings." }
            }
        }
    }

    /// The search, kept at the top of Recent (once, the last 10) when you act on its results.
    private func remember() {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        recentText = ([typed] + recent.filter { $0.caseInsensitiveCompare(typed) != .orderedSame }).prefix(10).joined(separator: "\n")
    }
}

/// The first song, large, with a play button.
private struct TopResult: View {
    let track: Track
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                Cover(url: track.image, size: 88)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.title3.weight(.bold)).lineLimit(2)
                    Text(track.artistLine).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.title3)
                    .frame(width: 48, height: 48)
                    .compatGlass(in: Circle(), interactive: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .songMenu(track)
        .accessibilityLabel("Top result: \(track.title), \(track.artistLine)")
    }
}

private struct ArtistBubble: View {
    let name: String
    let image: String?

    var body: some View {
        VStack(spacing: 6) {
            Cover(url: image.flatMap(URL.init(string:)), size: 84, symbol: "person.fill")
                .clipShape(Circle())
            Text(name).font(.caption.weight(.medium)).lineLimit(1).frame(width: 90)
        }
    }
}

/// An artist: photo, name and listeners, Play and Shuffle, their songs, their albums.
struct ArtistScreen: View {
    @Environment(Player.self) private var player
    let ref: ArtistRef
    @State private var detail: ArtistDetail?
    @State private var problem: String?

    var body: some View {
        let songs = detail?.songs.map(Track.init) ?? []
        List {
            Section {
                VStack(spacing: 12) {
                    Cover(url: (detail?.image ?? ref.image).flatMap(URL.init(string:)), size: 160, symbol: "person.fill")
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                    Text(detail?.name ?? ref.name).font(.title.weight(.bold))
                    if let listeners = detail?.monthlyListeners {
                        Text("\(listeners.formatted(.number.notation(.compactName))) monthly listeners")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !songs.isEmpty {
                        CompatGlassGroup(spacing: 12) {
                            HStack(spacing: 12) {
                                Button { player.playInOrder(songs, source: "artist") } label: {
                                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .compatGlassButton(prominent: true)
                                Button { player.shufflePlay(songs, source: "artist") } label: {
                                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                                }
                                .compatGlassButton()
                            }
                            .controlSize(.large)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, track in
                        TrackRow(track: track) { player.play(songs, startAt: i, source: "artist") }
                    }
                }
            }
            if let albums = detail?.albums, !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums, id: \.self) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                Cover(url: album.image.flatMap(URL.init(string:)), size: 52, symbol: "square.stack")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).lineLimit(1)
                                    if let year = album.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(detail?.name ?? ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if detail == nil && problem == nil { ProgressView() } }
        .task {
            do { detail = try await API.artist(ref) } catch { problem = "Couldn't load this artist. Pull to try again." }
        }
        .refreshable { detail = try? await API.artist(ref) }
    }
}

/// An album: its songs under its cover, with Play and Shuffle.
struct AlbumScreen: View {
    let ref: AlbumRef
    @State private var detail: AlbumDetail?
    @State private var problem: String?

    var body: some View {
        SongsScreen(title: detail?.title ?? ref.title, tracks: detail?.songs.map(Track.init) ?? [],
                    source: "album:\(ref.source):\(ref.id)", cover: (detail?.image ?? ref.image).flatMap(URL.init(string:)),
                    symbol: "square.stack")
            .overlay {
                if let problem { Text(problem).foregroundStyle(.secondary) } else if detail == nil { ProgressView() }
            }
            .task {
                do { detail = try await API.album(ref) } catch { problem = "Couldn't load this album." }
            }
    }
}

// MARK: - Library

struct LibraryScreen: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SongsScreen(title: "Liked Songs", tracks: library.liked, source: "liked")
                } label: {
                    Label { Text("Liked Songs") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
            }
            if !library.ownPlaylists.isEmpty {
                Section("Your playlists") {
                    ForEach(library.ownPlaylists) { playlist in
                        NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                    }
                }
            }
            if !library.sharedPlaylists.isEmpty {
                Section("Shared with you") {
                    ForEach(library.sharedPlaylists) { playlist in
                        NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PhoneSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .refreshable { if await Connectivity.shared.checkServer() { await library.refresh(); await library.refreshPlaylists() } }
    }
}

/// Songs under a header (cover, name, count and length), with Play and Shuffle; a tapped song plays from there.
struct SongsScreen: View {
    @Environment(Player.self) private var player
    let title: String
    let tracks: [Track]
    var source: String? = nil
    var cover: URL? = nil
    var symbol = "music.note.list"
    var remove: ((Int) -> Void)? = nil

    var body: some View {
        List {
            Section {
                header.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                    TrackRow(track: track, remove: remove.map { remove in { remove(i) } }) {
                        player.play(tracks, startAt: i, source: source)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Cover(url: cover ?? tracks.first?.image, size: 200, symbol: symbol)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            VStack(spacing: 3) {
                Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text(Self.summary(tracks)).font(.subheadline).foregroundStyle(.secondary)
            }
            if !tracks.isEmpty {
                CompatGlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { player.playInOrder(tracks, source: source) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .compatGlassButton(prominent: true)
                        Button { player.shufflePlay(tracks, source: source) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .compatGlassButton()
                    }
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// "12 songs, 43 min" / "1 song, 3 min" / "120 songs, 7 h 5 min"
    static func summary(_ tracks: [Track]) -> String {
        let minutes = tracks.reduce(0) { $0 + $1.duration } / 60
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(minutes, tracks.isEmpty ? 0 : 1)) min"
        return "\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(length)"
    }
}

struct PlaylistScreen: View {
    @Environment(LibraryStore.self) private var library
    let playlist: PlaylistSummary
    @State private var loaded = false

    var body: some View {
        let detail = library.details[playlist.id]
        let tracks = detail?.items.map { Track($0.song) } ?? []
        SongsScreen(title: playlist.name, tracks: tracks, source: "playlist:\(playlist.id.uuidString)",
                    cover: playlist.thumbnail.flatMap(URL.init(string:)),
                    symbol: playlist.isAlbum ? "square.stack" : "music.note.list",
                    remove: playlist.canEdit ? { i in
                        guard let entry = detail?.items[safe: i] else { return }
                        Task { await library.remove(entry, from: playlist.id) }
                    } : nil)
            .overlay { if !loaded && tracks.isEmpty { ProgressView() } }
            .task {
                _ = await library.loadPlaylist(playlist.id)
                loaded = true
            }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Rows

struct TrackRow: View {
    @Environment(Player.self) private var player
    let track: Track
    var remove: (() -> Void)? = nil
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Cover(url: track.image, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(player.current?.id == track.id ? Color.accentColor : .primary)
                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if track.isExplicit { Image(systemName: "e.square.fill").foregroundStyle(.secondary).font(.caption) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title), \(track.artistLine)\(track.isExplicit ? ", explicit" : "")")
        // swipe right: play next; swipe left: add to the queue (and remove, in a playlist you can edit)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let remove { Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") } }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                .tint(.orange)
        }
        .songMenu(track)
    }
}

extension View {
    /// Long-press: the song's menu, the same everywhere.
    func songMenu(_ track: Track) -> some View { modifier(SongMenu(track: track)) }
}

private struct SongMenu: ViewModifier {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    let track: Track

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Divider()
            let liked = library.isLiked(track)
            Button { Task { await library.toggleLike(track) } } label: {
                Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart")
            }
            if !library.playlists.filter(\.canEdit).isEmpty {
                Menu {
                    ForEach(library.playlists.filter(\.canEdit)) { playlist in
                        Button(playlist.name) { Task { await library.add(track, to: playlist) } }
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistSummary

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: playlist.thumbnail.flatMap(URL.init(string:)), size: 44, symbol: playlist.isAlbum ? "square.stack" : "music.note.list")
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text("\(playlist.songCount) songs").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// A cover from the artwork cache, or a placeholder.
struct Cover: View {
    let url: URL?
    let size: CGFloat
    var symbol = "music.note"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 8).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
        .task(id: url) {
            guard let url else { image = nil; return }
            // a smaller copy already in the cache (the row's, the player's) at once, then the sharp one
            image = [size * 2, 256, 128, 64, 32].lazy.compactMap { ArtworkCache.shared.cached(url, size: $0) }.first
            if let sharp = await ArtworkCache.shared.image(for: url, size: size * 2) { image = sharp }
        }
    }
}
