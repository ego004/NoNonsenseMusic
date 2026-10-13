import Foundation
import Observation

// MARK: - Models (GET /friends, /friends/requests, /notifications)

nonisolated struct Friend: Codable, Hashable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    let since: String                    // ISO 8601: when the friendship began, or when the request was sent
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case username, since; case userID = "user_id" }
}

nonisolated struct FriendRequests: Codable, Sendable {
    let incoming: [Friend]
    let outgoing: [Friend]
}

/// One notification. `payload` holds the names and ids its kind needs (from_username, playlist_id, …).
nonisolated struct AppNotification: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let type: String                     // "friend_request" | "friend_accepted" | "playlist_invite"
    let payload: [String: String]
    let seq: Int
    var read: Bool
    let createdAt: String
    enum CodingKeys: String, CodingKey { case id, type, payload, seq, read; case createdAt = "created_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        // text values only; a null (a jam with no name) or a value of another kind is left out
        payload = ((try? c.decode([String: String?].self, forKey: .payload)) ?? [:]).compactMapValues { $0 }
        seq = try c.decode(Int.self, forKey: .seq)
        read = try c.decode(Bool.self, forKey: .read)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }

    /// Who it is from: the other person's username.
    var from: String { payload["from_username"] ?? payload["by_username"] ?? "Someone" }
}

nonisolated struct NotificationsReply: Codable, Sendable {
    let notifications: [AppNotification]
    let unreadCount: Int
    enum CodingKeys: String, CodingKey { case notifications; case unreadCount = "unread_count" }
}

// MARK: - API

extension API {
    private struct Username: Encodable { let username: String }
    private struct Respond: Encodable { let username: String; let action: String }
    private nonisolated struct Ticket: Decodable { let ticket: String }

    static func friends() async throws -> [Friend] { try await get(baseURL.appending(path: "friends")) }
    static func friendRequests() async throws -> FriendRequests { try await get(baseURL.appending(path: "friends/requests")) }
    static func sendFriendRequest(to username: String) async throws {
        try await sendNoContent("POST", path: "friends/request", body: Username(username: username))
    }
    static func respond(to username: String, accept: Bool) async throws {
        try await sendNoContent("POST", path: "friends/respond", body: Respond(username: username, action: accept ? "accept" : "decline"))
    }
    static func removeFriend(_ id: UUID) async throws { try await sendNoContent("DELETE", path: "friends/\(id.uuidString.lowercased())") }

    static func notifications() async throws -> NotificationsReply {
        var url = baseURL.appending(path: "notifications")
        url.append(queryItems: [URLQueryItem(name: "limit", value: "50")])
        return try await get(url)
    }
    static func markAllNotificationsRead() async throws { try await sendNoContent("POST", path: "notifications/read-all") }

    /// A single-use ticket for a WebSocket handshake, so the session token never goes into a URL.
    static func socketTicket() async throws -> String {
        let reply: Ticket = try await post("ws-ticket")
        return reply.ticket
    }

    /// The server's address for a WebSocket: ws:// for http, wss:// for https.
    static func socketURL(_ path: String, query: [URLQueryItem]) -> URL? {
        guard var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.queryItems = query
        return parts.url
    }
}

// MARK: - Social

/// Friends, friend requests and notifications for the signed-in account. One WebSocket brings new notifications as
/// they happen; it sends a ping every 25 s (the server closes a silent socket after 30 s) and otherwise waits, so it
/// costs no CPU between messages. A dropped socket reconnects after 1 s, then up to 60 s apart while the server is away.
@MainActor
@Observable
final class Social {
    static let shared = Social()

    private(set) var friends: [Friend] = []
    private(set) var incoming: [Friend] = []
    private(set) var outgoing: [Friend] = []
    private(set) var notifications: [AppNotification] = []
    private(set) var unread = 0

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?

    /// Signed in: the lists, then the live socket. Calling it again while running does nothing.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.refresh()
            await self?.listen()
        }
    }

    /// Signed out: the socket closes and every list empties, so nothing of this account stays for the next one.
    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        friends = []; incoming = []; outgoing = []; notifications = []; unread = 0
    }

    func refresh() async {
        async let f = try? API.friends()
        async let r = try? API.friendRequests()
        async let n = try? API.notifications()
        let (friendList, requests, reply) = await (f, r, n)
        if let friendList, friendList != friends { friends = friendList }
        if let requests {
            if requests.incoming != incoming { incoming = requests.incoming }
            if requests.outgoing != outgoing { outgoing = requests.outgoing }
        }
        if let reply {
            if reply.notifications != notifications { notifications = reply.notifications }
            if reply.unreadCount != unread { unread = reply.unreadCount }
        }
    }

    /// nil when the request went out; else the server's reason ("No account with that username", "Already friends").
    func addFriend(_ username: String) async -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Enter a username." }
        do {
            try await API.sendFriendRequest(to: name)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func respond(to username: String, accept: Bool) async {
        incoming.removeAll { $0.username == username }           // at once; the server catches up
        try? await API.respond(to: username, accept: accept)
        await refresh()
    }

    func remove(_ friend: Friend) async {
        friends.removeAll { $0.id == friend.id }
        try? await API.removeFriend(friend.id)
        await refresh()
    }

    /// The notifications list was opened: everything in it counts as read, here and on your other devices.
    func markAllRead() async {
        guard unread > 0 else { return }
        unread = 0
        notifications = notifications.map { var n = $0; n.read = true; return n }
        try? await API.markAllNotificationsRead()
    }

    // MARK: the socket

    private func listen() async {
        var wait: Double = 1
        while !Task.isCancelled {
            if await connectOnce() { wait = 1 }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 60)
        }
    }

    /// One connection, until it drops. True when it connected (the next retry is then quick).
    private func connectOnce() async -> Bool {
        guard let ticket = try? await API.socketTicket(),
              let url = API.socketURL("ws/notifications", query: [URLQueryItem(name: "ticket", value: ticket)]) else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                try? await task.send(.string("ping"))
            }
        }
        defer { pinger.cancel(); task.cancel(with: .goingAway, reason: nil) }
        var connected = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            connected = true
            if case .string(let text) = message { await handle(text) }
        }
        return connected
    }

    private struct Envelope: Decodable {
        let type: String
        let unread: Int?
        let data: Data?
        struct Data: Decodable { let unread: Int? }
    }

    private func handle(_ text: String) async {
        let raw = Data(text.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: raw) else { return }
        switch envelope.type {
        case "connected":
            await refresh()                                          // whatever arrived while the socket was down
        case "notification":
            struct Pushed: Decodable { let data: AppNotification }
            guard let pushed = try? JSONDecoder().decode(Pushed.self, from: raw) else { return }
            if !notifications.contains(where: { $0.id == pushed.data.id }) {
                notifications.insert(pushed.data, at: 0)
                unread += 1
            }
            if pushed.data.type != "playlist_invite" { await refresh() }   // a request or an accept changes the lists
        case "notification_read", "notifications_cleared":
            if let count = envelope.data?.unread, count != unread { unread = count }
        default:
            break                                                    // "pong"
        }
    }
}
