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
    }

    @ObservationIgnored private var messageTimer: Task<Void, Never>?

    /// A library problem shown above the player bar for 5 s. Its own field: `refresh()` clears `lastError`
    /// when it succeeds, which would wipe this message the moment it appeared.
    private(set) var message: String?

    private func show(_ text: String) {
        message = text
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
}
