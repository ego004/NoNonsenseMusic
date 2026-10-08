import Foundation

/// Every call the app makes to your FastAPI server.
enum API {
    static let defaultServer = "http://127.0.0.1:8000"

    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? defaultServer)
            ?? URL(string: defaultServer)!
    }

    /// The signed-in session's token (AUTH-1), set by `Account`. Every request carries it as `Authorization: Bearer …`
    /// (`perform`), except sign-up and sign-in, which make one.
    static var token: String?

    /// Called when the server answers 401 to a request sent with the token still in use: the session ended (it expired,
    /// or you signed out on another device). `Account` forgets it and shows the sign-in screen.
    static var onSignedOut: (() -> Void)?

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

    /// True only for a 200 within 3 s: any answer at all used to count (another program on the port answering 404
    /// read as "the server is running"), and a server that hung was waited on for URLSession's default 60 s.
    static func health() async -> Bool {
        let request = URLRequest(url: baseURL.appending(path: "health"), timeoutInterval: 3)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The server's address for a copy: it answers with a redirect to the audio file (see `audioURL`, which asks it).
    /// `fresh`: skip the server's cache (sent only after this listing's cached URL failed to play).
    static func playURL(_ listing: Listing, fresh: Bool = false) -> URL {
        var base = baseURL
        #if DEBUG
        // self-tests: songs through a local proxy that holds each /play (a slow connection, NN_SELFTEST_SLOWPLAY)
        if let port = ProcessInfo.processInfo.environment["NN_SLOW_PLAY_PORT"], let slow = URL(string: "http://127.0.0.1:\(port)") { base = slow }
        #endif
        let url = base.appending(path: "play").appending(path: listing.source).appending(path: listing.id)
        return fresh ? url.appending(queryItems: [URLQueryItem(name: "serve_fresh", value: "true")]) : url
    }

    /// Tell the server a listing's URL failed: it fetches a fresh one into its cache. The redirect is not followed,
    /// so no audio is downloaded. Returns the server's answer (307 = a fresh URL is ready, 404, 502 + its detail),
    /// so the player can say why a copy failed; nil when the server did not answer.
    @discardableResult
    static func refresh(_ listing: Listing) async -> (status: Int, detail: String?)? {
        guard let (data, response) = try? await perform(URLRequest(url: playURL(listing, fresh: true)), on: noRedirect),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, detail(data))
    }

    /// The audio's own address, for AVPlayer and for downloads. /play needs the token; the player is never given it: an
    /// HTTP stack that follows the redirect may carry `Authorization` on to the audio host (YouTube, JioSaavn). So the
    /// app asks /play itself, does not follow the redirect, and hands over the `Location` (handoff 3.2, 8 Oct). The same
    /// two requests as before: AVPlayer following the redirect was two already.
    static func audioURL(_ listing: Listing, fresh: Bool = false) async throws -> URL {
        let (data, response) = try await perform(URLRequest(url: playURL(listing, fresh: fresh), timeoutInterval: 20), on: noRedirect)
        let http = response as? HTTPURLResponse
        if let code = http?.statusCode, (300..<400).contains(code),
           let location = http?.value(forHTTPHeaderField: "Location"), let url = URL(string: location, relativeTo: baseURL) {
            return url.absoluteURL
        }
        throw Failure.http(http?.statusCode ?? 0, detail: detail(data))
    }

    /// One listing for `POST /prefetch` (MUS-1 step 3).
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
        let (_, response) = try await perform(request)
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

    // ---- sharing (AUTH-3): the owner shares by username, as a viewer or an editor (the same call again changes the
    // role), and makes a playlist public; a member leaves by removing themselves ----

    private struct PublicBody: Encodable { let `public`: Bool }
    private struct ShareBody: Encodable { let username: String; let role: String }

    static func setPublic(_ id: UUID, _ isPublic: Bool) async throws {
        let _: PlaylistSummary = try await send("PATCH", path: "playlists/\(id.path)", body: PublicBody(public: isPublic))
    }

    static func share(_ id: UUID, with username: String, role: String) async throws {
        try await sendNoContent("PUT", path: "playlists/\(id.path)/members", body: ShareBody(username: username, role: role))
    }

    static func removeMember(_ user: UUID, from id: UUID) async throws {
        try await sendNoContent("DELETE", path: "playlists/\(id.path)/members/\(user.path)")
    }

    // ---- accounts (AUTH-1). Sign-up and sign-in send no token; their 401 means "wrong username or password", not a
    // session that ended ----

    private struct Credentials: Encodable {
        let username: String
        let password: String
        let deviceName: String
        enum CodingKeys: String, CodingKey { case username, password; case deviceName = "device_name" }
    }

    static func signUp(_ username: String, _ password: String, device: String) async throws -> SessionReply {
        try await session("auth/signup", Credentials(username: username, password: password, deviceName: device))
    }

    static func signIn(_ username: String, _ password: String, device: String) async throws -> SessionReply {
        try await session("auth/signin", Credentials(username: username, password: password, deviceName: device))
    }

    private struct DeviceBody: Encodable {
        let deviceName: String
        enum CodingKeys: String, CodingKey { case deviceName = "device_name" }
    }

    /// `PATCH /auth/me/device`: renames this device (the session the token belongs to) in your list of devices.
    static func renameDevice(_ name: String) async throws {
        try await sendNoContent("PATCH", path: "auth/me/device", body: DeviceBody(deviceName: name))
    }

    private static func session(_ path: String, _ body: Credentials) async throws -> SessionReply {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)     // no token: this makes one
        try check(response, data: data)
        return try JSONDecoder().decode(SessionReply.self, from: data)
    }

    /// Who the stored token belongs to: the launch check. A 401 ends the session (through `onSignedOut`).
    static func me() async throws -> AccountUser { try await get(baseURL.appending(path: "auth/me")) }

    /// Ends this device's session on the server; your other devices stay signed in.
    static func signOut() async throws { try await sendNoContent("POST", path: "auth/signout") }

    // ---- plumbing ----

    /// Every request but sign-up and sign-in goes through here: the token on it, and a 401 to that token ends the
    /// session. Only to the token still in use: an older request answering 401 after you signed in again says nothing.
    private static func perform(_ request: URLRequest, on session: URLSession = .shared) async throws -> (Data, URLResponse) {
        var request = request
        let sent = token
        if let sent { request.setValue("Bearer \(sent)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, let sent, sent == token { onSignedOut?() }
        return (data, response)
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await perform(URLRequest(url: url))
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For 204 answers: nothing to decode.
    private static func sendNoContent(_ method: String, path: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        let (data, response) = try await perform(request)
        try check(response, data: data)
    }

    private static func sendNoContent<B: Encodable>(_ method: String, path: String, body: B) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        try check(response, data: data)
    }

    private static func send<B: Encodable, T: Decodable>(_ method: String, path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Throws for a status outside `allow`, carrying the server's `detail` sentence when there is one.
    private static func check(_ response: URLResponse, data: Data? = nil, allow: Set<Int> = Set(200..<300)) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard allow.contains(code) else { throw Failure.http(code, detail: data.flatMap(detail)) }
    }

    /// The server's own words, written to be shown. A 422 lists what was wrong with each field instead:
    /// `[{"loc": ["body", "password"], "msg": "String should have at least 8 characters"}]` →
    /// "Password should have at least 8 characters" (it was no sentence at all before accounts, 8 Oct).
    static func detail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let sentence = json["detail"] as? String { return sentence }
        guard let first = (json["detail"] as? [[String: Any]])?.first, let message = first["msg"] as? String else { return nil }
        let field = ((first["loc"] as? [Any])?.last as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        guard let initial = field.first else { return message }
        let name = initial.uppercased() + field.dropFirst()
        return message.hasPrefix("String should") ? "\(name) \(message.dropFirst("String ".count))" : "\(name): \(message)"
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
