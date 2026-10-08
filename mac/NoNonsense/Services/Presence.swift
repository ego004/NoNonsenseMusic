import Darwin
import Foundation
import Observation

/// Speaks Discord's local RPC protocol over the Unix socket the Discord desktop app opens
/// (`$TMPDIR/discord-ipc-0`). Every message is a frame:
///   [opcode: UInt32 little-endian][length: UInt32 little-endian][JSON]
/// opcode 0 = handshake, 1 = command/reply, 2 = close (Discord rejected us).
/// An `actor`, so its blocking socket reads and writes never run on the main (UI) thread.
actor DiscordIPC {
    struct Activity: Sendable {
        let details: String?        // the song
        let state: String?          // "by …"
        let image: String?          // the cover's URL
        let imageText: String?      // the album, shown on hover
        let smallImage: String?     // the badge on the cover's corner (an art asset's name)
        let smallText: String?
        let start: Int?             // unix seconds; with `end`, Discord draws a time bar
        let end: Int?
        let statusLine: Int         // what the member list shows: 0 the app's name, 1 `state`, 2 `details`
    }

    enum Failure: Error {
        case notRunning                 // no Discord socket to connect to
        case rejected(String)           // the handshake was refused, with Discord's reason ("Invalid Client ID")
        case closed                     // the connection broke (e.g. Discord restarted)
        case timeout                    // Discord did not answer within 10 s (SO_RCVTIMEO, below)
        case discord(String)            // Discord answered the command with an error, with its message
    }

    private var fd: Int32 = -1
    private var connectedClientID: String?

    /// Sends the status. A connection kept from earlier can be dead (Discord restarts to update itself), so a
    /// closed connection is dropped and tried once more on a fresh one. A timeout is not retried at once:
    /// handshakes in quick succession are exactly what makes Discord stop answering.
    func setActivity(_ activity: Activity?, clientID: String) throws {
        do {
            try setActivityOnce(activity, clientID: clientID)
        } catch Failure.closed {
            disconnect()
            try setActivityOnce(activity, clientID: clientID)
        }
    }

    private func setActivityOnce(_ activity: Activity?, clientID: String) throws {
        try connect(clientID: clientID)
        var args: [String: Any] = ["pid": Int(getpid())]
        if let activity { args["activity"] = payload(activity) }      // no activity = clear the status
        try send(opcode: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString])
        let (_, reply) = try receive()
        // Discord answers a bad command with evt "ERROR" and a message: report it instead of claiming success
        if let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], json["evt"] as? String == "ERROR" {
            let message = (json["data"] as? [String: Any])?["message"] as? String ?? "unknown error"
            throw Failure.discord(message)
        }
    }

    func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        connectedClientID = nil
    }

    // MARK: - protocol

    private func payload(_ a: Activity) -> [String: Any] {
        // type 2 = "Listening to". Discord rejects strings shorter than 2 characters.
        var activity: [String: Any] = ["type": 2, "status_display_type": a.statusLine]
        if let details = a.details { activity["details"] = padded(details) }
        if let state = a.state { activity["state"] = padded(state) }
        if let start = a.start, let end = a.end { activity["timestamps"] = ["start": start, "end": end] }
        var assets: [String: Any] = [:]
        if let image = a.image { assets["large_image"] = image }
        if let text = a.imageText { assets["large_text"] = padded(text) }
        if let small = a.smallImage { assets["small_image"] = small }
        if let text = a.smallText { assets["small_text"] = padded(text) }
        if !assets.isEmpty { activity["assets"] = assets }
        // deliberately no buttons or links: nothing here points at a GitHub profile
        return activity
    }

    private func padded(_ s: String) -> String { s.count >= 2 ? String(s.prefix(128)) : s + "  " }

    private func connect(clientID: String) throws {
        if fd >= 0, connectedClientID == clientID { return }
        disconnect()
        for path in Self.socketPaths() {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))   // no crash if Discord quits
            // Discord can take seconds to answer a handshake, and slows down after several in a row (measured 5 Oct:
            // 0.4 s, 4.5 s, no answer). This runs on the actor, never on the main thread, so waiting is free.
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let fits = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    path.withCString { strlcpy(buffer, $0, capacity) < capacity }
                }
            }
            let connected = fits && withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if connected { fd = s; break }
            Darwin.close(s)
        }
        guard fd >= 0 else { throw Failure.notRunning }
        try send(opcode: 0, ["v": 1, "client_id": clientID])
        let (opcode, reply) = try receive()
        guard opcode == 1 else {                                              // 2 = refused, with a reason
            let reason = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["message"] as? String
            disconnect()
            throw Failure.rejected(reason ?? "refused")
        }
        connectedClientID = clientID
    }

    private static func socketPaths() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let dirs = [env["XDG_RUNTIME_DIR"], env["TMPDIR"], "/tmp"].compactMap { $0 }
        return dirs.flatMap { dir in (0..<10).map { (dir as NSString).appendingPathComponent("discord-ipc-\($0)") } }
    }

    private func send(opcode: UInt32, _ json: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: json)
        var frame = Data()
        withUnsafeBytes(of: opcode.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        let written = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, frame.count) }
        guard written == frame.count else { disconnect(); throw Failure.closed }
    }

    private func receive() throws -> (UInt32, Data) {
        let header = try read(8)
        let opcode = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        return (opcode, try read(Int(length)))
    }

    private func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var received = 0
        while received < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + received, count - received) }
            guard n > 0 else {
                let timedOut = n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)    // SO_RCVTIMEO ran out
                disconnect()
                throw timedOut ? Failure.timeout : Failure.closed
            }
            received += n
        }
        return data
    }
}

