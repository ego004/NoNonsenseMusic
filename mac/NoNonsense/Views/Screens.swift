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
                    .tag(item)
                    .badge(item == .liked ? library.liked.count : 0)
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

    private var unhealthy: [SourceInfo] { sources.filter { !$0.healthy } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, track in
                    SongRow(track: track, queue: results, index: i)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .overlay {
            if isLoading && results.isEmpty {
                ProgressView().controlSize(.large)
            } else if failed {
                ContentUnavailableView("Can't reach your server", systemImage: "wifi.exclamationmark",
                                       description: Text("Is the backend running at \(API.baseURL.absoluteString)?"))
            } else if query.isEmpty {
                ContentUnavailableView("Find something to play", systemImage: "music.note",
                                       description: Text("Search JioSaavn and YouTube Music at once."))
            } else if results.isEmpty && !isLoading {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .top) {
            if !unhealthy.isEmpty {
                Label("\(unhealthy.map { $0.source == "jiosaavn" ? "JioSaavn" : "YouTube Music" }.joined(separator: ", ")) unavailable — showing the rest",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Songs, artists, albums")
        .onChange(of: query) { _, new in schedule(new, delay: .milliseconds(350)) }
        .onSubmit(of: .search) { schedule(query, delay: .zero) }
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
