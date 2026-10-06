import SwiftUI

/// One playlist: its cover, name and length, Play and Shuffle, and its songs. Drag a song to move it; right-click
/// to remove it. Everything goes through LibraryStore, which also keeps a playing copy of this playlist in step.
struct PlaylistView: View {
    let id: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var gone = false

    private var detail: PlaylistDetail? { library.details[id] }

    var body: some View {
        Group {
            if gone {
                ContentUnavailableView("This playlist is gone", systemImage: "music.note.list",
                                       description: Text("It was deleted, maybe on another device."))
            } else if let detail {
                songs(detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(detail?.name ?? library.playlists.first { $0.id == id }?.name ?? "Playlist")
        .task(id: id) { gone = !(await library.loadPlaylist(id)) }
    }

    private func songs(_ detail: PlaylistDetail) -> some View {
        let tracks = detail.tracks
        return List {
            header(detail, tracks)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .moveDisabled(true)

            ForEach(Array(detail.items.enumerated()), id: \.element.itemID) { i, entry in
                SongRow(track: tracks[i], queue: tracks, index: i, keys: detail.keys, source: detail.queueSource,
                        removeLabel: "Remove from “\(detail.name)”") {
                    Task { await library.remove(entry, from: detail.id) }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
            }
            .onMove { from, to in Task { await library.moveItems(in: detail.id, from: from, to: to) } }

            if detail.items.isEmpty {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text("Right-click any song › Add to Playlist."))
                    .frame(maxWidth: .infinity)                 // a list row is only as wide as its content: centre it (6 Oct)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.emptyStateFrame = $0 }
                    #endif
                    .padding(.top, 40)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.3), value: detail.keys)          // rows slide when one is removed or added
        .sensoryFeedback(.levelChange, trigger: detail.keys)            // a light tick as the order changes (Force Touch trackpads)
    }

    private func header(_ detail: PlaylistDetail, _ tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 22) {
            PlaylistCover(images: PlaylistCover.images(of: tracks), size: 172, seed: detail.name)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text("Playlist").textStyle(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Text(detail.name).textStyle(size: 34, weight: .bold).lineLimit(2)
                Text(Self.stats(count: detail.items.count, seconds: detail.duration))
                    .textStyle(.body)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                HStack(spacing: 10) {
                    Button { player.playInOrder(tracks, keys: detail.keys, source: detail.queueSource) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tracks.isEmpty)
                    Button { player.shufflePlay(tracks, keys: detail.keys, source: detail.queueSource) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.glass)
                    .disabled(tracks.isEmpty)
                    Menu {
                        Button("Rename…") { library.renameRequest = detail.summary }
                        Button("Delete…", role: .destructive) { library.deleteRequest = detail.summary }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("Rename or delete")
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    /// "12 songs · 48 min", "1 song · 3 min", "30 songs · 1 hr 52 min"
    static func stats(count: Int, seconds: Int) -> String {
        let songs = count == 1 ? "1 song" : "\(count) songs"
        guard count > 0 else { return songs }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
        return "\(songs) · \(length)"
    }
}

/// A playlist's cover until uploads exist (MUS-2 step 5): four songs' covers in a 2×2 grid, one cover when there
/// are fewer than four, or a soft gradient with a note when it is empty.
struct PlaylistCover: View {
    let images: [URL]
    let size: CGFloat
    /// The playlist's name: an empty playlist's gradient takes a colour from it, so empty playlists differ.
    var seed = ""

    /// 0...1, the same for the same name on every launch (Swift's own hashValue changes per launch).
    private var hue: Double {
        let n = seed.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }   // FNV-1a
        return Double(n % 360) / 360
    }

    /// The first four different covers, in playlist order.
    static func images(of tracks: [Track]) -> [URL] {
        var seen = Set<URL>()
        return tracks.compactMap(\.image).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    var body: some View {
        Group {
            if images.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cell(0); cell(1) }
                    GridRow { cell(2); cell(3) }
                }
            } else if let first = images.first {
                ArtworkView(url: first, size: size, radius: 0)
            } else {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.92),
                                        Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "music.note.list").font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.9)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.08, style: .continuous))
    }

    private func cell(_ i: Int) -> some View { ArtworkView(url: images[i], size: size / 2, radius: 0) }
}

/// The sheet for a playlist's name: New Playlist and Rename. The server decides whether a name is free;
/// its reason appears under the field, and the field shakes.
struct NamePlaylistSheet: View {
    let title: String
    let action: String
    var initial = ""
    /// nil: it worked (the sheet closes); otherwise why not.
    let submit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var problem: String?
    @State private var working = false
    @State private var shakes = 0
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Name", text: $name, prompt: Text("My playlist"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit(go)
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { field, x in
                    field.offset(x: reduceMotion ? 0 : x)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(-9, duration: 0.06)
                        SpringKeyframe(8, duration: 0.07)
                        SpringKeyframe(-6, duration: 0.07)
                        SpringKeyframe(4, duration: 0.07)
                        SpringKeyframe(0, duration: 0.1)
                    }
                }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 380)
        .animation(.snappy(duration: 0.25), value: problem)
        .sensoryFeedback(.error, trigger: shakes)
        .onAppear { name = initial; focused = true }
        .onChange(of: name) { problem = nil }
    }

    private func go() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        Task {
            let reason = await submit(trimmed)
            working = false
            if let reason { problem = reason; shakes += 1 } else { dismiss() }
        }
    }
}

/// "Add to Playlist" in a song's right-click menu: every playlist, plus "New Playlist…" (created, then the song added).
struct AddToPlaylistMenu: View {
    let track: Track
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist…") { library.newPlaylistRequest = .init(track: track) }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { Task { await library.add(track, to: playlist) } }
            }
        }
    }
}
