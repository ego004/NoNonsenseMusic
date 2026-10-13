import Foundation
import Observation

/// Bring a library in from Spotify or YouTube. The files are read here, on this Mac; only each song's title, artists and
/// length (or its YouTube video id) go to the server, which finds each song on its sources in the background (POST
/// /import) and is asked how far it has got. Files: Exportify's CSV (one per playlist, "Liked Songs" among them),
/// Spotify's own data export (YourLibrary.json, Playlist1.json…), a Google Takeout CSV (a "Video ID" column). A YouTube
/// playlist link is read by the server. Everything goes to Liked Songs, new playlists, or one playlist you chose.
struct SpotifyImportSong: Codable, Sendable {
    var title: String = ""
    var artists: [String] = []
    var durationMs: Int? = nil
    var youtubeID: String? = nil
    enum CodingKeys: String, CodingKey { case title, artists; case durationMs = "duration_ms"; case youtubeID = "youtube_id" }
}

struct SpotifyImportGroup: Codable, Sendable {
    /// nil, with no playlist: Liked Songs. Otherwise a new playlist of this name.
    var name: String? = nil
    /// An existing playlist to add to (its Import…): the name is not used.
    var playlistID: UUID? = nil
    /// A YouTube or YouTube Music playlist link, read by the server.
    var youtubePlaylist: String? = nil
    var songs: [SpotifyImportSong] = []
    enum CodingKeys: String, CodingKey { case name, songs; case playlistID = "playlist_id"; case youtubePlaylist = "youtube_playlist" }
}

nonisolated struct SpotifyImportStatus: Decodable, Sendable {
    let id: UUID
    let total: Int
    let done: Int
    let added: Int
    let missing: [String]
    let finished: Bool
    let failed: String?
}

extension API {
    private struct ImportBody: Encodable { let groups: [SpotifyImportGroup] }

    static func startSpotifyImport(_ groups: [SpotifyImportGroup]) async throws -> SpotifyImportStatus {
        try await send("POST", path: "import", body: ImportBody(groups: groups))
    }

    static func spotifyImportStatus(_ id: UUID) async throws -> SpotifyImportStatus {
        try await get(baseURL.appending(path: "import/\(id.uuidString.lowercased())"))
    }
}

// MARK: - reading Spotify's files

enum SpotifyFile {
    struct Unreadable: LocalizedError {
        let file: String
        var errorDescription: String? { "“\(file)” is not a file from Exportify, Spotify's data download or Google Takeout." }
    }

    /// The lists in these files, in the order picked. A list named like Liked Songs goes to your liked songs.
    static func groups(in urls: [URL]) throws -> [SpotifyImportGroup] {
        try urls.flatMap { url in
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let groups = url.pathExtension.lowercased() == "csv" ? exportify(data, name: name) : try json(data)
            guard let groups, !groups.isEmpty else { throw Unreadable(file: url.lastPathComponent) }
            return groups
        }
    }

    /// A CSV: Exportify's (a header row naming "Track Name", "Artist Name(s)", "Duration (ms)") or Google Takeout's (a
    /// "Video ID" column; "Song Title" and "Artist Name 1" in the music library's file). One row per song.
    private static func exportify(_ data: Data, name: String) -> [SpotifyImportGroup]? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }    // a byte-order mark would hide the first column's name
        let rows = csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
        let column = { (names: [String]) in header.firstIndex { h in names.contains { h.hasPrefix($0) } } }
        let title = column(["Track Name", "Song Title", "Title"]), artists = column(["Artist Name"])
        let video = column(["Video ID", "Video Id"]), duration = column(["Duration"])
        guard video != nil || (title != nil && artists != nil) else { return nil }
        let songs = rows.dropFirst().compactMap { row -> SpotifyImportSong? in
            func cell(_ i: Int?) -> String? { i.flatMap { row.indices.contains($0) ? row[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 } }
            let id = cell(video).flatMap { $0.count == 11 ? $0 : nil }
            guard id != nil || cell(title) != nil else { return nil }
            // Exportify separates artists with ";" and a name may hold a comma ("Tyler, The Creator"): never split on ","
            let named = cell(artists).map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
            return SpotifyImportSong(title: cell(title) ?? "", artists: named,
                                     durationMs: cell(duration).flatMap { Int($0) }, youtubeID: id)
        }
        var plain = name.replacingOccurrences(of: "_", with: " ")
        if plain.hasSuffix("-videos") { plain.removeLast("-videos".count) }   // Takeout: "<playlist>-videos.csv"
        return [SpotifyImportGroup(name: plain.lowercased().contains("liked") ? nil : plain, songs: songs)]
    }

    /// Spotify's data download: YourLibrary.json ({"tracks": [{"track", "artist"}]}) or a playlists file
    /// ({"playlists": [{"name", "items": [{"track": {"trackName", "artistName"}}]}]}). Neither says a song's length.
    private static func json(_ data: Data) throws -> [SpotifyImportGroup]? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tracks = root["tracks"] as? [[String: Any]] {
            let songs = tracks.compactMap { t -> SpotifyImportSong? in
                guard let title = t["track"] as? String, !title.isEmpty else { return nil }
                return SpotifyImportSong(title: title, artists: [t["artist"] as? String].compactMap { $0 }, durationMs: nil)
            }
            return [SpotifyImportGroup(name: nil, songs: songs)]
        }
        if let playlists = root["playlists"] as? [[String: Any]] {
            return playlists.compactMap { p -> SpotifyImportGroup? in
                guard let name = p["name"] as? String, !name.isEmpty else { return nil }
                let songs = (p["items"] as? [[String: Any]] ?? []).compactMap { item -> SpotifyImportSong? in
                    guard let t = item["track"] as? [String: Any], let title = t["trackName"] as? String, !title.isEmpty
                    else { return nil }                                   // podcast episodes and local files: skipped
                    return SpotifyImportSong(title: title, artists: [t["artistName"] as? String].compactMap { $0 }, durationMs: nil)
                }
                return songs.isEmpty ? nil : SpotifyImportGroup(name: name, songs: songs)
            }
        }
        return nil
    }

    /// RFC 4180: fields split by commas, a quoted field may hold commas, line breaks and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

