import Foundation
import Observation

// The rules, for this app, the Windows and Android app's core/jam.dart and the server: docs/jam.md.

// MARK: - Models (JamState over HTTP and /ws/jam)

nonisolated struct JamMember: Codable, Hashable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case username; case userID = "user_id" }
}

nonisolated struct JamEntry: Codable, Hashable, Identifiable, Sendable {
    let entryID: UUID
    let listing: Listing
    /// The song's other copies, best first: this Mac's player falls back on them when `listing` will not play here (one
    /// member's copy failing left that member silent while the others heard it). None from an app that sent none.
    let copies: [Listing]
    var id: UUID { entryID }
    enum CodingKeys: String, CodingKey { case listing, copies; case entryID = "entry_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try c.decode(UUID.self, forKey: .entryID)
        listing = try c.decode(Listing.self, forKey: .listing)
        copies = try c.decodeIfPresent([Listing].self, forKey: .copies) ?? []
    }
}

nonisolated struct JamState: Codable, Equatable, Sendable {
    let roomID: UUID
    let code: String
    let name: String?
    let hostID: UUID
    let members: [JamMember]
    let current: JamEntry?
    let isPlaying: Bool
    let positionSeconds: Double
    let queue: [JamEntry]
    /// The host plays the room on their device alone: every other member's player follows without sound.
    let onlyHostPlays: Bool
    /// The host controls the room alone: members may only add songs to the end of the queue.
    let onlyHostControls: Bool
    enum CodingKeys: String, CodingKey {
        case code, name, members, current, queue
        case roomID = "room_id"; case hostID = "host_id"; case isPlaying = "is_playing"; case positionSeconds = "position_seconds"
        case onlyHostPlays = "only_host_plays"; case onlyHostControls = "only_host_controls"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try c.decode(UUID.self, forKey: .roomID)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        members = try c.decode([JamMember].self, forKey: .members)
        current = try c.decodeIfPresent(JamEntry.self, forKey: .current)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        positionSeconds = try c.decode(Double.self, forKey: .positionSeconds)
        queue = try c.decode([JamEntry].self, forKey: .queue)
        // a server from before sends neither
        onlyHostPlays = try c.decodeIfPresent(Bool.self, forKey: .onlyHostPlays) ?? false
        onlyHostControls = try c.decodeIfPresent(Bool.self, forKey: .onlyHostControls) ?? false
    }

    /// The member's name, or "Someone" when they are not in the member list.
    func name(of user: UUID) -> String { members.first { $0.userID == user }?.username ?? "Someone" }
    var hostName: String { name(of: hostID) }
}

/// The song on screen when you start or join a jam: a room with no song takes it, from `seconds`, playing or paused as
/// it was (docs/jam.md). It goes with the request, so nothing lands between the room opening and the song joining it:
/// this app used to add it, seek it and pause it with three commands after the room's first, empty, state.
nonisolated struct JamSong: Encodable, Sendable {
    let listing: Listing
    let copies: [Listing]
    let seconds: Double
    let playing: Bool
}

/// One control message for the room (JamCommand on the server).
private nonisolated struct JamCommand: Encodable, Sendable {
    let type: String
    var seconds: Double? = nil
    var listings: [Listing]? = nil
    /// add: each song's other copies, in the order of `listings`, for members whose device cannot play the first
    var copies: [[Listing]]? = nil
    /// remove, move, jump, ended
    var entryID: UUID? = nil
    /// add: "end", "next" or "now" (Play: at once, the song playing dropped)
    var placement: String? = nil
    /// move: the entry's new place in the room's queue
    var toIndex: Int? = nil
    /// only_host_plays, only_host_controls: the setting's new value
    var on: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case type, seconds, listings, copies, placement, on; case entryID = "entry_id"; case toIndex = "to_index"
    }
}

extension API {
    private struct JamCreate: Encodable { let name: String?; let song: JamSong? }
    private struct JamJoin: Encodable { let code: String; let song: JamSong? }
    private struct JamHost: Encodable {
        let memberID: UUID
        enum CodingKeys: String, CodingKey { case memberID = "member_id" }
    }

    static func createJam(named name: String?, song: JamSong?) async throws -> JamState {
        try await send("POST", path: "jam", body: JamCreate(name: name, song: song))
    }
    static func joinJam(code: String, song: JamSong?) async throws -> JamState {
        try await send("POST", path: "jam/join", body: JamJoin(code: code, song: song))
    }
    /// The room as it is now; `Failure.http(404, _)` when it is gone or you are not in it.
    static func jam(_ room: UUID) async throws -> JamState {
        try await get(baseURL.appending(path: "jam/\(room.uuidString.lowercased())"))
    }
    static func setJamHost(_ room: UUID, member: UUID) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/host", body: JamHost(memberID: member))
    }
    private struct JamInvite: Encodable { let username: String }

    static func inviteToJam(_ room: UUID, username: String) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/invites", body: JamInvite(username: username))
    }
    static func leaveJam(_ room: UUID) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/leave")
    }
}

