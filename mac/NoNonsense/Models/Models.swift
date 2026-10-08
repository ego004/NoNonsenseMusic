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
    /// The explicit version (MUS-19); nil: not known (listings stored before 7 Oct, until they are seen again)
    var explicit: Bool? = nil

    /// Unique across sources: the same id string could exist on two sources.
    var key: String { "\(source):\(id)" }

    /// Every field, a missing one as null. Swift's own encoder leaves nil fields out, and the server's model needs
    /// `album` and `popularity` present even when empty: it answered 422 "Field required" and dropped 44 of 119
    /// play events and 5 likes before this (5 Oct).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artists, forKey: .artists)
        try c.encode(album, forKey: .album)              // nil -> null
        try c.encode(duration, forKey: .duration)
        try c.encode(popularity, forKey: .popularity)    // nil -> null
        try c.encode(image, forKey: .image)
        try c.encode(explicit, forKey: .explicit)        // nil -> null
    }
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

/// Equatable: LibraryStore skips a refresh that brought nothing new (every assignment redraws its readers).
nonisolated struct LibrarySong: Codable, Sendable, Equatable {
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

// ---- lyrics (MUS-12): what POST /lyrics answers ----

nonisolated struct LyricLine: Codable, Hashable, Sendable {
    let startMs: Int?            // nil: plain lyrics, no times. A line lasts until the next one starts
    let text: String             // "" is a gap (an instrumental break): nothing is being sung

    enum CodingKeys: String, CodingKey { case startMs = "start_ms", text }
}

nonisolated struct Lyrics: Codable, Hashable, Sendable {
    let lyricsSource: String?    // "lrclib" | "ytmusic"; nil: nobody had lyrics (lines is empty)
    let synced: Bool
    let lines: [LyricLine]

    enum CodingKeys: String, CodingKey { case lyricsSource = "lyrics_source", synced, lines }

    /// The line being sung at `seconds`: the last one that has started. nil before the first line, or when
    /// the lyrics are not timed. Lines come sorted by time from the server.
    func line(at seconds: Double) -> Int? {
        guard synced else { return nil }
        let ms = Int(seconds * 1000)
        var low = 0, high = lines.count                  // binary search: the first line that starts after `ms`
        while low < high {
            let mid = (low + high) / 2
            if (lines[mid].startMs ?? 0) <= ms { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    var sourceName: String? {
        switch lyricsSource { case "lrclib": "LRCLIB"; case "ytmusic": "YouTube Music"; default: nil }
    }
}

// ---- playlists (MUS-2). Server names in brackets: these decode exactly what the backend sends ----

/// One playlist without its songs: the sidebar, the list, the header [PlaylistMetadata].
/// Someone on a playlist (GET /playlists/{id}/members): its owner, or someone it is shared with.
nonisolated struct PlaylistMember: Decodable, Hashable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    let role: String                  // "owner", "editor" or "viewer"
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case username, role; case userID = "user_id" }

    /// As the share sheet's picker says it.
    var roleName: String { role == "owner" ? "Owner" : role == "editor" ? "Can make changes" : "View only" }
}

nonisolated struct PlaylistSummary: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let songCount: Int
    let duration: Int                 // seconds, every song added up
    let thumbnail: String?            // an uploaded cover's URL; nil: the app draws a 2×2 grid
    var isPublic = false              // anyone signed in can open it by its id (AUTH-3)
    /// Yours: "owner". Shared with you: "editor" (add, remove, reorder songs) or "viewer" (look and play).
    var role = "owner"
    enum CodingKeys: String, CodingKey { case id, name, duration, thumbnail, role; case songCount = "song_count"; case isPublic = "public" }

    var isOwner: Bool { role == "owner" }
    /// May change its songs: the owner or an editor. The server refuses the rest (403); the app does not offer it.
    var canEdit: Bool { role != "viewer" }
}

// ---- accounts (AUTH-1) ----

/// Who is signed in [User].
nonisolated struct AccountUser: Codable, Sendable, Equatable {
    let id: UUID
    let username: String
}

/// POST /auth/signup and /auth/signin [Session]: the only time the server sends the token itself.
nonisolated struct SessionReply: Codable, Sendable {
    let token: String
    let user: AccountUser
}

/// GET /playlists [PlaylistsResponse]
nonisolated struct PlaylistsResponse: Codable, Sendable { let playlists: [PlaylistSummary] }

/// One row of a playlist [PlaylistItem]: its own id (a song added twice is two rows) and the song.
nonisolated struct PlaylistEntry: Codable, Sendable, Equatable {
    let itemID: UUID
    let song: LibrarySong
    enum CodingKeys: String, CodingKey { case itemID = "item_id"; case song }
}

/// GET /playlists/{id}: the playlist and its rows, in your order [PlaylistItems].
nonisolated struct PlaylistDetail: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let songCount: Int
    let duration: Int
    let thumbnail: String?
    var isPublic = false
    var role = "owner"
    let items: [PlaylistEntry]
    enum CodingKeys: String, CodingKey { case id, name, duration, thumbnail, items, role; case songCount = "song_count"; case isPublic = "public" }

    var summary: PlaylistSummary {
        PlaylistSummary(id: id, name: name, songCount: songCount, duration: duration, thumbnail: thumbnail, isPublic: isPublic, role: role)
    }
    @MainActor var tracks: [Track] { items.map { Track($0.song) } }
    /// The rows' item ids as the player's queue keys: edits to this playlist find their entries by these.
    var keys: [String] { items.map { $0.itemID.uuidString } }
    /// The player's name for a queue that came from this playlist.
    var queueSource: String { "playlist:\(id.uuidString)" }

    /// The same playlist with these rows (after a move or a remove, before the server answers).
    func with(items: [PlaylistEntry]) -> PlaylistDetail {
        PlaylistDetail(id: id, name: name, songCount: items.count, duration: items.reduce(0) { $0 + $1.song.duration },
                       thumbnail: thumbnail, isPublic: isPublic, role: role, items: items)
    }
}

