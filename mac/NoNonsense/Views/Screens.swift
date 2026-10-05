import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case search, liked, recent
    var id: String { rawValue }
    var title: String {
        switch self { case .search: "Search"; case .liked: "Liked Songs"; case .recent: "Recently Played" }
    }
    var symbol: String {
        switch self { case .search: "magnifyingglass"; case .liked: "heart"; case .recent: "clock" }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .liked ? library.liked.count : 0)
                    // .tag must come last: placed before .badge, the list could not see it and no row was selectable (5 Oct)
                    .tag(item)
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
}

struct SearchView: View {
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var sources: [SourceInfo] = []
    @State private var isLoading = false
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var unhealthy: [SourceInfo] { sources.filter { !$0.healthy } }
    /// Nothing typed yet: the bar sits lower, as the screen's main element. Typing moves it to the top.
    private var isIdle: Bool { query.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                SearchBar(text: $query, isLoading: isLoading, focused: $fieldFocused) { schedule(query, delay: .zero) }
                if !unhealthy.isEmpty {
                    Label("\(unhealthy.map { $0.source == "jiosaavn" ? "JioSaavn" : "YouTube Music" }.joined(separator: ", ")) unavailable — showing the rest",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, isIdle ? 110 : 18)
            .padding(.bottom, 10)

            ScrollView {
                if isIdle {
                    RecentShelf()                              // until you type: your own music, as covers
                        .padding(.horizontal, 32)
                        .padding(.top, 40)
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
                } else if !isIdle && results.isEmpty && !isLoading {      // idle shows the feature grid instead
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: isIdle)
        .navigationTitle("Search")
        .onChange(of: query) { _, new in schedule(new, delay: .milliseconds(350)) }
        .onAppear { fieldFocused = true }
        // ⌘F from anywhere in the window focuses the bar (an invisible button that only holds the shortcut)
        .background { Button("") { fieldFocused = true }.keyboardShortcut("f", modifiers: .command).hidden() }
    }

    /// Debounce: wait until typing pauses, and cancel the previous search if a new one starts.
    private func schedule(_ text: String, delay: Duration) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; sources = []; failed = false; return }
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
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
                        Text(item.title).font(.largeTitle.bold())
                        Text("\(tracks.count) songs").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                        .disabled(tracks.isEmpty)
                    Button { player.play(Shuffle.tracks(tracks)) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.glass)
                        .disabled(tracks.isEmpty)
                }
                .controlSize(.large)

                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                        SongRow(track: track, queue: tracks, index: i)
                    }
                }
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
                .font(.title3)
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


/// The idle home: the songs you played last, as covers. Nothing at all when there is no history yet.
struct RecentShelf: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let tracks = Array(library.recent.prefix(12))
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Played").font(.title3.weight(.semibold))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            CoverTile(track: track) { player.play(library.recent, startAt: i) }
                        }
                    }
                    .padding(.vertical, 12)                    // room for the hover lift and its shadow
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.leading)                 // open at the first cover (it opened at the last)
                .scrollClipDisabled()                          // shadows and lifted covers draw past the edges
            }
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A cover you can play. Under the pointer it tilts toward it, a soft light follows the pointer across it
/// (the Apple TV focus look), its shadow deepens and a small glass play button floats in.
/// No tilt with Reduce Motion. Drawn only while the pointer moves over it: nothing runs otherwise.
struct CoverTile: View {
    let track: Track
    let play: () -> Void
    @State private var pointer: CGPoint?                 // where the pointer is on the cover, 0...1 each way
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let side: CGFloat = 148

    var body: some View {
        let hovering = pointer != nil
        let tilt = reduceMotion ? nil : pointer
        Button(action: play) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(url: track.image, size: side, radius: 12)
                    .overlay {
                        if let p = tilt {                                     // the light, where the pointer is
                            RadialGradient(colors: [.white.opacity(0.28), .clear], center: UnitPoint(x: p.x, y: p.y),
                                           startRadius: 0, endRadius: side * 0.85)
                                .blendMode(.plusLighter)
                                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            Image(systemName: "play.fill")
                                .font(.callout)
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .padding(10)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: side, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.title)")
    }
}
