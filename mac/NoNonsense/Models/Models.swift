import Foundation

// Mirrors of the backend's JSON. `nonisolated` because decoding can happen off the main thread.

nonisolated struct Listing: Codable, Hashable, Sendable {
    let source: String          // "jiosaavn" | "ytmusic"
    let id: String
    let title: String
    let artists: [String]
    let album: String?
    let duration: Int
    let popularity: Int?
    let image: String?

    /// Unique across sources: the same id string could exist on two sources.
    var key: String { "\(source):\(id)" }
    var sourceName: String { source == "jiosaavn" ? "JioSaavn" : "YouTube Music" }
    var quality: String { source == "jiosaavn" ? "AAC 320 kbps" : "AAC 128 kbps" }
}

nonisolated struct SearchSong: Codable, Sendable {
    let title: String
    let artists: [String]?
    let duration: Int
    let score: Double
    let best: Listing
    let listings: [Listing]
}

nonisolated struct SourceInfo: Codable, Sendable {
    let source: String
    let healthy: Bool
    let numResults: Int
    let ms: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case source, healthy, ms, error
        case numResults = "num_results"
    }
}

nonisolated struct SearchResponse: Codable, Sendable {
    let query: String
    let sources: [SourceInfo]
    let songs: [SearchSong]
}

nonisolated struct LibrarySong: Codable, Sendable {
    let id: UUID
    let title: String
    let artists: [String]
    let duration: Int
    let best: Listing
    let listings: [Listing]
    let liked: Bool
    let at: String?
}

nonisolated struct SongRef: Codable, Sendable {
    let songID: UUID
    enum CodingKeys: String, CodingKey { case songID = "song_id" }
}

/// What every screen and the player work with, whether it came from a search or the library.
struct Track: Identifiable, Hashable {
    let id: String               // the best listing's key: stable for a session
    let title: String
    let artists: [String]
    let duration: Int
    let image: URL?
    let best: Listing            // the copy to play (the server's pick_best)
    let listings: [Listing]      // every copy: fallbacks, "N versions"

    var artistLine: String { artists.joined(separator: ", ") }

    init(best: Listing, listings: [Listing]) {
        self.id = best.key
        self.title = best.title
        self.artists = best.artists
        self.duration = best.duration
        self.image = best.image.flatMap(URL.init(string:))
        self.best = best
        self.listings = listings.isEmpty ? [best] : listings
    }

    init(_ song: SearchSong) { self.init(best: song.best, listings: song.listings) }
    init(_ song: LibrarySong) { self.init(best: song.best, listings: song.listings) }

    /// The same song, but playing one specific copy (chosen from its listings).
    func playing(_ listing: Listing) -> Track { Track(best: listing, listings: listings) }

    /// Same song, whichever copy plays: the same set of listings.
    func isSameSong(as other: Track) -> Bool { Set(listings.map(\.key)) == Set(other.listings.map(\.key)) }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}
