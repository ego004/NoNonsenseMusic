import SwiftUI

/// One playlist: its cover, name and length, Play and Shuffle, and its songs. Drag a song to move it; right-click
/// to remove it. Everything goes through LibraryStore, which also keeps a playing copy of this playlist in step.
struct PlaylistView: View {
    @AppStorage(AppLook.key) private var look = AppLook.standard          // Classic: no label over the title
    let id: UUID
    /// It is gone (deleted, or no longer shared with you): RootView closes it.
    var closed: () -> Void = {}
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @State private var loading = true
    @State private var selection: Set<UUID> = []
    @State private var filter = ""

    private var detail: PlaylistDetail? { library.details[id] }

    var body: some View {
        Group {
            if let detail {
                songs(detail)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .fixedTitle(library.playlists.first { $0.id == id }?.name ?? "Playlist")
            } else {
                // the server could not be asked (it spun forever, audit 7 Oct): say so, and offer to ask again
                ContentUnavailableView {
                    Label("Couldn't load this playlist", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Is the server running?")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .fixedTitle(library.playlists.first { $0.id == id }?.name ?? "Playlist")
            }
        }
        .task(id: id) { await load() }
        // gone from your list while open (unpinned, deleted on another device, or the owner removed you): back out,
        // instead of an error screen for a playlist that no longer exists
        .onChange(of: library.playlists.contains { $0.id == id }) { was, now in if was && !now { closed() } }
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
        let keys = detail.keys                  // once: each row, the animation and the tick read it (#12: per row before)
        return List(selection: $selection) {
            header(detail, tracks)
                .pageRow(top: 0, bottom: 0)
                .moveDisabled(true)

            // a viewer's rows: no Remove, no drag (the server would refuse both, 403)
            let canEdit = detail.summary.canEdit
            // a pinned album's rows are numbered, as on its album page (15 Oct, as in the Windows app); not while
            // Search hides some of them
            let numbered = detail.summary.isAlbum && filter.isEmpty
            // Search narrows the rows: playing one plays what is shown (as its own queue, not kept in step with the
            // playlist, which would bring the hidden songs back); no dragging while some songs are hidden
            let shown = Array(detail.items.indices).filter { filter.isEmpty || songMatches(tracks[$0], filter) }
            let shownTracks = shown.map { tracks[$0] }
            ForEach(Array(shown.enumerated()), id: \.element) { row, i in
                let entry = detail.items[i]
                SongRow(track: tracks[i], queue: filter.isEmpty ? tracks : shownTracks, index: filter.isEmpty ? i : row,
                        number: numbered ? i + 1 : nil,
                        keys: filter.isEmpty ? keys : nil, source: filter.isEmpty ? detail.queueSource : nil,
                        removeLabel: "Remove from “\(detail.name)”", remove: canEdit ? {
                    Task { await library.remove(entry, from: detail.id) }
                } : nil, doubleClickPlays: false)
                .selfTestFrame("playlist.row:\(i)")
                .pageRow(top: 1, bottom: 1, inset: 24)
            }
            .onMove(perform: canEdit && filter.isEmpty ? { from, to in Task { await library.moveItems(in: detail.id, from: from, to: to) } } : nil)

            if !detail.items.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: filter).frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }

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
            player.play(tracks, startAt: i, keys: keys, source: detail.queueSource)
        }
        .scrollContentBackground(.hidden)
        .scrollTitle(detail.name)
        .selfTestFrame("playlist.page")
        .animation(.snappy(duration: 0.3), value: keys)          // rows slide when one is removed or added
        .sensoryFeedback(.levelChange, trigger: keys)            // a light tick as the order changes (Force Touch trackpads)
    }

