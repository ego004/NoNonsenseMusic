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
        let title: String
        let artists: String
        let album: String?
        let image: String?
        let start: Int          // unix seconds the song started (Discord draws a progress bar)
        let end: Int
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
        var activity: [String: Any] = [
            "type": 2,
            "details": padded(a.title),
            "state": padded("by \(a.artists)"),
            "timestamps": ["start": a.start, "end": a.end],
        ]
        var assets: [String: Any] = [:]
        if let image = a.image { assets["large_image"] = image }
        if let album = a.album { assets["large_text"] = padded(album) }
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

/// The Settings toggle and status line; the player calls `update` whenever playback changes.
@Observable
final class Presence {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "discordEnabled")
    private(set) var clientID = UserDefaults.standard.string(forKey: "discordClientID") ?? ""
    private(set) var status = "Off"

    @ObservationIgnored private let ipc = DiscordIPC()
    @ObservationIgnored private var last: (track: Track?, isPlaying: Bool, position: Double) = (nil, false, 0)

    init() { status = enabled ? "Shows up when a song plays" : "Off" }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "discordEnabled")
        if on { update(last.track, isPlaying: last.isPlaying, position: last.position) }
        else { status = "Off"; Task { try? await ipc.setActivity(nil, clientID: clientID); await ipc.disconnect() } }
    }

    func setClientID(_ id: String) {
        clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: "discordClientID")
        Task { await ipc.disconnect() }
        if enabled { update(last.track, isPlaying: last.isPlaying, position: last.position) }
    }

    func update(_ track: Track?, isPlaying: Bool, position: Double) {
        last = (track, isPlaying, position)
        guard enabled else { return }
        guard !clientID.isEmpty else { status = "Add your Discord Application ID"; return }
        let now = Int(Date().timeIntervalSince1970)
        let activity: DiscordIPC.Activity? = (track != nil && isPlaying) ? track.map {
            let start = now - Int(position)
            return .init(title: $0.title, artists: $0.artistLine, album: $0.best.album, image: $0.best.image,
                         start: start, end: start + $0.duration)
        } : nil                                           // paused or stopped: clear the status
        let id = clientID
        let title = track?.title
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