// MARK: - the import

@MainActor @Observable
final class SpotifyImporter {
    static let shared = SpotifyImporter()

    /// The running or last import, as the server last reported it.
    private(set) var status: SpotifyImportStatus?
    private(set) var problem: String?
    /// Between pressing Import and the server's first answer: running already (a second press would only get 409)
    private var starting = false
    var running: Bool { starting || status.map { !$0.finished } ?? false }

    /// Imports these files: to Liked Songs and new playlists, or all of them into `playlist`.
    func start(_ urls: [URL], into playlist: UUID? = nil, library: LibraryStore) {
        problem = nil
        var groups: [SpotifyImportGroup]
        do {
            groups = try SpotifyFile.groups(in: urls)
        } catch {
            problem = error.localizedDescription
            library.notify(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            return
        }
        if let playlist { groups = groups.map { var g = $0; g.playlistID = playlist; return g } }
        run(groups, library: library)
    }

    /// Imports a YouTube or YouTube Music playlist link: to a new playlist named after it, or into `playlist`.
    func start(link: String, into playlist: UUID? = nil, library: LibraryStore) {
        problem = nil
        run([SpotifyImportGroup(playlistID: playlist, youtubePlaylist: link.trimmingCharacters(in: .whitespacesAndNewlines))],
            library: library)
    }

    private func run(_ groups: [SpotifyImportGroup], library: LibraryStore) {
        // the last import's result goes at once: shown until the server answered, it read as this import's (12 Oct)
        status = nil
        starting = true
        library.notify("Importing…", symbol: "square.and.arrow.down")
        Task {
            do {
                status = try await API.startSpotifyImport(groups)
                starting = false
            } catch {
                starting = false
                problem = error.localizedDescription
                library.notify("Couldn't import: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                return
            }
            await follow(library: library, into: groups.first?.playlistID)
        }
    }

    /// Asks every 2 s until the server says it has finished, then shows the library as it now is.
    private func follow(library: LibraryStore, into playlist: UUID?) async {
        // songs are added one by one: the playlist being filled shows them as they come, not only at the end (it said
        // "0 songs" for minutes while the server had added dozens, 12 Oct). At most one reload every 5 s
        var shown = 0, reloaded = Date.distantPast
        while let current = status, !current.finished {
            try? await Task.sleep(for: .seconds(2))
            if let next = try? await API.spotifyImportStatus(current.id) { status = next }
            if let playlist, let added = status?.added, added > shown, Date().timeIntervalSince(reloaded) >= 5 {
                shown = added
                reloaded = .now
                _ = await library.loadPlaylist(playlist)
            }
        }
        await library.refresh()
        if let playlist { _ = await library.loadPlaylist(playlist) }   // the open playlist shows its new songs
        if let status {
            let missing = status.total - status.added
            library.notify(missing == 0 ? "Imported all \(status.added) songs"
                           : "Imported \(status.added) of \(status.total) songs; \(missing) not found",
                           symbol: "square.and.arrow.down.fill")
        }
    }
}
