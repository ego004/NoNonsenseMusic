import Foundation
import Observation

/// Liked songs and recently played, kept in sync with the server.
@Observable
final class LibraryStore {
    private(set) var liked: [Track] = []
    private(set) var recent: [Track] = []
    /// "source:id" of every listing of every liked song: a search result is liked
    /// if ANY of its listings is in here (search results have no song IDs yet).
    private(set) var likedKeys: Set<String> = []
    @ObservationIgnored private var songIDs: [String: UUID] = [:]      // listing key -> stored song id (no view reads it)

    func isLiked(_ track: Track) -> Bool { track.listings.contains { likedKeys.contains($0.key) } }

    /// The server's last answers, and the version (Settings › Playback) the tracks were built for. Observation counts
    /// every assignment as a change, equal or not: assigning the same lists after every song start redrew every row,
    /// heart, shelf and the sidebar (audit, 7 Oct). Now only what changed is assigned.
    @ObservationIgnored private var lastLiked: [LibrarySong]?
    @ObservationIgnored private var lastRecent: [LibrarySong]?
    @ObservationIgnored private var builtExplicit = Track.prefersExplicit

    func refresh() async {
        do {
            async let likedSongs = API.liked()
            async let recentSongs = API.recent()
            let (l, r) = try await (likedSongs, recentSongs)
            apply(liked: l, recent: r)
        } catch {
            // a failure keeps the last good lists; the connection banner (Connectivity) says when the server is gone
        }
        await refreshPlaylists()
    }

    /// After a song starts: only Recently Played can have changed. One request instead of three (liked, recent, playlists).
    func refreshRecent() async {
        guard let r = try? await API.recent() else { return }
        apply(liked: nil, recent: r)
    }

    /// nil: not asked this time, keep the last answer.
    private func apply(liked newLiked: [LibrarySong]?, recent newRecent: [LibrarySong]?) {
        let rebuild = Track.prefersExplicit != builtExplicit          // the other version plays now: every track again
        builtExplicit = Track.prefersExplicit
        var changed = false
        if let l = newLiked ?? lastLiked, rebuild || l != lastLiked {
            liked = l.map(Track.init)
            lastLiked = l
            changed = true
        }
        if let r = newRecent ?? lastRecent, rebuild || r != lastRecent {
            recent = r.map(Track.init)
            lastRecent = r
            changed = true
        }
        // the hearts follow the server's liked list (this also undoes an optimistic like the server refused), but only
        // when it was just asked: from the last answer, a ♥ tapped as a song starts would empty again for a moment
        if let l = newLiked {
            let keys = Set(l.flatMap { $0.listings.map(\.key) })
            if keys != likedKeys { likedKeys = keys }
        }
        guard changed else { return }
        songIDs = [:]
        for song in (lastLiked ?? []) + (lastRecent ?? []) { for listing in song.listings { songIDs[listing.key] = song.id } }
    }

    @ObservationIgnored private var messageTimer: Task<Void, Never>?

    /// A library problem shown above the player bar for 5 s.
    private(set) var message: String?
    /// The message's symbol: a warning for problems, a tick for "Added to …".
    private(set) var messageSymbol = "exclamationmark.triangle.fill"

    /// A message from elsewhere (downloads), on the same line above the player bar.
    func notify(_ text: String, symbol: String) { show(text, symbol: symbol) }