/// POST /playlists/{id}/items [PlaylistItemRef]
nonisolated struct PlaylistItemRef: Codable, Sendable {
    let itemID: UUID
    let songID: UUID
    enum CodingKeys: String, CodingKey { case itemID = "item_id"; case songID = "song_id" }
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

    /// `choosingVersion: false`: `serverBest` plays as given (a copy you picked yourself), whatever Settings › Playback says.
    init(best serverBest: Listing, listings: [Listing], choosingVersion: Bool = true) {
        // your version (Settings › Playback): when a song has both, the explicit or the clean one plays and is shown.
        // The server picks by source and popularity, which chose the clean Les (7 Oct)
        let wantExplicit = Track.prefersExplicit
        let inOrder = [serverBest] + listings.sorted {           // the server's pick, then its source, then most played
            ($0.source == serverBest.source ? 0 : 1, -($0.popularity ?? 0)) < ($1.source == serverBest.source ? 0 : 1, -($1.popularity ?? 0))
        }
        let best = choosingVersion ? (inOrder.first { $0.explicit == wantExplicit } ?? serverBest) : serverBest
        self.id = best.key
        self.title = best.title
        self.artists = best.artists
        self.duration = best.duration
        self.image = best.image.flatMap(URL.init(string:))
        self.best = best
        // the default copy first, then copies from the same source, then the rest, most popular first.
        // The listings list shows this order, and a failed copy falls back in this order.
        let others = listings.filter { $0.key != best.key }.sorted {
            ($0.source == best.source ? 0 : 1, -($0.popularity ?? 0)) < ($1.source == best.source ? 0 : 1, -($1.popularity ?? 0))
        }
        self.listings = [best] + others
    }

    /// Settings › Playback › Version: true (the default) plays a song's explicit version when it has one.
    static var prefersExplicit: Bool { (UserDefaults.standard.string(forKey: "versionPreference") ?? "explicit") == "explicit" }

    var isExplicit: Bool { best.explicit == true }

    init(_ song: SearchSong) { self.init(best: song.best, listings: song.listings) }
    init(_ song: LibrarySong) { self.init(best: song.best, listings: song.listings) }

    /// The same song, but playing one specific copy (chosen from its listings). Exactly that copy: re-choosing the
    /// version here turned a click on the clean copy into the explicit one (audit, 7 Oct).
    func playing(_ listing: Listing) -> Track { Track(best: listing, listings: listings, choosingVersion: false) }

    /// Same song, whichever copy plays: the same set of listings. Every visible row asks this on every change of the
    /// queue, so the usual answers come first: the same copy (one listing belongs to one song), or a different count.
    func isSameSong(as other: Track) -> Bool {
        if id == other.id { return true }
        guard listings.count == other.listings.count else { return false }
        return Set(listings.map(\.key)) == Set(other.listings.map(\.key))
    }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// ---- Genius notes (experimental, 8 Oct): POST /genius. Notes only, never Genius's lyrics ----

nonisolated struct GeniusNote: Codable, Hashable, Sendable {
    let fragment: String         // the song's words it is about, as Genius quotes them
    let text: String
    let verified: Bool           // written or confirmed by the artist
}

nonisolated struct GeniusAbout: Codable, Hashable, Sendable {
    let description: String?
    let producedBy: [String]
    let samples: [String]
    enum CodingKeys: String, CodingKey { case description, samples; case producedBy = "produced_by" }

    var isEmpty: Bool { description == nil && producedBy.isEmpty && samples.isEmpty }
}

nonisolated struct GeniusNotes: Codable, Hashable, Sendable {
    let url: String?             // the song's page on Genius (the credit); nil: Genius has no such song
    let notes: [GeniusNote]
    let about: GeniusAbout?

    /// Which lyric line each note is about: a line whose words are in the note's fragment, or that holds a line of
    /// the fragment, case, accents and punctuation ignored. Short pieces (under 8 letters: "oh oh") match nothing,
    /// so a note never lands on every chorus line by chance. A line takes the first note that fits it.
    func byLine(_ lines: [LyricLine]) -> [Int: GeniusNote] {
        var found: [Int: GeniusNote] = [:]
        let plainLines = lines.map { Self.plain($0.text) }
        for note in notes {
            let whole = Self.plain(note.fragment)
            let pieces = note.fragment.split(whereSeparator: \.isNewline).map { Self.plain(String($0)) }.filter { $0.count >= 8 }
            for (i, line) in plainLines.enumerated() where found[i] == nil && line.count >= 8 {
                if whole.contains(line) || pieces.contains(where: { line.contains($0) }) { found[i] = note }
            }
        }
        return found
    }

    /// Lowercase letters and digits, single spaces: "Don't—stop!" and "dont stop" read the same.
    static func plain(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")   // don't, don’t: dont
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