    private func header(_ detail: PlaylistDetail, _ tracks: [Track]) -> some View {
        // as the Windows app's (15 Oct): a bigger cover, and a pinned album called one
        HStack(alignment: .bottom, spacing: 28) {
            PlaylistCover(images: PlaylistCover.images(of: tracks.lazy.map(\.image)), size: 200, seed: detail.name)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .selfTestFrame("playlist.cover")
            VStack(alignment: .leading, spacing: 4) {
                if look == .new {
                    Text(detail.summary.isAlbum ? "Album" : "Playlist")
                        .textStyle(.caption, weight: .semibold).textCase(.uppercase).foregroundStyle(.secondary)
                }
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
                    .compatGlassButton(prominent: true)
                    .disabled(tracks.isEmpty)
                    Button { player.shufflePlay(tracks, keys: detail.keys, source: detail.queueSource) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .compatGlassButton()
                    .disabled(tracks.isEmpty)
                    DownloadAllButton(tracks: tracks, name: detail.name)
                    if detail.summary.canEdit { ImportIntoPlaylistButton(playlist: detail.id) }
                    if !tracks.isEmpty { FilterField(text: $filter) }
                    Menu {
                        PlaylistRoleActions(playlist: detail.summary)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .compatGlassButton()
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
    /// The first four different covers, read lazily: a long playlist stops at its fourth cover.
    static func images(of covers: some Sequence<URL?>) -> [URL] {
        var seen = Set<URL>()
        return Array(covers.lazy.compactMap { $0 }.filter { seen.insert($0).inserted }.prefix(4))
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
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { [reduceMotion] field, x in
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

/// A song's library actions, the same wherever a song is offered (a row, a cover, Up Next, the playing song's "…"):
/// like, add to a playlist, download, and a downloaded song's file in the Finder. The download entries only while a
/// downloads folder is in use (not while its drive is unplugged).
struct SongLibraryActions: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        Button(library.isLiked(track) ? "Remove from Liked" : "Like") { Task { await library.toggleLike(track) } }
        AddToPlaylistMenu(track: track)
        if downloads.available {
            if downloads.isDownloading(track) {
                Button("Downloading…") {}.disabled(true)
            } else if downloads.isDownloaded(track) {
                Button("Remove Download") { downloads.remove(track) }
                Button("Show in Finder") { downloads.revealInFinder(track) }
            } else {
                Button("Download") { Task { await downloads.download(track) } }
            }
        }
    }
}

/// "…" beside the playing song's heart (the player bar, Now Playing): its library actions, as a row's right-click has.
struct SongActionsButton: View {
    let track: Track
    var font: Font = .body

    var body: some View {
        Menu { SongLibraryActions(track: track) } label: { Image(systemName: "ellipsis.circle").font(font) }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("More: Add to Playlist, Download")
            .accessibilityLabel("More")
    }
}

/// A playlist's actions by your role on it (AUTH-3), in every menu that offers them (the sidebar, Home, the playlist
/// screen). The owner renames, shares, makes it public and deletes; someone it is shared with can leave. The server
/// refuses the rest (403): they are not offered, rather than offered and refused.
struct PlaylistRoleActions: View {
    let playlist: PlaylistSummary
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if playlist.isAlbum {
            // a pinned album: a copy of the source's album, so nothing to rename or share
            if let source = playlist.source, let id = playlist.sourceID {
                Button("Go to Album") {
                    Navigator.shared.open(.album(AlbumRef(source: source, id: id, title: playlist.name, artists: [],
                                                          year: nil, image: nil, songCount: playlist.songCount)))
                }
            }
            Divider()
            Button("Unpin from Home", role: .destructive) { Task { await library.unpin(playlist) } }
        } else if playlist.isOwner {
            Button("Rename…") { library.renameRequest = playlist }
            Button("Share…") { library.shareRequest = playlist }
            Button(playlist.isPublic ? "Make Private" : "Make Public") {
                Task { await library.setPublic(playlist, !playlist.isPublic) }
            }
            Divider()
            Button("Delete…", role: .destructive) { library.deleteRequest = playlist }
        } else {
            Button("People…") { library.shareRequest = playlist }       // the same sheet, to look at (AUTH-3)
            Button("Leave…", role: .destructive) { library.leaveRequest = playlist }
        }
    }
}

/// Who is on a playlist, and (its owner) inviting someone: a username and what they may do. Sharing again with the
/// same person changes their role; the owner removes people from the list. Someone it is shared with sees the list
/// only. The sheet stays open after an invite, so the new person shows in the list; Done closes it (8 Oct).
struct SharePlaylistSheet: View {
    let playlist: PlaylistSummary
    /// username, role → nil: it worked; otherwise why not.
    let submit: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var members: [PlaylistMember] = []
    @State private var copied = false
    @State private var username = ""
    @State private var role = "viewer"
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Bool

    private var trimmed: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(playlist.isOwner ? "Share “\(playlist.name)”" : "People on “\(playlist.name)”").font(.title3.weight(.semibold))
                Spacer()
                // the web address: anyone it is shared with, or anyone at all when it is public, can open it
                Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PlaylistLink.web(playlist.id).absoluteString, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderless)
            }
            if !members.isEmpty {
                VStack(spacing: 0) {
                    ForEach(members) { member in
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            Text(member.username)
                            Spacer()
                            Text(member.roleName).foregroundStyle(.secondary)
                            if playlist.isOwner, member.role != "owner" {
                                Button { remove(member) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove \(member.username)")
                            }
                        }
                        .padding(.vertical, 6)
                        if member.id != members.last?.id { Divider() }
                    }
                }
            }
            if playlist.isOwner {
                TextField("Username", text: $username, prompt: Text("Username"))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(go)
                // friends not on the playlist yet: a click fills the name, Share adds them with the permission below
                let suggestions = Social.shared.friends.filter { friend in !members.contains { $0.username == friend.username } }
                if !suggestions.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions) { friend in
                            Button { username = friend.username } label: {
                                HStack(spacing: 6) {
                                    Avatar(name: friend.username, size: 18)
                                    Text(friend.username).textStyle(.callout)
                                }
                                .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                                .background(.primary.opacity(username == friend.username ? 0.14 : 0.06), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .help("Share with \(friend.username)")
                        }
                    }
                }
                Picker("Permission", selection: $role) {
                    Text("View only").tag("viewer")
                    Text("Can make changes").tag("editor")
                }
                .pickerStyle(.radioGroup)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                Button("Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if playlist.isOwner {
                    Button("Share") { go() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty || working)
                }
            }
        }
        .padding(22)
        .frame(width: 380)
        .animation(.snappy(duration: 0.25), value: problem)
        .animation(.snappy(duration: 0.25), value: members)
        .task { await loadMembers() }
        .onAppear { focused = playlist.isOwner }
        .onChange(of: username) { problem = nil }
    }