    private func show(_ text: String, symbol: String = "exclamationmark.triangle.fill") {
        message = text
        messageSymbol = symbol
        messageTimer?.cancel()
        messageTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { message = nil }
        }
    }

    func toggleLike(_ track: Track) async {
        let wasLiked = isLiked(track)
        // optimistic: the heart fills instantly, the server catches up
        if wasLiked { track.listings.forEach { likedKeys.remove($0.key) } }
        else { track.listings.forEach { likedKeys.insert($0.key) } }
        // one song's likes and unlikes take turns: an unlike sent while the like was still on its way had no song id
        // yet, so it never reached the server and the next refresh filled the heart again (audit, 7 Oct)
        let previous = likeTurns[track.id]
        let turn = Task { @MainActor in
            await previous?.value
            do {
                if wasLiked, let id = track.listings.lazy.compactMap({ self.songIDs[$0.key] }).first {
                    try await API.unlike(id)
                } else if !wasLiked {
                    let id = try await API.like(track.listings)
                    track.listings.forEach { self.songIDs[$0.key] = id }      // an unlike right after has its id
                }
            } catch {
                self.show(wasLiked ? "Couldn't unlike “\(track.title)”: \(error.localizedDescription)"
                                   : "Couldn't like “\(track.title)”: \(error.localizedDescription)")
            }
        }
        likeTurns[track.id] = turn
        await turn.value
        // only the last turn refreshes: an earlier one's refresh would undo the heart of a newer press for a moment
        guard likeTurns[track.id] == turn else { return }
        likeTurns[track.id] = nil
        await refresh()
    }
    @ObservationIgnored private var likeTurns: [String: Task<Void, Never>] = [:]

    // MARK: - playlists (MUS-2)

    private(set) var playlists: [PlaylistSummary] = []
    /// Each opened playlist's rows, as last loaded. Every change reloads the playlist it touched.
    private(set) var details: [UUID: PlaylistDetail] = [:]
    /// Asks RootView for the "New Playlist" sheet: from the sidebar's +, ⌘N, or a song's "Add to Playlist › New Playlist…".
    var newPlaylistRequest: NewPlaylistRequest?
    /// Ask RootView for the rename sheet, or the "Delete …?" question (from the sidebar or the playlist screen).
    var renameRequest: PlaylistSummary?
    var deleteRequest: PlaylistSummary?
    /// The Player sets this: a changed playlist reaches the playing queue when the queue came from it.
    @ObservationIgnored var playlistChanged: ((PlaylistDetail) -> Void)?

    struct NewPlaylistRequest: Identifiable {
        let id = UUID()
        let track: Track?          // a song to add once it exists
    }

    func refreshPlaylists() async {
        // a failure keeps the last good list; the same list is not assigned again (the sidebar and Home would redraw)
        if let fresh = try? await API.playlists(), fresh != playlists { playlists = fresh }
    }

    /// Loads one playlist's rows. False: it no longer exists (deleted, maybe on another device).
    @discardableResult
    func loadPlaylist(_ id: UUID) async -> Bool {
        let edits = localEdits[id, default: 0]
        do {
            let detail = try await API.playlist(id)
            // an edit made on screen while this was on its way (a drag just before a slow load landed) is newer than
            // this answer: keep the screen; the edit's own request brings the server along (audit, 7 Oct)
            guard localEdits[id, default: 0] == edits else { return true }
            if details[id] != detail { details[id] = detail }     // opening an unchanged playlist redraws nothing
            playlistChanged?(detail)
            return true
        } catch API.Failure.http(404, _) {
            details[id] = nil
            return false
        } catch {
            show("Couldn't open the playlist: \(error.localizedDescription)")
            return true
        }
    }

    /// nil when it worked; otherwise the reason, for the sheet to show under the name ("A playlist with this name already exists").
    func createPlaylist(named name: String, adding track: Track? = nil) async -> String? {
        do {
            let playlist = try await API.createPlaylist(named: name)
            await refreshPlaylists()
            if let track { await add(track, to: playlist) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func renamePlaylist(_ playlist: PlaylistSummary, to name: String) async -> String? {
        do {
            _ = try await API.renamePlaylist(playlist.id, to: name)
            await refreshPlaylists()
            if details[playlist.id] != nil { await loadPlaylist(playlist.id) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deletePlaylist(_ playlist: PlaylistSummary) async {
        do {
            try await API.deletePlaylist(playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            details[playlist.id] = nil
            show("Deleted “\(playlist.name)”", symbol: "trash")
        } catch {
            show("Couldn't delete “\(playlist.name)”: \(error.localizedDescription)")
        }
    }

    func add(_ track: Track, to playlist: PlaylistSummary) async {
        do {
            try await API.add(track.listings, to: playlist.id)
            show("Added to “\(playlist.name)”", symbol: "checkmark.circle.fill")
            await refreshPlaylists()
            await loadPlaylist(playlist.id)            // also brings the new song into the queue if this playlist is playing
        } catch {
            show("Couldn't add to “\(playlist.name)”: \(error.localizedDescription)")
        }
    }

    /// Takes the row out at once, then tells the server; a failure brings it back.
    func remove(_ entry: PlaylistEntry, from playlistID: UUID) async {
        if let detail = details[playlistID] {
            update(detail.with(items: detail.items.filter { $0.itemID != entry.itemID }))
        }
        do {
            try await API.remove(item: entry.itemID, from: playlistID)
        } catch {
            show("Couldn't remove “\(entry.song.title)”: \(error.localizedDescription)")
        }
        await loadPlaylist(playlistID)
        await refreshPlaylists()
    }

    /// A drag in the playlist screen. The rows move at once; the server gets the moved row's new neighbours
    /// (one row changes there). A failure reloads the server's order.
    func moveItems(in playlistID: UUID, from source: IndexSet, to destination: Int) async {
        guard let detail = details[playlistID], source.count == 1, let from = source.first else { return }
        let moved = detail.items[from].itemID
        var items = detail.items
        items.move(fromOffsets: source, toOffset: destination)
        guard let k = items.firstIndex(where: { $0.itemID == moved }), k != from else { return }
        update(detail.with(items: items))
        do {
            try await API.move(item: moved, in: playlistID,
                               top: k > 0 ? items[k - 1].itemID : nil,
                               bottom: k + 1 < items.count ? items[k + 1].itemID : nil)
        } catch {
            show("Couldn't move “\(detail.items[from].song.title)”: \(error.localizedDescription)")
            await loadPlaylist(playlistID)
        }
    }

    /// A drag in the sidebar's Playlists section: the same, for the order of your playlists.
    func movePlaylists(from source: IndexSet, to destination: Int) async {
        guard source.count == 1, let from = source.first else { return }
        let moved = playlists[from].id
        var order = playlists
        order.move(fromOffsets: source, toOffset: destination)
        guard let k = order.firstIndex(where: { $0.id == moved }), k != from else { return }
        playlists = order
        do {
            try await API.move(playlist: moved, top: k > 0 ? order[k - 1].id : nil,
                               bottom: k + 1 < order.count ? order[k + 1].id : nil)
        } catch {
            show("Couldn't move the playlist: \(error.localizedDescription)")
            await refreshPlaylists()
        }
    }

    private func update(_ detail: PlaylistDetail) {
        localEdits[detail.id, default: 0] += 1
        details[detail.id] = detail
        playlistChanged?(detail)
    }
    /// Edits made on screen per playlist, so a load that left before one cannot undo it (`loadPlaylist`).
    @ObservationIgnored private var localEdits: [UUID: Int] = [:]
}
