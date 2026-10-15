import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, library, search, liked, recent, downloads, friends
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "Home"; case .library: "Library"; case .search: "Search"; case .liked: "Liked Songs"; case .recent: "Recently Played"; case .downloads: "Downloads"; case .friends: "Friends" }
    }
    var symbol: String {
        switch self { case .home: "house"; case .library: "books.vertical"; case .search: "magnifyingglass"; case .liked: "heart"; case .recent: "clock"; case .downloads: "arrow.down.circle"; case .friends: "person.2" }
    }
}

/// What the window shows: one of the fixed screens, or one playlist.
enum Destination: Hashable {
    case section(SidebarItem)
    case playlist(UUID)
}

/// The sidebar (15 Oct, as in the Windows app): the logo, the places, then Playlists: Liked Songs, Recently Played and
/// Downloads, your playlists and those shared with you, each a picture with its name and how many songs. Who is signed
/// in, and Settings, at the bottom. Search is not here: it is the command bar's, at the top of the page.
struct SidebarView: View {
    @Binding var selection: Destination?
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(Player.self) private var player
    @Environment(Account.self) private var account
    @AppStorage("sidebarBlur") private var sidebarBlur = Look.sidebarBlur      // Settings › Appearance › Surfaces › Sidebar
    @AppStorage("sidebarSolid") private var sidebarSolid = Look.sidebarSolid

    /// The places at the top. Liked Songs, Recently Played and Downloads are pictures under Playlists now.
    private static let places: [SidebarItem] = [.home, .library, .friends]

    var body: some View {
        // While an artist or album page is open, no row is selected: you are on that page. A click on any row,
        // the one you came from included, is then a real selection, and it closes the page. A tap gesture on the
        // rows did this before, but it competed with the list's own click and ate clicks on a row's text (11 Oct)
        List(selection: Binding(get: { Navigator.shared.path.isEmpty ? selection : nil },
                                set: { if let picked = $0 { selection = picked; Navigator.shared.path = [] } })) {
            brand                                                   // no tag: not a place, never selected
            ForEach(Self.places) { item in
                Label {
                    Text(item.title).selfTestFrame("sidebar.title:\(item.title)").selfTestFrame("sidebar.place:\(item.title)")
                } icon: {
                    Image(systemName: item.symbol).selfTestFrame("sidebar.icon:\(item.title)")
                }
                .badge(item == .friends ? Social.shared.incoming.count : 0)
                // .tag must come last: placed before .badge, the list could not see it and no row was selectable (5 Oct)
                .tag(Destination.section(item))
            }
            Section {
                ForEach(SidebarItem.collections(downloads)) { item in
                    PictureRow(name: item.title, count: item.songCount(library: library, downloads: downloads)) {
                        CollectionTile(item: item, size: 40)
                    }
                    .tag(Destination.section(item))                 // last, as above
                }
                ForEach(library.ownPlaylists) { playlistRow($0) }
                    // only your own: shared ones keep their owner's order (LibraryStore.movePlaylists)
                    .onMove { from, to in Task { await library.movePlaylists(from: from, to: to) } }
                    .animation(.snappy(duration: 0.3), value: library.ownPlaylists.map(\.id))   // new and deleted playlists slide
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { library.newPlaylistRequest = .init(track: nil) } label: { Image(systemName: "plus").font(.body) }
                        .buttonStyle(.quiet)
                        .help("New Playlist (⌘N)")
                        .accessibilityLabel("New Playlist")
                        .selfTestFrame("sidebar.newPlaylist")
                        // the header runs wider than the rows (6 Oct): this brings the + back over the rows' right edge
                        .padding(.trailing, 8)
                }
            }
            // under your own, as Shared with You in Apple's apps (AUTH-3)
            if !library.sharedPlaylists.isEmpty {
                Section {
                    ForEach(library.sharedPlaylists) { playlistRow($0) }
                        .animation(.snappy(duration: 0.3), value: library.sharedPlaylists.map(\.id))
                } header: {
                    Text("Shared with You")
                }
            }
        }
        .selfTestFrame("sidebar.list")
        .safeAreaInset(edge: .bottom) { accountRow }
        // macOS draws the sidebar as a floating glass panel, and SwiftUI cannot change that glass (probed 6 Oct:
        // NSContainerConcentricGlassEffectView). This frosts and fills over it, inside the panel; 0 / 0 draws nothing.
        .background { SurfaceLayer(blur: sidebarBlur, solid: sidebarSolid, blending: .behindWindow).ignoresSafeArea() }
    }

    /// The logo's mark in the colour of the text, and the app's name.
    private var brand: some View {
        HStack(spacing: 10) {
            Image("Mark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .accessibilityHidden(true)
            Text("NoNonsenseMusic").tracking(-0.2).textStyle(size: 14.5, weight: .bold).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.bottom, 10)
        .selfTestFrame("sidebar.brand")
    }

    /// Who is signed in, and the gear that opens Settings (it replaced the Settings row).
    @ViewBuilder private var accountRow: some View {
        let name = account.user?.username ?? ""
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 10) {
                Avatar(name: name, size: 34)
                Text(name).textStyle(size: 14, weight: .semibold).lineLimit(1)
                Spacer(minLength: 4)
                SettingsLink { Image(systemName: "gearshape").font(.title3) }
                    .buttonStyle(.quiet)
                    .foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
                    .selfTestFrame("sidebar.settings")
            }
            .selfTestFrame("sidebar.account")
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        #if DEBUG
        .onChange(of: name, initial: true) { _, now in SelfTest.shownText["sidebar.account"] = now }
        #endif
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        PictureRow(name: playlist.name, count: playlist.songCount) { SidebarPlaylistCover(playlist: playlist) }
            .contextMenu {
                Button("Play") { Task { await play(playlist, shuffled: false) } }
                Button("Shuffle") { Task { await play(playlist, shuffled: true) } }
                Divider()
                PlaylistRoleActions(playlist: playlist)
            }
            .tag(Destination.playlist(playlist.id))            // last, as above
    }

    /// Play from the sidebar without opening the playlist: load its songs, then play them.
    private func play(_ playlist: PlaylistSummary, shuffled: Bool) async {
        guard await library.loadPlaylist(playlist.id), let detail = library.details[playlist.id], !detail.items.isEmpty else { return }
        if shuffled { player.shufflePlay(detail.tracks, keys: detail.keys, source: detail.queueSource) }
        else { player.playInOrder(detail.tracks, keys: detail.keys, source: detail.queueSource) }
    }
}

