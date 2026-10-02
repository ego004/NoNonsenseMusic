import Foundation

/// Every call the app makes to your FastAPI server.
enum API {
    static let defaultServer = "http://127.0.0.1:8000"

    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? defaultServer)
            ?? URL(string: defaultServer)!
    }

    enum Failure: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self { case .http(let code): "The server answered \(code)." }
        }
    }

    // ---- reads ----

    static func search(_ query: String) async throws -> SearchResponse {
        var url = baseURL.appending(path: "search")
        url.append(queryItems: [URLQueryItem(name: "q", value: query)])
        return try await get(url)
    }

    static func library() async throws -> [LibrarySong] { try await get(baseURL.appending(path: "library")) }
    static func recent() async throws -> [LibrarySong] { try await get(baseURL.appending(path: "recent")) }

    static func health() async -> Bool {
        (try? await URLSession.shared.data(from: baseURL.appending(path: "health"))) != nil
    }

    /// The server answers with a redirect to the audio file; AVPlayer follows it.
    static func playURL(_ listing: Listing) -> URL {
        baseURL.appending(path: "play").appending(path: listing.source).appending(path: listing.id)
    }

    // ---- writes (IDs are lazy: send the listings, the server finds or creates the song) ----

    private struct LibraryBody: Encodable { let listings: [Listing] }
    private struct EventBody: Encodable { let listings: [Listing]; let type: String; let position: Int }

    @discardableResult
    static func like(_ listings: [Listing]) async throws -> UUID {
        let ref: SongRef = try await send("POST", path: "library", body: LibraryBody(listings: listings))
        return ref.songID
    }

    static func unlike(_ songID: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "library").appending(path: songID.uuidString.lowercased()))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response, allow: [204, 404])
    }

    /// type: "play" | "skip" | "finish"; position: seconds into the song
    static func event(_ listings: [Listing], type: String, position: Int) async throws {
        let _: SongRef = try await send("POST", path: "events",
                                        body: EventBody(listings: listings, type: type, position: max(0, position)))
    }

    // ---- plumbing ----

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func send<B: Encodable, T: Decodable>(_ method: String, path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, allow: Set<Int> = Set(200..<300)) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard allow.contains(code) else { throw Failure.http(code) }
    }
}
