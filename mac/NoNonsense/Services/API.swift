import Foundation

/// Every call the app makes to your FastAPI server.
enum API {
    static let defaultServer = "http://127.0.0.1:8000"

    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? defaultServer)
            ?? URL(string: defaultServer)!
    }

    enum Failure: LocalizedError {
        /// detail: the server's own sentence, when it sent one ("A playlist with this name already exists")
        case http(Int, detail: String?)
        var errorDescription: String? {
            switch self {
            case .http(_, let detail?): detail
            case .http(let code, nil): "The server answered \(code)."
            }
        }
    }

    // ---- reads ----

    static func search(_ query: String) async throws -> SearchResponse {
        var url = baseURL.appending(path: "search")
        url.append(queryItems: [URLQueryItem(name: "q", value: query)])
        return try await get(url)
    }

    static func liked() async throws -> [LibrarySong] { try await get(baseURL.appending(path: "liked")) }
    static func recent() async throws -> [LibrarySong] { try await get(baseURL.appending(path: "recent")) }

    static func health() async -> Bool {
        (try? await URLSession.shared.data(from: baseURL.appending(path: "health"))) != nil
    }

    /// The server answers with a redirect to the audio file; AVPlayer follows it.
    /// `fresh`: skip the server's cache (sent only after this listing's cached URL failed to play).
    static func playURL(_ listing: Listing, fresh: Bool = false) -> URL {
        let url = baseURL.appending(path: "play").appending(path: listing.source).appending(path: listing.id)
        return fresh ? url.appending(queryItems: [URLQueryItem(name: "serve_fresh", value: "true")]) : url
    }

    /// Tell the server a listing's URL failed: it fetches a fresh one into its cache. The redirect is not followed,
    /// so no audio is downloaded. Returns the server's answer (307 = a fresh URL is ready, 404, 502 + its detail),
    /// so the player can say why a copy failed; nil when the server did not answer.
    @discardableResult
    static func refresh(_ listing: Listing) async -> (status: Int, detail: String?)? {
        guard let (data, response) = try? await noRedirect.data(from: playURL(listing, fresh: true)),
              let http = response as? HTTPURLResponse else { return nil }
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
        return (http.statusCode, detail)
    }

    /// Ask the server to resolve a listing's audio URL in advance, without downloading any audio:
    /// the redirect is not followed. Pays off once the server caches URLs; MUS-1 replaces it with a prefetch request.
    private struct PrefetchItem: Encodable {
        let source: String
        let sourceID: String
        enum CodingKeys: String, CodingKey { case source; case sourceID = "source_id" }
    }
    private struct PrefetchBody: Encodable { let listings: [PrefetchItem] }

    /// `POST /prefetch`: these listings come next. The server answers 202 at once and looks them up in the background.
    static func prefetch(_ listings: [Listing]) async throws {
        let items = listings.prefix(50).map { PrefetchItem(source: $0.source, sourceID: $0.id) }   // the server's maximum
        try await sendNoContent("POST", path: "prefetch", body: PrefetchBody(listings: Array(items)))
    }

    private struct LyricsBody: Encodable {
        let songName: String
        let artistName: String
        let songDuration: Int
        let youtubeID: String?               // nil is left out: the server's default (no YouTube copy)
        enum CodingKeys: String, CodingKey {
            case songName = "song_name", artistName = "artist_name", songDuration = "song_duration", youtubeID = "youtube_id"
        }
    }

    /// The song's lyrics (MUS-12). Always an answer when the server is reached: no lyrics is an empty `lines`.
    /// Throws only when the server cannot be asked.
    static func lyrics(for track: Track) async throws -> Lyrics {
        // every artist, joined: LRCLIB then matches the fuller record (measured 6 Oct: 50 lines vs 5 with the first
        // artist alone). YouTube Music needs a YouTube copy's id, even when another copy is the one playing.
        let youtube = track.listings.first { $0.source == "ytmusic" }?.id
        return try await send("POST", path: "lyrics", body: LyricsBody(songName: track.title, artistName: track.artistLine,
                                                                       songDuration: track.duration, youtubeID: youtube))
    }

    private static let noRedirect = URLSession(configuration: .default, delegate: StopRedirects(), delegateQueue: nil)

    // ---- writes (IDs are lazy: send the listings, the server finds or creates the song) ----

    private struct LibraryBody: Encodable { let listings: [Listing] }
    private struct EventBody: Encodable { let listings: [Listing]; let type: String; let position: Int }

    @discardableResult
    static func like(_ listings: [Listing]) async throws -> UUID {
        let ref: SongRef = try await send("POST", path: "liked", body: LibraryBody(listings: listings))
        return ref.songID
    }

    static func unlike(_ songID: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "liked").appending(path: songID.uuidString.lowercased()))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response, allow: [204, 404])
    }

    /// type: "play" | "skip" | "finish"; position: seconds into the song
    static func event(_ listings: [Listing], type: String, position: Int) async throws {
        let _: SongRef = try await send("POST", path: "events",
                                        body: EventBody(listings: listings, type: type, position: max(0, position)))
    }

    // ---- playlists (MUS-2) ----

    static func playlists() async throws -> [PlaylistSummary] {
        let response: PlaylistsResponse = try await get(baseURL.appending(path: "playlists"))
        return response.playlists
    }

    static func playlist(_ id: UUID) async throws -> PlaylistDetail {
        try await get(baseURL.appending(path: "playlists/\(id.path)"))
    }

    private struct NameBody: Encodable { let name: String }

    static func createPlaylist(named name: String) async throws -> PlaylistSummary {
        try await send("POST", path: "playlists", body: NameBody(name: name))
    }

    static func renamePlaylist(_ id: UUID, to name: String) async throws -> PlaylistSummary {
        try await send("PATCH", path: "playlists/\(id.path)", body: NameBody(name: name))
    }

    static func deletePlaylist(_ id: UUID) async throws {
        try await sendNoContent("DELETE", path: "playlists/\(id.path)")
    }

    @discardableResult
    static func add(_ listings: [Listing], to playlist: UUID) async throws -> PlaylistItemRef {
        try await send("POST", path: "playlists/\(playlist.path)/items", body: LibraryBody(listings: listings))
    }

    static func remove(item: UUID, from playlist: UUID) async throws {
        try await sendNoContent("DELETE", path: "playlists/\(playlist.path)/items/\(item.path)")
    }

    /// The new neighbours: `top` above, `bottom` below; nil is the top or the bottom of the list. One row moves.
    private struct MoveBody: Encodable {
        let top: UUID?
        let bottom: UUID?
        enum CodingKeys: String, CodingKey { case top = "top_neighbour_id"; case bottom = "bottom_neighbour_id" }
        func encode(to encoder: Encoder) throws {          // nil goes out as null, like Listing's fields
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(top, forKey: .top)
            try c.encode(bottom, forKey: .bottom)
        }
    }

    static func move(item: UUID, in playlist: UUID, top: UUID?, bottom: UUID?) async throws {
        try await sendNoContent("POST", path: "playlists/\(playlist.path)/items/\(item.path)/move", body: MoveBody(top: top, bottom: bottom))
    }

    static func move(playlist: UUID, top: UUID?, bottom: UUID?) async throws {
        try await sendNoContent("POST", path: "playlists/\(playlist.path)/move", body: MoveBody(top: top, bottom: bottom))
    }

    // ---- plumbing ----

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For 204 answers: nothing to decode.
    private static func sendNoContent(_ method: String, path: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
    }

    private static func sendNoContent<B: Encodable>(_ method: String, path: String, body: B) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
    }

    private static func send<B: Encodable, T: Decodable>(_ method: String, path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Throws for a status outside `allow`, carrying the server's `detail` sentence when there is one
    /// (FastAPI's 422s send a list instead: then there is no sentence, only the code).
    private static func check(_ response: URLResponse, data: Data? = nil, allow: Set<Int> = Set(200..<300)) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard allow.contains(code) else {
            struct Detail: Decodable { let detail: String }
            throw Failure.http(code, detail: data.flatMap { try? JSONDecoder().decode(Detail.self, from: $0) }?.detail)
        }
    }
}

private extension UUID {
    /// How ids go in URLs: lowercase, as the server prints them.
    var path: String { uuidString.lowercased() }
}

/// Makes a URLSession stop at a redirect instead of following it (used by `API.refresh`).
/// Top-level and callback-style: a nested class with an `async` version of this method crashed the Swift 6.4 compiler.
nonisolated final class StopRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