/// A collection or a playlist under Playlists: a 40 pt picture, the name, and "12 songs" under it.
private struct PictureRow<Picture: View>: View {
    let name: String
    let count: Int
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        let detail = SongListView.count(count)
        HStack(spacing: 12) {
            picture()
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .selfTestFrame("sidebar.icon:\(name)")
            VStack(alignment: .leading, spacing: 1) {
                Text(name).textStyle(size: 13.5, weight: .semibold).lineLimit(1).selfTestFrame("sidebar.title:\(name)")
                Text(detail).textStyle(size: 12).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selfTestFrame("sidebar.row:\(name)")
        #if DEBUG
        .onChange(of: detail, initial: true) { _, now in SelfTest.shownText["sidebar.detail:\(name)"] = now }
        #endif
    }
}

/// A playlist's 2×2 cover in the sidebar, from the songs already loaded (Home's cards and the playlist itself load
/// them; the sidebar does not): the name's gradient until then. Its own view, so a playlist loading redraws only this.
private struct SidebarPlaylistCover: View {
    let playlist: PlaylistSummary
    @Environment(LibraryStore.self) private var library

    var body: some View {
        PlaylistCover(images: PlaylistCover.images(of: (library.details[playlist.id]?.items ?? []).lazy.map {
            Track.coverURL(image: $0.song.image, listings: [$0.song.best] + $0.song.listings)
        }), size: 40, seed: playlist.name)
    }
}

/// What Search shows: everything, or songs, artists or albums alone (the server then asks the sources for less).
enum SearchFilter: String, CaseIterable, Identifiable {
    case all, songs, artists, albums
    var id: String { rawValue }
    var title: String { self == .all ? "All" : rawValue.capitalized }
}

struct SearchView: View {
    /// ⌘K or ⌘F on the Search page, which has no command bar (RootView counts the presses): each focuses the search bar
    var focusRequests = 0
    @Environment(Player.self) private var player
    /// Searches that led to a song you played, newest first (RecentSearches): the idle screen offers them again.
    @AppStorage("recentSearches") private var recentRaw = ""
    @State private var query: String
    @State private var results: [Track] = []
    @State private var artists: [SearchArtist] = []
    @State private var albums: [AlbumRef] = []
    @State private var filter = SearchFilter.all
    @State private var sources: [SourceInfo] = []
    @State private var isLoading = false
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// `initialQuery`: words searched at once, as the command bar's "All results for “…”" opens Search.
    init(focusRequests: Int = 0, initialQuery: String = "") {
        self.focusRequests = focusRequests
        _query = State(initialValue: initialQuery)
    }