// MARK: - The session

/// A jam: listening together. Every member's device plays the room's song in step and every member controls it; the
/// host may choose to play the room on their Mac alone (`onlyHostPlays`) or to control it alone (`onlyHostControls`).
/// While you are in one, the room decides what plays: the player's ⏯ ⏭ ⏮, seeks, and Play on any song become the room's
/// commands (playing a song adds it to the jam), and every member's player follows the room's state as it arrives. One
/// WebSocket carries the commands and the state; the host's app reports its playhead every 15 s while the room plays,
/// which keeps its socket open, and any other socket pings every 25 s. An idle jam costs no CPU. The rules are
/// docs/jam.md's, as in the Windows and Android app.
@MainActor
@Observable
final class JamSession {
    static let shared = JamSession()

    private(set) var state: JamState?
    /// The server's last refusal ("Queue is full (200).") or a connection problem, shown in the jam's popover.
    private(set) var problem: String?

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored var me: UUID?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var connected = false
    /// The entry this Mac's player last loaded: a state with another entry loads that one.
    @ObservationIgnored private var loadedEntry: UUID?
    /// The room's last known place: its position, whether it played, and when that arrived.
    @ObservationIgnored private var mark: (seconds: Double, playing: Bool, at: Date) = (0, false, .distantPast)
    /// Shows a short message in the window ("Added to the jam", why you are out of it); set by the window.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    /// More than this far from the room's playhead, a player moves to it (docs/jam.md: the same in every app).
    static let seekBeyond = 2.5
    /// What you are told when the room turns you away: the server says only that it has no such room for you (#31).
    static let endedNotice = "You are no longer in the jam: it ended, or the host removed you."
    static let notConnected = "Not connected to the jam right now. Trying again…"

    /// Where the room's song is now: the last position the room gave, plus the time since while it plays (the server's
    /// playhead). A song loaded for the room starts here once it is ready: the position from when its state arrived
    /// was as old as the load was long, and a member started that far behind until the host's next report, 15 s later
    /// (#28).
    var playhead: Double? {
        guard state?.current != nil else { return nil }
        return mark.seconds + (mark.playing ? Date().timeIntervalSince(mark.at) : 0)
    }

    var isHost: Bool { state != nil && state?.hostID == me }
    /// The host's app reports its place while the room plays a song, and only then.
    private var reporting: Bool { isHost && state?.isPlaying == true && state?.current != nil }
    /// A member's device plays the room's song in step with the host. Off: it follows silently (friends in one room
    /// would hear an echo). The host always plays.
    var playHere = true { didSet { if let state { player?.jamSetSilent(silentHere(state)) } } }

    /// Whether this Mac follows `room` without sound: a member's, when the host plays the room alone or the member
    /// turned Play here off. The host's always plays.
    private func silentHere(_ room: JamState) -> Bool { room.hostID != me && (room.onlyHostPlays || !playHere) }

    /// At most this many other copies go with a song (the server's MAX_JAM_COPIES).
    private static let maxCopies = 4

    /// `track`'s copies other than the one that plays, best first, as an add sends them.
    private static func otherCopies(_ track: Track, playing: Listing? = nil) -> [Listing] {
        let first = (playing ?? track.best).key
        return Array(track.listings.filter { $0.key != first }.prefix(maxCopies))
    }
    var inJam: Bool { state != nil }

    /// The song on screen, with the copy that plays and where it is: what a start or a join brings to an empty room.
    private var songOnScreen: JamSong? {
        guard let player, let track = player.current else { return nil }
        let listing = player.playingListing ?? track.best
        return JamSong(listing: listing, copies: Self.otherCopies(track, playing: listing), seconds: player.livePosition,
                       playing: player.isPlaying)
    }

    // MARK: joining and leaving

    /// nil when it worked; else why not. The song on screen comes in with its place and nothing restarts.
    func start(named name: String?) async -> String? {
        let song = songOnScreen
        return await enter { try await API.createJam(named: name?.isEmpty == true ? nil : name, song: song) }
    }

    /// nil when it worked; else why not. A room with no song takes the one on screen; one with a song plays its own here.
    func join(code: String) async -> String? {
        let typed = code.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !typed.isEmpty else { return "Enter the jam's code." }
        let song = songOnScreen
        return await enter { try await API.joinJam(code: typed, song: song) }
    }

