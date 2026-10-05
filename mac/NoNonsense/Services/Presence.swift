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
        let start: Int?             // unix seconds; with `end`, Discord draws a time bar
        let end: Int?
        let statusLine: Int         // what the member list shows: 0 the app's name, 1 `state`, 2 `details`
    }

    enum Failure: Error { case notRunning, rejected }

    private var fd: Int32 = -1
    private var connectedClientID: String?

    func setActivity(_ activity: Activity?, clientID: String) throws {
        try connect(clientID: clientID)
        var args: [String: Any] = ["pid": Int(getpid())]
        if let activity { args["activity"] = payload(activity) }      // no activity = clear the status
        try send(opcode: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString])
        _ = try receive()
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
            var timeout = timeval(tv_sec: 2, tv_usec: 0)                                           // never hang the app
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
        let (opcode, _) = try receive()
        guard opcode == 1 else { disconnect(); throw Failure.rejected }   // 2 = wrong Application ID
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
        guard written == frame.count else { disconnect(); throw Failure.notRunning }
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
            guard n > 0 else { disconnect(); throw Failure.notRunning }
            received += n
        }
        return data
    }
}

/// Discord status: the Settings switches, and `update`, which the player calls whenever playback changes.
@Observable
final class Presence {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "discordEnabled")
    private(set) var clientID = UserDefaults.standard.string(forKey: "discordClientID") ?? ""
    private(set) var status = "Off"
    private(set) var lastTrack: Track?                     // for the preview in Settings

    // What to share. Each change is saved and sent to Discord at once.
    var statusLine = UserDefaults.standard.object(forKey: "discordStatusLine") as? Int ?? 2 { didSet { save("discordStatusLine", statusLine) } }
    var shareSong = Presence.flag("discordShareSong") { didSet { save("discordShareSong", shareSong) } }
    var shareArtist = Presence.flag("discordShareArtist") { didSet { save("discordShareArtist", shareArtist) } }
    var shareArt = Presence.flag("discordShareArt") { didSet { save("discordShareArt", shareArt) } }
    var shareTime = Presence.flag("discordShareTime") { didSet { save("discordShareTime", shareTime) } }
    var showWhenPaused = Presence.flag("discordShowWhenPaused", default: false) { didSet { save("discordShowWhenPaused", showWhenPaused) } }

    @ObservationIgnored private let ipc = DiscordIPC()
    @ObservationIgnored private var last: (isPlaying: Bool, position: Double) = (false, 0)

    init() { status = enabled ? "Shows up when a song plays" : "Off" }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "discordEnabled")
        if on { resend() }
        else { status = "Off"; Task { try? await ipc.setActivity(nil, clientID: clientID); await ipc.disconnect() } }
    }

    func setClientID(_ id: String) {
        clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: "discordClientID")
        Task { await ipc.disconnect() }
        if enabled { resend() }
    }

    func update(_ track: Track?, isPlaying: Bool, position: Double) {
        lastTrack = track
        last = (isPlaying, position)
        guard enabled else { return }
        guard !clientID.isEmpty else { status = "Add your Discord Application ID"; return }
        send(track.flatMap { activity(for: $0, isPlaying: isPlaying, position: position) }, title: track?.title)
    }

    /// Settings' "Send a test status": the last song, or a sample, so the setup can be checked without playing anything.
    func sendTest() {
        guard !clientID.isEmpty else { status = "Add your Discord Application ID"; return }
        let sample = lastTrack ?? Track(best: Listing(source: "jiosaavn", id: "test", title: "Test from NoNonsense", artists: ["NoNonsense"],
                                                      album: nil, duration: 200, popularity: nil, image: nil), listings: [])
        send(activity(for: sample, isPlaying: true, position: 0), title: sample.title)
    }

    /// What Discord gets for a song, following the share switches. nil clears the status.
    func activity(for track: Track, isPlaying: Bool, position: Double) -> DiscordIPC.Activity? {
        guard isPlaying || showWhenPaused else { return nil }
        let start = Int(Date().timeIntervalSince1970) - Int(position)
        let timed = shareTime && isPlaying                    // a paused song has no running time bar
        return .init(details: shareSong ? track.title : nil,
                     state: shareArtist ? "by \(track.artistLine)" : nil,
                     image: shareArt ? track.best.image : nil,
                     imageText: shareArt ? track.best.album : nil,
                     start: timed ? start : nil,
                     end: timed ? start + track.duration : nil,
                     statusLine: statusLine)
    }

    private func resend() { update(lastTrack, isPlaying: last.isPlaying, position: last.position) }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        resend()
    }

    private static func flag(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private func send(_ activity: DiscordIPC.Activity?, title: String?) {
        let id = clientID
        Task {
            do {
                try await ipc.setActivity(activity, clientID: id)
                status = activity == nil ? "Connected, nothing playing" : "Showing “\(title ?? "")”"
            } catch DiscordIPC.Failure.rejected {
                status = "Discord rejected the Application ID"
            } catch {
                status = "Discord isn't running"
            }
        }
    }
}