    private var unhealthy: [SourceInfo] { sources.filter { !$0.healthy } }

    /// "JioSaavn didn't respond. Search again to include it." for the sources whose results are missing.
    static func didNotRespond(_ names: [String]) -> String {
        let list = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) didn't respond. Search again to include \(names.count < 2 ? "it" : "them")."
    }
    /// The "No Results" screen: only for a finished search that found nothing.
    private var showsNoResults: Bool { !failed && !isIdle && results.isEmpty && artists.isEmpty && albums.isEmpty && !isLoading }
    /// Nothing typed yet: the bar sits lower, as the screen's main element. Typing moves it to the top.
    private var isIdle: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                SearchBar(text: $query, isLoading: isLoading, focused: $fieldFocused) { schedule(query, delay: .zero) }
                if !isIdle { FilterCapsules(selection: $filter) }
                if !unhealthy.isEmpty {
                    Label(Self.didNotRespond(unhealthy.map { Listing.name(ofSource: $0.source) }), systemImage: "exclamationmark.triangle")
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, isIdle ? 110 : 18)
            .padding(.bottom, 10)

            Group {
                if isIdle {
                    ScrollView {
                        RecentSearchChips(raw: $recentRaw) { query = $0 }   // until you type: what you searched before
                            .padding(.horizontal, 32)
                            .padding(.top, 36)
                            .padding(.bottom, 24)
                    }
                    .transition(.opacity)
                } else {
                    // a List, not a LazyVStack in a ScrollView: that redrew the whole window on every step of a scroll
                    // (Liked Songs: 114 late frames in 14 s against 8 as a List, 8 Oct; SongListView)
                    if filter == .artists {
                        ScrollView { ArtistGrid(artists: artists).padding(.horizontal, 24).padding(.vertical, 12) }
                    } else if filter == .albums {
                        ScrollView { AlbumGrid(albums: albums).padding(.horizontal, 24).padding(.vertical, 12) }
                    } else {
                    List {
                        if !artists.isEmpty {
                            ArtistShelf(artists: artists) { filter = .artists }
                                .browseRow(top: 6, bottom: 8, inset: 24).selfTestFrame("search.artists")
                        }
                        if !albums.isEmpty {
                            AlbumShelf(albums: albums) { filter = .albums }.browseRow(top: 6, bottom: 8, inset: 24)
                        }
                        if !results.isEmpty && (!artists.isEmpty || !albums.isEmpty) {
                            Text("Songs").textStyle(.title3, weight: .bold).browseRow(top: 6, bottom: 2, inset: 24)
                        }
                        // a search result plays alone; Autoplay then continues with songs like it, not with the rest
                        // of the results
                        ForEach(results) { track in
                            SongRow(track: track, queue: [track], index: 0)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if failed {
                    ContentUnavailableView("Can't reach your server", systemImage: "wifi.exclamationmark",
                                           description: Text("Check that the server at \(API.baseURL.absoluteString) is running."))
                } else if showsNoResults {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: isIdle)
        .fixedTitle("Search")
        #if DEBUG
        .onChange(of: showsNoResults, initial: true) { _, now in SelfTest.noResultsShowing = now }
        .onChange(of: results.count, initial: true) { _, n in SelfTest.searchResultCount = n; SelfTest.searchTop = results.first?.best }
        // a self-test plays the first result exactly as a double-click on its row does
        .onReceive(NotificationCenter.default.publisher(for: .selfTestSearch)) { note in
            if let text = note.object as? String { query = text }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfTestPlayFirstResult)) { _ in
            if let first = results.first { player.play([first]) }
        }
        #endif
        .onChange(of: query) { _, new in schedule(new, delay: .milliseconds(350)) }
        .onChange(of: filter) { schedule(query, delay: .zero) }
        // a search counts as "recent" once it led to music: a song from these results started playing
        .onChange(of: player.current?.id) { _, id in
            guard let id, !isIdle, results.contains(where: { $0.id == id }) else { return }
            recentRaw = RecentSearches.adding(query, to: recentRaw)
        }
        .onAppear {
            fieldFocused = true
            if !isIdle, task == nil { schedule(query, delay: .zero) }   // opened with words (All results): searched at once
        }
        // a search still on its way would land after this and hand its results to the Prefetcher again
        .onDisappear { task?.cancel(); Prefetcher.shared.searchChanged([]) }
        // ⌘K or ⌘F while Search is open: RootView holds the shortcuts, so they work from every screen (⌘F lived
        // here, so it worked only on Search: audit, 7 Oct)
        .onChange(of: focusRequests) { fieldFocused = true }
    }

    /// Debounce: wait until typing pauses, and cancel the previous search if a new one starts.
    private func schedule(_ text: String, delay: Duration) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; artists = []; albums = []; sources = []; failed = false; isLoading = false; Prefetcher.shared.searchChanged([]); return }
        // loading from the first keystroke, not after the 350 ms pause: "No Results" flashed in that gap (16 of 72
        // samples while typing "arijit", 6 Oct). Only the newest search turns it off: a cancelled one used to, as it died.
        isLoading = true
        task = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let response = try await API.search(q, filter: filter.rawValue)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    results = response.songs.map(Track.init)
                    // All shows a shelf of each; a filter shows every one found
                    artists = Array((response.artists ?? []).prefix(filter == .all ? 8 : 60))
                    albums = Array((response.albums ?? []).prefix(filter == .all ? 12 : 60).map(\.best))
                    sources = response.sources
                }
                Prefetcher.shared.searchChanged(results.prefix(5).map(\.best))   // the top results (as many as Settings › Footprint says) start at once
                failed = false
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// Liked Songs and Recently Played: a big header with Play and Shuffle, then the list.
struct SongListView: View {
    let item: SidebarItem
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @State private var confirmingRemoveAll = false
    @State private var filter = ""

    private var tracks: [Track] {
        switch item {
        case .liked: library.liked
        case .downloads: downloads.tracks            // from this Mac: there even with the server off
        default: library.recent
        }
    }

    var body: some View {
        let tracks = self.tracks
        // a List (an AppKit table: each row its own small host, moved by AppKit as you scroll), not a ScrollView with a
        // LazyVStack: that rebuilt the whole window's drawing on every step of a scroll, 17 ms a frame where a 120 Hz
        // screen gives 8: the scroll ran at about 60 frames a second and stuttered (114 late frames in 14 s of flicks,
        // against 11 for the same songs in a List; measured with real trackpad input and Instruments, 8 Oct)
        // Search narrows the rows; playing one plays what is shown, in that order
        let shown = filter.isEmpty ? tracks : tracks.filter { songMatches($0, filter) }
        List {
            header(tracks).pageRow(top: 20, bottom: 16)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, track in
                SongRow(track: track, queue: shown, index: i).pageRow(top: 1, bottom: 1, inset: 24)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.3), value: tracks.map(\.id))     // a like or a new play slides rows in
        .overlay {
            if !tracks.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if tracks.isEmpty && item != .downloads && !Connectivity.shared.serverAnswers {
                // not "No liked songs yet" when the songs are only out of reach (a server down at launch said that)
                ContentUnavailableView("Can't reach your server", systemImage: "bolt.horizontal.circle",
                                       description: Text("\(item.title) comes from it. Downloads still play."))
            } else if tracks.isEmpty {
                switch item {
                case .liked:
                    ContentUnavailableView("No liked songs yet", systemImage: item.symbol, description: Text("Click ♥ on any song to keep it here."))
                case .downloads:
                    ContentUnavailableView("Nothing downloaded yet", systemImage: item.symbol,
                                           description: Text("Right-click a song › Download, or click Download at the top of a playlist. Downloads play without the server or the internet."))
                default:
                    ContentUnavailableView("Nothing played yet", systemImage: item.symbol, description: Text("Songs you play show up here."))
                }
            }
        }
        .confirmationDialog("Remove all \(tracks.count) downloads?", isPresented: $confirmingRemoveAll) {
            Button("Remove All", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They stay in your library and still play from the internet.")
        }
        .scrollTitle(item.title)
        .task { await library.refreshIfStale() }
    }

    /// "1 song", "12 songs".
    static func count(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    private func header(_ tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).tracking(-0.6).textStyle(size: 32, weight: .bold)         // as the Windows app's (15 Oct)
                Text(item == .downloads ? "\(Self.count(tracks.count)) · \(formatBytes(downloads.totalBytes)) on this Mac" : Self.count(tracks.count))
                    .textStyle(.body).foregroundStyle(.secondary)
            }
            Spacer()
            if !tracks.isEmpty { FilterField(text: $filter) }
            Button { player.playInOrder(tracks) } label: { Label("Play", systemImage: "play.fill") }
                .compatGlassButton(prominent: true)
                .disabled(tracks.isEmpty)
            Button { player.shufflePlay(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                .compatGlassButton()
                .disabled(tracks.isEmpty)
            if item != .downloads { DownloadAllButton(tracks: tracks, name: item.title) }
            if item == .downloads {
                Button("Remove All", role: .destructive) { confirmingRemoveAll = true }
                    .compatGlassButton()
                    .disabled(tracks.isEmpty)
            }
        }
        .controlSize(.large)
    }
}


// MARK: - filtering a list

/// Whether a song matches what was typed in a list's Search: every word in its title, artists or album, ignoring case
/// and accents ("beyonce" finds "Beyoncé").
func songMatches(_ track: Track, _ query: String) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let text = ([track.best.title, track.best.album ?? ""] + track.best.artists).joined(separator: " ")
    return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

/// A list's Search: narrows the songs shown to those matching what is typed (Liked Songs, Recently Played, Downloads,
/// a playlist). Escape clears it. Called Search, not Filter: it finds by words (13 Oct)
struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .onKeyPress(.escape) { text = ""; return .handled }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 190)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Download for a whole list, beside Play and Shuffle: "Downloading 3 of 20" while it runs, "Downloaded" once every
/// song is on this Mac. One song at a time, each fetched as playback fetches it.
struct DownloadAllButton: View {
    let tracks: [Track]
    let name: String
    @Environment(DownloadStore.self) private var downloads
    @State private var working = false

