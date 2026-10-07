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
    private var songIDs: [String: UUID] = [:]      // listing key -> stored song id
    private(set) var lastError: String?

    func isLiked(_ track: Track) -> Bool { track.listings.contains { likedKeys.contains($0.key) } }

    func refresh() async {
        do {
            async let likedSongs = API.liked()
            async let recentSongs = API.recent()
            let (l, r) = try await (likedSongs, recentSongs)
            liked = l.map(Track.init)
            recent = r.map(Track.init)
            likedKeys = Set(l.flatMap { $0.listings.map(\.key) })
            songIDs = [:]
            for song in l + r { for listing in song.listings { songIDs[listing.key] = song.id } }
            lastError = nil
        } catch {
            lastError = "Can't reach the server at \(API.baseURL.absoluteString)."
        }
        await refreshPlaylists()
    }

    @ObservationIgnored private var messageTimer: Task<Void, Never>?

    /// A library problem shown above the player bar for 5 s. Its own field: `refresh()` clears `lastError`
    /// when it succeeds, which would wipe this message the moment it appeared.
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
        do {
            if wasLiked, let id = track.listings.lazy.compactMap({ self.songIDs[$0.key] }).first {
                try await API.unlike(id)
            } else if !wasLiked {
                try await API.like(track.listings)
            }
        } catch {
            show(wasLiked ? "Couldn't unlike “\(track.title)”: \(error.localizedDescription)"
                          : "Couldn't like “\(track.title)”: \(error.localizedDescription)")
        }
        await refresh()
    }

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
        if let fresh = try? await API.playlists() { playlists = fresh }      // a failure keeps the last good list
    }

    /// Loads one playlist's rows. False: it no longer exists (deleted, maybe on another device).
    @discardableResult
    func loadPlaylist(_ id: UUID) async -> Bool {
        do {
            let detail = try await API.playlist(id)
            details[id] = detail
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
        details[detail.id] = detail
        playlistChanged?(detail)
    }
}
