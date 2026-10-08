import SwiftUI

/// One playlist: its cover, name and length, Play and Shuffle, and its songs. Drag a song to move it; right-click
/// to remove it. Everything goes through LibraryStore, which also keeps a playing copy of this playlist in step.
struct PlaylistView: View {
    let id: UUID
    /// It is gone (deleted, or no longer shared with you): RootView closes it.
    var closed: () -> Void = {}
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @State private var loading = true
    @State private var selection: Set<UUID> = []

    private var detail: PlaylistDetail? { library.details[id] }

    var body: some View {
        Group {
            if let detail {
                songs(detail)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(library.playlists.first { $0.id == id }?.name ?? "Playlist")
            } else {
                // the server could not be asked (it spun forever, audit 7 Oct): say so, and offer to ask again
                ContentUnavailableView {
                    Label("Couldn't load this playlist", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Is the server running?")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .navigationTitle(library.playlists.first { $0.id == id }?.name ?? "Playlist")
            }
        }
        .task(id: id) { await load() }
    }

    private func load() async {
        loading = true
        let name = detail?.name ?? library.playlists.first { $0.id == id }?.name
        // a 404: deleted, maybe on another device, or no longer shared with you. Closed, and gone from the list
        // (LibraryStore.loadPlaylist), instead of a screen saying so (handoff 3.3, 8 Oct)
        if !(await library.loadPlaylist(id)) {
            library.notify(name.map { "“\($0)” is no longer available" } ?? "That playlist is no longer available", symbol: "music.note.list")
            closed()
        }
        loading = false
    }

    private func songs(_ detail: PlaylistDetail) -> some View {
        let tracks = detail.tracks
        return List(selection: $selection) {
            header(detail, tracks)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .moveDisabled(true)

            // a viewer's rows: no Remove, no drag (the server would refuse both, 403)
            let canEdit = detail.summary.canEdit
            ForEach(Array(detail.items.enumerated()), id: \.element.itemID) { i, entry in
                SongRow(track: tracks[i], queue: tracks, index: i, keys: detail.keys, source: detail.queueSource,
                        removeLabel: "Remove from “\(detail.name)”", remove: canEdit ? {
                    Task { await library.remove(entry, from: detail.id) }
                } : nil, doubleClickPlays: false)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                .selfTestFrame("playlist.row:\(i)")
            }
            .onMove(perform: canEdit ? { from, to in Task { await library.moveItems(in: detail.id, from: from, to: to) } } : nil)

            if detail.items.isEmpty {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: canEdit ? Text("Right-click any song › Add to Playlist.") : nil)
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
        // a double-click plays the song: the list's own, because a double-click gesture on the rows stopped every drag
        // (SongRow.doubleClickPlays, 8 Oct). The rows keep their own right-click menus (an empty one here)
        .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
            guard let id = ids.first, let i = detail.items.firstIndex(where: { $0.itemID == id }) else { return }
            player.play(tracks, startAt: i, keys: detail.keys, source: detail.queueSource)
        }
        .scrollContentBackground(.hidden)
        .scrollTitle(detail.name)
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
                if let standing = Self.standing(detail.summary) {
                    Label(standing, systemImage: detail.summary.isOwner ? "globe" : "person.2.fill")
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                }
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
                        Button("Download Playlist") { Task { await downloads.download(all: tracks, name: detail.name) } }
                            .disabled(tracks.isEmpty)
                        Divider()
                        PlaylistRoleActions(playlist: detail.summary)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("More")
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    /// How it is shared, under its length: "Shared · Can make changes", or "Public" for your own; nil for your
    /// own private ones.
    static func standing(_ playlist: PlaylistSummary) -> String? {
        if playlist.isOwner { return playlist.isPublic ? "Public" : nil }
        return playlist.canEdit ? "Shared · Can make changes" : "Shared · View only"
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

/// "Add to Playlist" in a song's right-click menu: every playlist you may add to (yours, and those shared with you
/// as an editor), plus "New Playlist…" (created, then the song added).
struct AddToPlaylistMenu: View {
    let track: Track
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let editable = library.playlists.filter(\.canEdit)
        Menu("Add to Playlist") {
            Button("New Playlist…") { library.newPlaylistRequest = .init(track: track) }
            if !editable.isEmpty { Divider() }
            ForEach(editable) { playlist in
                Button(playlist.name) { Task { await library.add(track, to: playlist) } }
            }
        }
    }
}

/// A playlist's actions by your role on it (AUTH-3), in every menu that offers them (the sidebar, Home, the playlist
/// screen). The owner renames, shares, makes it public and deletes; someone it is shared with can leave. The server
/// refuses the rest (403): they are not offered, rather than offered and refused.
struct PlaylistRoleActions: View {
    let playlist: PlaylistSummary
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if playlist.isOwner {
            Button("Rename…") { library.renameRequest = playlist }
            Button("Share…") { library.shareRequest = playlist }
            Button(playlist.isPublic ? "Make Private" : "Make Public") {
                Task { await library.setPublic(playlist, !playlist.isPublic) }
            }
            Divider()
            Button("Delete…", role: .destructive) { library.deleteRequest = playlist }
        } else {
            Button("Leave…", role: .destructive) { library.leaveRequest = playlist }
        }
    }
}

/// Share a playlist: a username, and what they may do. Sharing again with the same person changes their role.
/// The server's reason shows under the field ("No account with that username"). Who it is shared with cannot be
/// listed yet: the server has no route for it (handoff 3.3).
struct SharePlaylistSheet: View {
    let playlist: PlaylistSummary
    /// username, role → nil: it worked (the sheet closes); otherwise why not.
    let submit: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var role = "viewer"
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Bool

    private var trimmed: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share “\(playlist.name)”").font(.title3.weight(.semibold))
            TextField("Username", text: $username, prompt: Text("Username"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit(go)
            Picker("Permission", selection: $role) {
                Text("View only").tag("viewer")
                Text("Can make changes").tag("editor")
            }
            .pickerStyle(.radioGroup)
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
                Button("Share") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 380)
        .animation(.snappy(duration: 0.25), value: problem)
        .onAppear { focused = true }
        .onChange(of: username) { problem = nil }
    }

    private func go() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        Task {
            problem = await submit(trimmed, role)
            working = false
            if problem == nil { dismiss() }
        }
    }
}