    var body: some View {
        let done = tracks.filter { downloads.isDownloaded($0) }.count
        let all = !tracks.isEmpty && done == tracks.count
        Button {
            working = true
            Task { await downloads.download(all: tracks, name: name); working = false }
        } label: {
            Label(all ? "Downloaded" : working ? "Downloading \(done) of \(tracks.count)" : "Download",
                  systemImage: all ? "checkmark.circle.fill" : "arrow.down.circle")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .compatGlassButton()
        .disabled(all || working || tracks.isEmpty || !downloads.available)     // the downloads folder is not there
        .help(all ? "Every song here plays without the internet" : "Download every song, to play without the internet")
    }
}

/// The big centred search bar: Liquid Glass capsule, icon, field, a spinner while searching, a clear button.
struct SearchBar: View {
    @Binding var text: String
    var isLoading: Bool
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Songs, artists, albums", text: $text)
                .textFieldStyle(.plain)
                .textStyle(.title3)
                .focused(focused)
                .onSubmit(onSubmit)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.quiet)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .compatGlass(in: .capsule, interactive: true)
        .frame(maxWidth: 580)
    }
}


/// The searches that led to a song you played, newest first, at most 12, stored on this Mac only
/// (UserDefaults "recentSearches", one per line). The same words in other capitals count as one search.
enum RecentSearches {
    static func list(_ raw: String) -> [String] { raw.split(separator: "\n").map(String.init) }