    private func enter(_ request: () async throws -> JamState) async -> String? {
        let before = state?.roomID
        do {
            let room = try await request()
            open(room)
            // one jam at a time: the one you were in is left on the server too, not kept with you as a silent member
            if let before, before != room.roomID { Task { try? await API.leaveJam(before) } }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The jam this Mac was in when the app last ran (docs/jam.md): back in it when the room still has you; told
    /// otherwise. Quit in a jam, the app forgot it while the room still listed you. Called once signed in.
    func resume() async {
        guard !inJam, let saved = UserDefaults.standard.string(forKey: Self.roomKey), let room = UUID(uuidString: saved) else { return }
        do {
            open(try await API.jam(room))
        } catch API.Failure.http(404, _) {
            UserDefaults.standard.removeObject(forKey: Self.roomKey)
            onNotice?(Self.endedNotice)
        } catch {}                                       // offline: asked again at the next launch
    }

    private static let roomKey = "jamRoom"

    private func open(_ room: JamState) {
        leaveLocally()
        UserDefaults.standard.set(room.roomID.uuidString, forKey: Self.roomKey)
        apply(room)
        loop = Task { [weak self] in await self?.listen(room.roomID) }
    }

    func leave() async {
        guard let room = state?.roomID else { return }
        leaveLocally()
        try? await API.leaveJam(room)
    }

    /// Signed out, or another jam: the socket closes and the player is yours again (not stopped: the song plays on).
    func leaveLocally() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        UserDefaults.standard.removeObject(forKey: Self.roomKey)   // signed out too: the next account must not come back in
        state = nil
        problem = nil
        loadedEntry = nil
        radioAskedAfter = nil
        station = nil
        autoplayed = []
        playHere = true
        player?.jamSetSilent(false)
        player?.jam = nil
    }

    /// Out of the jam without leaving it here: said once, wherever you are, as the jam's other notices are.
    private func out(_ why: String) {
        leaveLocally()
        onNotice?(why)
    }

    /// The host plays the room on this Mac alone (on), or on every member's device (off, the default).
    func setOnlyHostPlays(_ on: Bool) {
        guard isHost else { return }
        send(JamCommand(type: "only_host_plays", on: on))
    }

    /// The host controls the room alone (on): members may only add songs to the end of the queue; or everyone does.
    func setOnlyHostControls(_ on: Bool) {
        guard isHost else { return }
        send(JamCommand(type: "only_host_controls", on: on))
    }

    /// The current host makes another member the host: the room's clock, and its only device when it plays alone. A
    /// member cannot silently take over somebody else's room.
    func giveSpeakers(to member: JamMember) async {
        guard isHost, let room = state?.roomID else { return }
        do { try await API.setJamHost(room, member: member.userID) } catch { problem = error.localizedDescription }
    }

    /// The host removes someone from the room: the server tells their app, which leaves the jam and says why.
    func remove(_ member: JamMember) async {
        guard isHost, let room = state?.roomID else { return }
        do {
            try await API.sendNoContent("DELETE", path: "jam/\(room.uuidString.lowercased())/members/\(member.userID.uuidString.lowercased())")
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The host invites a friend: they get a notification with the jam's code. nil when it went out; else why not.
    func invite(_ username: String) async -> String? {
        guard let room = state?.roomID else { return nil }
        do {
            try await API.inviteToJam(room, username: username)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: commands (the player calls these while in a jam)

    /// Play (`play` true) or pause the room: what the button pressed shows, so a Mac still loading the room's song (its
    /// button on Play) cannot pause the room for everyone. Play with the room empty starts it with the song on screen,
    /// from the start; without one you are told how. It sent "play", which the server refused: Play did nothing (14 Oct).
    func setPlaying(_ play: Bool) {
        guard let room = state else { return }
        if play, room.current == nil {
            guard let song = songOnScreen else { onNotice?("Nothing is playing in the jam. Play any song to start it."); return }
            add([Track(best: song.listing, listings: [song.listing] + song.copies, choosingVersion: false)], .now)
            return
        }
        if !locked() { send(JamCommand(type: play ? "play" : "pause")) }
    }
    func skip() { if !locked() { send(JamCommand(type: "skip")) } }
    func seek(to seconds: Double) { if !locked() { send(JamCommand(type: "seek", seconds: max(0, seconds))) } }

    /// Whether you may control the room: everyone may, unless the host chose to control it alone.
    var canControl: Bool { isHost || state?.onlyHostControls != true }
    static let lockedNotice = "The host controls this jam. You can add songs to the queue."

    /// A control you may not use while the host controls the room: you are told, and nothing is sent (the server would
    /// refuse it).
    private func locked() -> Bool {
        if canControl { return false }
        onNotice?(Self.lockedNotice)
        return true
    }
    enum Placement: String { case end, next, now }

    /// Play (`.now`), Play Next (`.next`) and Add to Queue (`.end`) in a jam: one command each, placed by the server.
    /// While the host controls the room, your Play and Play Next add to the end instead.
    func add(_ tracks: [Track], _ asked: Placement = .end) {
        guard !tracks.isEmpty else { return }
        let placement = canControl ? asked : .end
        guard send(JamCommand(type: "add", listings: tracks.map(\.best), copies: tracks.map { Self.otherCopies($0) },
                              placement: placement.rawValue)) else { return }
        let what = tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) songs"
        let notice = switch placement {
            case .now: "Playing \(what) in the jam"
            case .next: "\(what) plays next in the jam"
            case .end: "Added \(what) to the jam"
        }
        onNotice?(placement == asked ? notice : notice + ": the host controls this jam")
    }
    func remove(_ entry: JamEntry) { if !locked() { send(JamCommand(type: "remove", entryID: entry.entryID)) } }
    func jump(to entry: JamEntry) { if !locked() { send(JamCommand(type: "jump", entryID: entry.entryID)) } }
    func move(_ entry: JamEntry, to index: Int) {
        if !locked() { send(JamCommand(type: "move", entryID: entry.entryID, toIndex: index)) }
    }

    /// The room's song played to its end on this Mac. Every member's app says so; the server moves the room on at the
    /// host's, or at a member's near the end (docs/jam.md), so the room no longer waits for the host's app. A copy that
    /// would not play is not an end: it is this Mac's alone.
    func songEnded() {
        if let loadedEntry { send(JamCommand(type: "ended", entryID: loadedEntry), quietly: true) }
    }

    /// Sends a command over the room's socket. While it is not connected (just joined, or connecting again) nothing is
    /// sent and you are told: a command sent late could pause the room long after you pressed Pause.
    @discardableResult
    private func send(_ command: JamCommand, quietly: Bool = false) -> Bool {
        guard connected, let socket, let data = try? JSONEncoder().encode(command), let text = String(data: data, encoding: .utf8) else {
            if !quietly { onNotice?(Self.notConnected) }
            return false
        }
        problem = nil
        Task { try? await socket.send(.string(text)) }
        return true
    }

    // MARK: Autoplay for the room

    @ObservationIgnored private var radioAskedAfter: String?
    @ObservationIgnored private var radioAsking = false
    /// What this host's Autoplay added to the room, oldest first, and the song their station follows.
    @ObservationIgnored private var autoplayed: [Listing] = []
    @ObservationIgnored private var station: Listing?

    /// The room's Autoplay, run by the host alone (one app asks, not every member's): when one song or fewer is left in
    /// the queue, songs like the last one a person chose are added, as Up Next does outside a jam. Once per song asked
    /// about, and only after an answer, so a failure is asked again at the next change.
    private func refillIfNeeded(_ room: JamState) {
        guard isHost, Player.autoplay, room.queue.count <= 1, !radioAsking,
              let last = room.queue.last?.listing ?? room.current?.listing, radioAskedAfter != last.key else { return }
        // a song Autoplay added never seeds it: the station goes on from the last song a person chose (docs/jam.md)
        let seed = autoplayed.contains(where: { $0.key == last.key }) ? station ?? last : last
        let exclude = autoplayed + ([room.current?.listing].compactMap { $0 }) + room.queue.map(\.listing)
        radioAsking = true
        Task {
            defer { radioAsking = false }
            guard let songs = try? await API.radio(seed: seed, exclude: exclude, limit: 10,
                                                  skipRecent: Player.autoplaySkipsRecent), !songs.isEmpty,
                  state?.roomID == room.roomID else { return }
            radioAskedAfter = last.key
            station = seed
            let tracks = songs.map { Track($0) }
            autoplayed += tracks.map(\.best)
            send(JamCommand(type: "add", listings: tracks.map(\.best), copies: tracks.map { Self.otherCopies($0) }), quietly: true)
        }
    }

    // MARK: the room's state

    /// A new state: kept, told, and this Mac's player made to match it.
    private func apply(_ room: JamState) {
        let was = state
        mark = (room.positionSeconds, room.isPlaying, Date())
        if room != state { state = room }
        if let was, was.hostID != room.hostID { sayNewHost(was, room) }
        follow()
        refillIfNeeded(room)
    }

    /// "“Kai” left the jam. You're the host now.": the host left, or handed the role on (docs/jam.md).
    private func sayNewHost(_ was: JamState, _ room: JamState) {
        let left = !room.members.contains { $0.userID == was.hostID }
        let now = room.hostID == me ? "You're the host now." : "“\(room.hostName)” is the host now."
        onNotice?(left ? "“\(was.hostName)” left the jam. \(now)" : now)
    }

    /// Makes this Mac's player match the room: docs/jam.md, "How an app follows the room", step by step.
    private func follow() {
        guard let room = state, let player else { return }
        player.jam = self
        player.jamSetSilent(silentHere(room))
        guard let entry = room.current, let at = playhead else {
            loadedEntry = nil
            if player.isPlaying { player.jamFollow(playing: false) }
            return
        }
        if entry.entryID != loadedEntry {
            loadedEntry = entry.entryID
            // the room's song is the copy already playing here (it came in with a start or a join): kept, not loaded again
            if entry.listing.key != player.playingListing?.key {
                // the song's other copies come too: a copy that will not play on this Mac falls back to the next one
                player.jamLoad(Track(best: entry.listing, listings: [entry.listing] + entry.copies, choosingVersion: false),
                               at: at, playing: room.isPlaying)
                return
            }
        }
        if room.isPlaying != player.isPlaying { player.jamFollow(playing: room.isPlaying) }
        // a song still loading starts at the playhead when it is ready (Player.statusChanged)
        if !player.isBuffering, abs(player.livePosition - at) > Self.seekBeyond { player.jamFollow(seek: at) }
    }

    private func listen(_ room: UUID) async {
        var wait: Double = 1
        while !Task.isCancelled, state?.roomID == room {
            if await connectOnce(room) { wait = 1 }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
    }

    private func connectOnce(_ room: UUID) async -> Bool {
        guard let ticket = try? await API.socketTicket(),
              let url = API.socketURL("ws/jam", query: [URLQueryItem(name: "ticket", value: ticket),
                                                       URLQueryItem(name: "room_id", value: room.uuidString.lowercased())])
        else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        // One wake-up per message: the host's report every 15 s while the room plays, which keeps its socket open on its
        // own, else a ping every 25 s (the server closes a socket silent for 30 s). It woke every 5 s before (17 Oct)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.reporting == true ? 15 : 25))
                guard let self, !Task.isCancelled else { return }
                // not while the song loads here: a loading song's place is 0, and it pulled the room back
                if self.reporting, let player = self.player, player.isPlaying, !player.isBuffering {
                    self.send(JamCommand(type: "position", seconds: player.livePosition), quietly: true)
                } else {
                    try? await task.send(.string("ping"))
                }
            }
        }
        defer { ticker.cancel(); task.cancel(with: .goingAway, reason: nil); connected = false }
        var answered = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            if !answered {
                answered = true
                connected = true
            }
            if case .string(let text) = message { handle(text) }
        }
        // the room closed, or you are no longer in it: out of the jam here too, and told (#31)
        if !Task.isCancelled, case .http(404, _)? = await Self.roomGone(room) { out(Self.endedNotice) }
        return answered
    }

    /// GET /jam/{id}: the failure when the room is gone or you are no longer in it; nil when it is still there.
    private static func roomGone(_ room: UUID) async -> API.Failure? {
        do {
            _ = try await API.jam(room)
            return nil
        } catch let failure as API.Failure {
            return failure
        } catch {
            return nil
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let data: JamState?
        let detail: String?                    // error
        let seconds: Double?                   // position
        let isPlaying: Bool?                   // position
        let reason: String?                    // out
        enum CodingKeys: String, CodingKey { case type, data, detail, seconds, reason; case isPlaying = "is_playing" }
    }

    private func handle(_ text: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else { return }
        switch envelope.type {
        case "state": if let room = envelope.data { apply(room) }
        case "position":
            // the host's playhead: without it a member caught up only when the room's state next changed
            if state != nil, let seconds = envelope.seconds {
                mark = (seconds, envelope.isPlaying ?? true, Date())
                follow()
            }
        case "error":
            problem = envelope.detail
            if let detail = envelope.detail { onNotice?(detail) }      // shown where you are, not only in the popover
        case "out":
            out(envelope.reason == "left" ? "You left the jam on another device." : "The host removed you from the jam.")
        default: break                         // "pong"
        }
    }

    #if DEBUG
    /// Self-tests: the room's socket drops, as when the network does; the app connects again by itself.
    func dropSocketForTests() { socket?.cancel() }
    /// Self-tests: whether the room's socket is up.
    var connectedForTests: Bool { connected }
    #endif
}