/// Discord status: the Settings switches, and `update`, which the player calls whenever playback changes.
@Observable
final class Presence {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "discordEnabled")
    /// NoNonsense's own Discord application, built in (8 Oct): you no longer make one and paste its ID. An application
    /// ID is public by design (every Rich Presence program sends it); Discord's public record of this one shows only
    /// its name, "NoNonsenseMusic", and no owner. Its name is what people see after "Listening to".
    static let applicationID = "1556695358023803031"
    private let clientID = Presence.applicationID
    private(set) var status = "Off"
    private(set) var lastTrack: Track?                     // for the preview in Settings
    private(set) var lastPlaylist: String?                 // the playlist that song plays from, if any

    // What to share. Each change is saved and sent to Discord at once.
    var statusLine = UserDefaults.standard.object(forKey: "discordStatusLine") as? Int ?? 2 { didSet { save("discordStatusLine", statusLine) } }
    var shareSong = Presence.flag("discordShareSong") { didSet { save("discordShareSong", shareSong) } }
    var shareArtist = Presence.flag("discordShareArtist") { didSet { save("discordShareArtist", shareArtist) } }
    var shareArt = Presence.flag("discordShareArt") { didSet { save("discordShareArt", shareArt) } }
    var shareTime = Presence.flag("discordShareTime") { didSet { save("discordShareTime", shareTime) } }
    /// The app's logo, uploaded by you as an art asset with this name in the Discord Developer Portal.
    static let logoAsset = "nononsense"
    var shareLogo = Presence.flag("discordShareLogo") { didSet { save("discordShareLogo", shareLogo) } }
    /// "from “Gym”" after the artist, when the song plays from a playlist. Off by default: playlist names can be personal.
    var sharePlaylist = Presence.flag("discordSharePlaylist", default: false) { didSet { save("discordSharePlaylist", sharePlaylist) } }
    /// When paused: "message" (your text), "keep" (the song, without the time bar) or "clear" (nothing).
    var whenPaused = UserDefaults.standard.string(forKey: "discordWhenPaused") ?? "message" { didSet { save("discordWhenPaused", whenPaused) } }
    var pausedMessage = UserDefaults.standard.string(forKey: "discordPausedMessage") ?? "Nothing playing" { didSet { save("discordPausedMessage", pausedMessage) } }

    @ObservationIgnored private let ipc = DiscordIPC()
    @ObservationIgnored private var attempts = 0          // only the newest attempt may set `status`

    @ObservationIgnored private var last: (isPlaying: Bool, position: Double) = (false, 0)

    init() { status = enabled ? "Shows up when a song plays" : "Off" }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "discordEnabled")
        if on { resend() }
        else { status = "Off"; Task { try? await ipc.setActivity(nil, clientID: clientID); await ipc.disconnect() } }
    }

    func update(_ track: Track?, isPlaying: Bool, position: Double, playlist: String? = nil) {
        lastTrack = track
        lastPlaylist = playlist
        last = (isPlaying, position)
        guard enabled else { return }
        send(track.flatMap { activity(for: $0, isPlaying: isPlaying, position: position, playlist: playlist) }, title: track?.title)
    }

    /// Settings' "Send a test status": the last song, or a sample, so the setup can be checked without playing anything.
    func sendTest() {
        let sample = lastTrack ?? Track(best: Listing(source: "jiosaavn", id: "test", title: "Test from NoNonsenseMusic", artists: ["NoNonsenseMusic"],
                                                      album: nil, duration: 200, popularity: nil, image: nil), listings: [])
        send(activity(for: sample, isPlaying: true, position: 0, playlist: lastPlaylist), title: sample.title)
    }

    /// What Discord gets for a song, following the share switches. nil clears the status.
    func activity(for track: Track, isPlaying: Bool, position: Double, playlist: String? = nil) -> DiscordIPC.Activity? {
        if !isPlaying {
            switch whenPaused {
            case "clear": return nil
            case "message":
                let text = pausedMessage.trimmingCharacters(in: .whitespaces)
                return .init(details: text.isEmpty ? "Nothing playing" : text, state: nil,
                             image: shareLogo ? Self.logoAsset : nil, imageText: shareLogo ? "NoNonsenseMusic" : nil,
                             smallImage: nil, smallText: nil,
                             start: nil, end: nil, statusLine: 2)       // the member list shows your message
            default: break                                           // "keep": the song below, without the time bar
            }
        }
        let start = Int(Date().timeIntervalSince1970) - Int(position)
        let timed = shareTime && isPlaying                    // a paused song has no running time bar
        let cover = shareArt ? track.best.image : nil         // nil when not shared, or when the song has none
        let badge = cover != nil && shareLogo                 // the logo badge only sits on a real cover
        let from = sharePlaylist ? playlist.map { "from “\($0)”" } : nil
        let byLine = shareArtist ? "by \(track.artistLine)" : nil
        return .init(details: shareSong ? track.title : nil,
                     state: [byLine, from].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                     image: cover ?? (shareLogo ? Self.logoAsset : nil),            // no cover: the logo is the picture
                     imageText: cover != nil ? track.best.album : (shareLogo ? "NoNonsenseMusic" : nil),
                     smallImage: badge ? Self.logoAsset : nil,
                     smallText: badge ? "NoNonsenseMusic" : nil,
                     start: timed ? start : nil,
                     end: timed ? start + track.duration : nil,
                     statusLine: statusLine)
    }

    private func resend() { update(lastTrack, isPlaying: last.isPlaying, position: last.position, playlist: lastPlaylist) }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        resend()
    }

    private static func flag(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private func send(_ activity: DiscordIPC.Activity?, title: String?) {
        let id = clientID
        attempts += 1
        let attempt = attempts
        Task {
            let result: String
            do {
                try await ipc.setActivity(activity, clientID: id)
                result = activity == nil ? "Connected, nothing playing" : "Showing “\(title ?? "")”"
            } catch let failure as DiscordIPC.Failure {
                switch failure {
                case .notRunning: result = "Discord isn't open"
                case .rejected(let reason): result = "Discord refused the ID: \(reason)"
                case .closed: result = "Discord closed the connection; it retries on the next song"
                case .timeout: result = "Discord didn't answer in 10 s; it tries again on the next song"
                case .discord(let message): result = "Discord said: \(message)"
                }
            } catch {
                result = "Couldn't reach Discord: \(error.localizedDescription)"
            }
            if attempt == attempts { status = result }        // an older, slower answer never overwrites a newer one
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