    static func adding(_ query: String, to raw: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return raw }
        let rest = list(raw).filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        return ([q] + rest).prefix(12).joined(separator: "\n")
    }

    static func removing(_ query: String, from raw: String) -> String {
        list(raw).filter { $0 != query }.joined(separator: "\n")
    }
}

/// The idle Search screen: your recent searches as glass chips that wrap onto new lines. Click one to search it
/// again; ✕ (on hover) or right-click removes one; Clear removes all. A hint when there are none yet.
struct RecentSearchChips: View {
    @Binding var raw: String
    let search: (String) -> Void

    var body: some View {
        let recent = RecentSearches.list(raw)
        VStack(alignment: .leading, spacing: 14) {
            if recent.isEmpty {
                Text("Try a song or an artist. Searches that lead to music show up here.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent searches").textStyle(.title3, weight: .semibold)
                    Spacer()
                    Button("Clear") { withAnimation(.snappy) { raw = "" } }
                        .buttonStyle(.quiet)
                        .foregroundStyle(.secondary)
                }
                CompatGlassGroup(spacing: 8) {
                    FlowLayout(spacing: 8) {
                        ForEach(recent, id: \.self) { query in
                            RecentChip(query: query) { search(query) } remove: {
                                withAnimation(.snappy) { raw = RecentSearches.removing(query, from: raw) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct RecentChip: View {
    let query: String
    let search: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
            Text(query).textStyle(.callout).lineLimit(1)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.quiet)
                    .help("Remove")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(.capsule)
        .compatGlass(in: .capsule, interactive: true)
        .onTapGesture(perform: search)
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
        .contextMenu { Button("Remove", action: remove) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Search \(query)")
    }
}

/// Lays its views out left to right, starting a new line when one does not fit (like words in a paragraph).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat?                               // between lines; nil: spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in rows(for: subviews, width: bounds.width).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {              // does not fit: a new line
                x = 0
                y += lineHeight + (lineSpacing ?? spacing)
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + lineHeight))
    }
}

/// A song cover you can play: a TiltCard with the title and artists under it. Click anywhere plays.
struct CoverTile: View {
    let track: Track
    var side: CGFloat = Look.cardSize
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TiltCard(side: side, play: play) { ArtworkView(url: track.image, size: side, radius: 12) }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).textStyle(.callout, weight: .medium).lineLimit(1)
                Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture(perform: play)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Play \(track.title)")
        #if DEBUG
        .onAppear { SelfTest.appeared["cover", default: 0] += 1 }
        #endif
    }
}

/// Any square artwork that answers the pointer: it tilts toward it, a soft light follows the pointer across it
/// (the Apple TV focus look), its shadow deepens and a small glass ▶ floats in (when `play` is given).
/// No tilt with Reduce Motion. Nothing runs until the pointer moves over it.
struct TiltCard<Art: View>: View {
    let side: CGFloat
    var radius: CGFloat = 12
    var play: (() -> Void)? = nil
    @ViewBuilder let art: () -> Art
    @State private var pointer: CGPoint?                 // where the pointer is on the card, 0...1 each way
    @State private var plainHover = false                // tilt off: only whether the pointer is over it
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Settings › Appearance › Cover tilt. Off by default: the tilt springs on every pointer move and animates the
    // shadow's blur, and each frame redraws the whole window (profiled 7 Oct). Off, hover only shows ▶, instantly
    @AppStorage("coverTilt") private var tiltOn = Look.coverTilt