    private func loadMembers() async {
        if let found = try? await API.members(of: playlist.id) { members = found }
    }

    private func go() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        Task {
            problem = await submit(trimmed, role)
            working = false
            if problem == nil {
                username = ""
                await loadMembers()
            }
        }
    }

    private func remove(_ member: PlaylistMember) {
        Task {
            do {
                try await API.removeMember(member.userID, from: playlist.id)
                await loadMembers()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}


/// A playlist's Import: songs from Spotify or YouTube files, or from a YouTube playlist link, added to this playlist.
private struct ImportIntoPlaylistButton: View {
    let playlist: UUID
    @Environment(LibraryStore.self) private var library
    @State private var choosingFiles = false
    @State private var askingLink = false
    @State private var link = ""
    private var importer: SpotifyImporter { .shared }

    /// "Import", or how far the import has got: "Importing 20 of 112…" ("Importing…" until the server first answers)
    private var progress: String {
        guard importer.running else { return "Import" }
        guard let s = importer.status, s.total > 0 else { return "Importing…" }
        return "Importing \(s.done) of \(s.total)…"
    }

    var body: some View {
        Menu {
            Button("Songs from Files…") { choosingFiles = true }
            Button("Songs from a YouTube Playlist…") { askingLink = true }
        } label: {
            Label(progress, systemImage: "square.and.arrow.down")
        }
        .menuIndicator(.hidden)
        .compatGlassButton()
        .fixedSize()
        .disabled(importer.running)
        .help("Add songs from Spotify (Exportify, Spotify's data download) or YouTube (Google Takeout, a playlist link)")
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.commaSeparatedText, .json], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
            importer.start(urls, into: playlist, library: library)
            opened.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        .alert("Import a YouTube Playlist", isPresented: $askingLink) {
            TextField("music.youtube.com/playlist?list=…", text: $link)
            Button("Import") { importer.start(link: link, into: playlist, library: library); link = "" }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { link = "" }
        } message: {
            Text("A public or unlisted playlist from YouTube or YouTube Music. Its songs are added to this playlist.")
        }
    }
}
