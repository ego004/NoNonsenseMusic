import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, search, liked, recent
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "Home"; case .search: "Search"; case .liked: "Liked Songs"; case .recent: "Recently Played" }
    }
    var symbol: String {
        switch self { case .home: "house"; case .search: "magnifyingglass"; case .liked: "heart"; case .recent: "clock" }
    }
}

/// What the window shows: one of the fixed screens, or one playlist.
enum Destination: Hashable {
    case section(SidebarItem)
    case playlist(UUID)
}

struct SidebarView: View {
    @Binding var selection: Destination?
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .liked ? library.liked.count : 0)
                    // .tag must come last: placed before .badge, the list could not see it and no row was selectable (5 Oct)
                    .tag(Destination.section(item))
            }
            Section {
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .symbolEffect(.bounce, value: playlist.songCount)     // a song just went in here: the icon hops
                        .contextMenu {
                            Button("Play") { Task { await play(playlist, shuffled: false) } }
                            Button("Shuffle") { Task { await play(playlist, shuffled: true) } }
                            Divider()
                            Button("Rename…") { library.renameRequest = playlist }
                            Button("Delete…", role: .destructive) { library.deleteRequest = playlist }
                        }
                        .tag(Destination.playlist(playlist.id))            // last, as above
                }
                .onMove { from, to in Task { await library.movePlaylists(from: from, to: to) } }
                .animation(.snappy(duration: 0.3), value: library.playlists.map(\.id))   // new and deleted playlists slide
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { library.newPlaylistRequest = .init(track: nil) } label: {
                        Image(systemName: "plus").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("New Playlist (⌘N)")
                    .accessibilityLabel("New Playlist")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    /// Play from the sidebar without opening the playlist: load its songs, then play them.
    private func play(_ playlist: PlaylistSummary, shuffled: Bool) async {
        guard await library.loadPlaylist(playlist.id), let detail = library.details[playlist.id], !detail.items.isEmpty else { return }
        if shuffled { player.shufflePlay(detail.tracks, keys: detail.keys, source: detail.queueSource) }
        else { player.playInOrder(detail.tracks, keys: detail.keys, source: detail.queueSource) }
    }
}

struct SearchView: View {
    @Environment(Player.self) private var player
    /// Searches that led to a song you played, newest first (RecentSearches): the idle screen offers them again.
    @AppStorage("recentSearches") private var recentRaw = ""
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var sources: [SourceInfo] = []
    @State private var isLoading = false
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var unhealthy: [SourceInfo] { sources.filter { !$0.healthy } }
    /// The "No Results" screen: only for a finished search that found nothing.
    private var showsNoResults: Bool { !failed && !isIdle && results.isEmpty && !isLoading }
    /// Nothing typed yet: the bar sits lower, as the screen's main element. Typing moves it to the top.
    private var isIdle: Bool { query.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                SearchBar(text: $query, isLoading: isLoading, focused: $fieldFocused) { schedule(query, delay: .zero) }
                if !unhealthy.isEmpty {
                    Label("\(unhealthy.map { $0.source == "jiosaavn" ? "JioSaavn" : "YouTube Music" }.joined(separator: ", ")) unavailable — showing the rest",
                          systemImage: "exclamationmark.triangle")
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, isIdle ? 110 : 18)
            .padding(.bottom, 10)

            ScrollView {
                if isIdle {
                    RecentSearchChips(raw: $recentRaw) { query = $0 }   // until you type: what you searched before
                        .padding(.horizontal, 32)
                        .padding(.top, 36)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, track in
                            SongRow(track: track, queue: results, index: i)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .overlay {
                if failed {
                    ContentUnavailableView("Can't reach your server", systemImage: "wifi.exclamationmark",
                                           description: Text("Is the backend running at \(API.baseURL.absoluteString)?"))
                } else if showsNoResults {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: isIdle)
        .navigationTitle("Search")
        #if DEBUG
        .onChange(of: showsNoResults, initial: true) { _, now in SelfTest.noResultsShowing = now }
        .onChange(of: results.count, initial: true) { _, n in SelfTest.searchResultCount = n }
        // a self-test plays the first result exactly as a double-click on its row does
        .onReceive(NotificationCenter.default.publisher(for: .selfTestPlayFirstResult)) { _ in
            if !results.isEmpty { player.play(results, startAt: 0) }
        }
        #endif
        .onChange(of: query) { _, new in schedule(new, delay: .milliseconds(350)) }
        // a search counts as "recent" once it led to music: a song from these results started playing
        .onChange(of: player.current?.id) { _, id in
            guard let id, !isIdle, results.contains(where: { $0.id == id }) else { return }
            recentRaw = RecentSearches.adding(query, to: recentRaw)
        }
        .onAppear { fieldFocused = true }
        // ⌘F from anywhere in the window focuses the bar (an invisible button that only holds the shortcut)
        .background { Button("") { fieldFocused = true }.keyboardShortcut("f", modifiers: .command).hidden() }
    }

    /// Debounce: wait until typing pauses, and cancel the previous search if a new one starts.
    private func schedule(_ text: String, delay: Duration) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; sources = []; failed = false; isLoading = false; return }
        // loading from the first keystroke, not after the 350 ms pause: "No Results" flashed in that gap (16 of 72
        // samples while typing "arijit", 6 Oct). Only the newest search turns it off: a cancelled one used to, as it died.
        isLoading = true
        task = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let response = try await API.search(q)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    results = response.songs.map(Track.init)
                    sources = response.sources
                }
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

    private var tracks: [Track] { item == .liked ? library.liked : library.recent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).textStyle(.largeTitle, weight: .bold)
                        Text("\(tracks.count) songs").textStyle(.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { player.playInOrder(tracks) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                        .disabled(tracks.isEmpty)
                    Button { player.shufflePlay(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.glass)
                        .disabled(tracks.isEmpty)
                }
                .controlSize(.large)

                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                        SongRow(track: track, queue: tracks, index: i)
                    }
                }
                .animation(.snappy(duration: 0.3), value: tracks.map(\.id))     // a like or a new play slides rows in
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(item == .liked ? "No liked songs yet" : "Nothing played yet",
                                       systemImage: item.symbol,
                                       description: Text(item == .liked ? "Tap ♥ on any song to keep it here."
                                                                       : "Songs you play show up here."))
            }
        }
        .navigationTitle(item.title)
        .task { await library.refresh() }
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
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .glassEffect(.regular.interactive(), in: .capsule)
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
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 8) {
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
                    .buttonStyle(.plain)
                    .help("Remove")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onTapGesture(perform: search)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
        .contextMenu { Button("Remove", action: remove) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Search \(query)")
    }
}

/// Lays its views out left to right, starting a new line when one does not fit (like words in a paragraph).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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
                y += lineHeight + spacing
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hovering = pointer != nil
        let tilt = reduceMotion ? nil : pointer
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
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Play")
                }
            }
            .rotation3DEffect(.degrees(tilt.map { ($0.y - 0.5) * -9 } ?? 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(tilt.map { ($0.x - 0.5) * 9 } ?? 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .shadow(color: .black.opacity(hovering ? 0.32 : 0.14), radius: hovering ? 18 : 8, y: hovering ? 12 : 4)
            .scaleEffect(hovering ? 1.035 : 1)
            .onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                        pointer = CGPoint(x: min(max(at.x / side, 0), 1), y: min(max(at.y / side, 0), 1))
                    }
                case .ended:
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { pointer = nil }
                }
            }
    }
}