    var body: some View {
        let hovering = tiltOn ? pointer != nil : plainHover
        let tilt = (reduceMotion || !tiltOn) ? nil : pointer
        art()
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                if let p = tilt {                                     // the light, where the pointer is
                    RadialGradient(colors: [.white.opacity(0.28), .clear], center: UnitPoint(x: p.x, y: p.y),
                                   startRadius: 0, endRadius: side * 0.85)
                        .blendMode(.plusLighter)
                        .clipShape(.rect(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering, let play {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.callout)
                            .frame(width: 36, height: 36)
                            .compatGlass(in: .circle, interactive: true)
                    }
                    .buttonStyle(.quiet)
                    .padding(10)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Play")
                }
            }
            .rotation3DEffect(.degrees(tilt.map { ($0.y - 0.5) * -9 } ?? 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(tilt.map { ($0.x - 0.5) * 9 } ?? 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .shadow(color: .black.opacity(tilt != nil ? 0.32 : 0.14), radius: tilt != nil ? 18 : 8, y: tilt != nil ? 12 : 4)
            .scaleEffect(tilt != nil ? 1.035 : 1)
            .modifier(TiltPointer(tiltOn: tiltOn, side: side, pointer: $pointer, plainHover: $plainHover))
    }
}

/// How a TiltCard follows the pointer. Tilt off (the default): only whether it is over the card. Following every
/// pointer move (also while a shelf scrolls under a still pointer) only to ignore it cost work on every frame.
private struct TiltPointer: ViewModifier {
    let tiltOn: Bool
    let side: CGFloat
    @Binding var pointer: CGPoint?
    @Binding var plainHover: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if tiltOn {
            content.onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                        pointer = CGPoint(x: min(max(at.x / side, 0), 1), y: min(max(at.y / side, 0), 1))
                    }
                case .ended:
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { pointer = nil }
                }
            }
        } else {
            content.onHover { plainHover = $0 }
        }
    }
}
