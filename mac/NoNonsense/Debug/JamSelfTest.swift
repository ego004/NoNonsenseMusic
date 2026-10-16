#if DEBUG
import AppKit

/// With `NN_SELFTEST_JAM=1` (this app's own test server; no internet: the songs are tones made here and played from the
/// audio cache): the scenarios of docs/jam.md, as backend/tests/test_jam.py and the Windows app's jam_test.dart run
/// them. A second account on the same server is the other member, over plain HTTP and a socket of its own. Muted; the
/// settings it changes are put back.
extension SelfTest {
    private static var startedJam = false

    static func runJamCheckIfAsked(player: Player, library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_JAM"] != nil, !startedJam else { return }
        startedJam = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("jam \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            @MainActor func notice(_ text: String) async -> Bool { await until(4) { library.message == text } }
            @MainActor func finish() {
                returnDefaults()
                report("jam: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer() else { report("jam: this app's own test server needed"); NSApp.terminate(nil); return }
            borrowDefaults(["jamRoom", "autoplay", "audioCacheMB"])
            UserDefaults.standard.set(false, forKey: "autoplay")                    // the room's queue stays as made here
            UserDefaults.standard.set(500, forKey: "audioCacheMB")                  // the songs play from the cache
            if !player.isMuted { player.toggleMute() }
            let jam = JamSession.shared

            // the songs: tones in the audio cache under made-up listings, 40 s each but one of 12 s (to end), and one with
            // no file at all, which will not play (the test server cannot find it)
            guard let long = tone(seconds: 40), let short = tone(seconds: 12) else { check("tones made with afconvert", false); finish(); return }
            let run = String(UInt32.random(in: 0 ... .max), radix: 16)
            @MainActor func song(_ name: String, _ seconds: Int, file: Data?) -> Listing {
                let listing = Listing(source: "jiosaavn", id: "selftest-jam-\(name)-\(run)", title: "Jam \(name)", artists: ["Self-Test"],
                                      album: nil, duration: seconds, popularity: nil, image: nil)
                if let file {
                    try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
                    try? file.write(to: AudioCache.shared.path(for: listing.key))
                }
                return listing
            }
            let a = song("a", 40, file: long), b = song("b", 40, file: long), c = song("c", 12, file: short)
            let e = song("e", 40, file: long), fallback = song("y", 40, file: long), missing = song("x", 40, file: nil)
            @MainActor func track(_ listing: Listing) -> Track { Track(best: listing, listings: [listing], choosingVersion: false) }

            // 1. Start with a song playing: the room starts with it, where it was, and it plays on
            player.play([track(a)])
            _ = await until(10) { player.isPlaying && player.livePosition > 3 }
            let before = player.livePosition
            check("1. Start a Jam with a song playing", await jam.start(named: nil) == nil && jam.isHost, jam.problem ?? "")
            check("1. …the room's song is the one playing, from where it was",
                  jam.state?.current?.listing.key == a.key && abs((jam.state?.positionSeconds ?? 0) - before) < 1.5,
                  "\(jam.state?.current?.listing.title ?? "-") at \(jam.state?.positionSeconds ?? -1) s, was \(before) s")
            check("1. …and it plays on, not loaded again", player.isPlaying && player.playingListing?.key == a.key
                  && player.livePosition >= before - 0.5, String(format: "%.1f s, was %.1f s", player.livePosition, before))
            check("(the room's socket connects)", await until(5) { jam.connectedForTests })

            // 3. The host's ⏯: the room and the player
            player.togglePlayPause()
            check("3. ⏯ by the host pauses the room and the player", await until(5) { jam.state?.isPlaying == false && !player.isPlaying })
            player.togglePlayPause()
            check("3. …and plays both again", await until(5) { jam.state?.isPlaying == true && player.isPlaying })

            // the other member: a second account, joined with the code, with its own socket
            guard let signedUp = try? await API.signUp("test-" + String(UInt32.random(in: 0 ... .max), radix: 16), testPassword,
                                                    device: "self-test"), let code = jam.state?.code, let room = jam.state?.roomID,
                  let me = jam.me?.uuidString.lowercased() else {
                check("a second account", false); finish(); return
            }
            let other = OtherMember(signedUp)
            check("(the second account joins with the code)", await other.call("POST", "jam/join", ["code": code]).status == 200)
            check("…and the host sees them at once", await until(3) { jam.state?.members.count == 2 })
            await other.connect(room)
            check("(their socket connects)", await until(5) { other.count("state") > 0 })

            // 3, 4, 5. A member's pause, play, seek and Next reach this Mac
            other.send(["type": "pause"])
            check("3. a member's pause pauses this Mac", await until(5) { !player.isPlaying && jam.state?.isPlaying == false })
            other.send(["type": "play"])
            check("3. …and their play plays it", await until(5) { player.isPlaying })
            other.send(["type": "seek", "seconds": 25])
            check("4. a member's seek moves this Mac there", await until(5) { abs(player.livePosition - 25) < JamSession.seekBeyond },
                  String(format: "%.1f s", player.livePosition))
            other.send(["type": "add", "listings": [json(b)]])
            _ = await until(3) { jam.state?.queue.first?.listing.key == b.key }
            other.send(["type": "skip"])
            check("5. a member's Next plays the room's next song here", await until(8) {
                player.playingListing?.key == b.key && player.isPlaying && !player.isBuffering })
            check("the member hears the host's playhead (a report every 15 s)", await until(20) { other.count("position") >= 1 },
                  "\(other.count("position")) reports")

            // 6. The song ends: the first device to finish moves the room on (the other member plays nothing here)
            player.play([track(c)])
            check("Play on a song plays it for the room at once", await until(5) { jam.state?.current?.listing.key == c.key })
            check("…and this Mac plays it", await until(5) { player.playingListing?.key == c.key && player.isPlaying })
            check("6. the song ends here: the room moves on, with no one pressing Next", await until(20) { jam.state?.current == nil },
                  jam.state?.current?.listing.title ?? "-")
            check("6. …the room empty, this Mac stops", await until(3) { !player.isPlaying })

            // 9 and 8. A copy that will not play: the next one does, from the room's playhead as it is when it is ready
            other.send(["type": "add", "listings": [json(missing)], "copies": [[json(fallback)]], "placement": "now"])
            check("9. a copy that will not play here: the next copy plays", await until(15) {
                player.playingListing?.key == fallback.key && player.isPlaying && !player.isBuffering })
            let drift = abs(player.livePosition - (jam.playhead ?? -100))
            check("8. …from where the room is now, not where it was when the load began", drift < 1.5, String(format: "%.1f s off", drift))
            check("9. …and the room was not skipped for everyone", jam.state?.current?.listing.key == missing.key)

            // 10. Reconnect: the socket drops; meanwhile the room pauses; connected again, this Mac follows
            jam.dropSocketForTests()
            _ = await until(2) { !jam.connectedForTests }
            other.send(["type": "pause"])
            check("10. after a dropped socket the app connects again", await until(8) { jam.connectedForTests })
            check("10. …and follows the room as it is now (paused meanwhile)", await until(3) { !player.isPlaying })
            other.send(["type": "play"])
            _ = await until(3) { player.isPlaying }

            // 7. The host hands the role on, then (12) controls the jam alone, then (11) removes this Mac
            if let member = jam.state?.members.first(where: { $0.userID == other.id }) { await jam.giveSpeakers(to: member) }
            check("7. the host hands over: this Mac is told who the host is now", await notice("“\(other.name)” is the host now."),
                  library.message ?? "-")
            check("7. …and plays on, in step, as a member", !jam.isHost && player.isPlaying)
            other.send(["type": "only_host_controls", "on": true])
            _ = await until(3) { jam.state?.onlyHostControls == true }
            let current = jam.state?.current?.entryID
            player.next()
            check("12. Only I control playback: a member's Next is not sent, and says why",
                  await notice(JamSession.lockedNotice) && jam.state?.current?.entryID == current, library.message ?? "-")
            player.play([track(e)])
            check("12. …and Play adds the song to the end", await until(3) { jam.state?.queue.last?.listing.key == e.key }
                  && library.message == "Added “Jam e” to the jam: the host controls this jam", library.message ?? "-")
            _ = await other.call("DELETE", "jam/\(room.uuidString.lowercased())/members/\(me)")
            let removed = await until(4) { !jam.inJam }
            check("11. removed by the host: out of the jam at once, and told",
                  await notice("The host removed you from the jam.") && removed, library.message ?? "-")
            check("11. …the song plays on, yours again", player.jam == nil && player.isPlaying)

            // 2. Join an empty room with a song playing: the room takes it, and Play and Pause then work (14 Oct)
            let empty = await other.call("POST", "jam", [:])
            let playing = player.playingListing?.key, at = player.livePosition
            check("2. join an empty room with a song playing", await jam.join(code: empty.json["code"] as? String ?? "") == nil)
            check("2. …the room takes it, from where it was", jam.state?.current?.listing.key == playing
                  && abs((jam.state?.positionSeconds ?? 0) - at) < 2, jam.state?.current?.listing.title ?? "-")
            check("2. …and it plays on", player.isPlaying && player.playingListing?.key == playing)
            _ = await until(5) { jam.connectedForTests }
            player.togglePlayPause()
            check("2. Pause in Now Playing pauses the room and this Mac", await until(5) { jam.state?.isPlaying == false && !player.isPlaying })
            player.togglePlayPause()
            check("2. Play in Now Playing plays them again (it did nothing, 14 Oct)",
                  await until(5) { jam.state?.isPlaying == true && player.isPlaying })

            // 7. The host leaves: this Mac is the host now, and told
            _ = await other.call("POST", "jam/\(empty.json["room_id"] as? String ?? "")/leave")
            let host = await until(4) { jam.isHost }
            check("7. the host leaves: this Mac is the host, and told",
                  await notice("“\(other.name)” left the jam. You're the host now.") && host, library.message ?? "-")

            // 2 and 8. Join a room playing another song: it loads here and starts where the room is, not behind (#28)
            let left = jam.state?.roomID.uuidString.lowercased() ?? ""
            let busy = await other.call("POST", "jam", ["song": ["listing": json(e), "copies": [Any](), "seconds": 20, "playing": true] as [String: Any]])
            check("2. join a room with a song", await jam.join(code: busy.json["code"] as? String ?? "") == nil)
            check("2. …its song plays here", await until(8) { player.playingListing?.key == e.key && player.isPlaying && !player.isBuffering })
            let behind = abs(player.livePosition - (jam.playhead ?? -100))
            check("8. …from the room's playhead", behind < 1.5, String(format: "%.1f s off", behind))
            let gone = await raw("GET", "jam/\(left)", token: API.token ?? "")
            check("…and the jam this Mac was in is left on the server too, not kept as a silent member", gone.status == 404, "\(gone.status)")

            // 11. Removed while the socket was down: connecting again, the room turns this Mac away; it leaves and says so
            // (#31 made Windows and Android say it; this Mac left without a word)
            _ = await until(5) { jam.connectedForTests }
            jam.dropSocketForTests()
            try? await Task.sleep(for: .milliseconds(300))
            _ = await other.call("DELETE", "jam/\(busy.json["room_id"] as? String ?? "")/members/\(me)")
            let turnedAway = await until(10) { !jam.inJam }
            check("11. turned away after a dropped connection: out of the jam, and told",
                  await notice(JamSession.endedNotice) && turnedAway, library.message ?? "-")

            // 11. Opened again in a jam that ended meanwhile: told, and forgotten
            UserDefaults.standard.set(UUID().uuidString, forKey: "jamRoom")
            await jam.resume()
            check("11. the app opened in a jam that is gone: told, and the room forgotten", await notice(JamSession.endedNotice)
                  && UserDefaults.standard.string(forKey: "jamRoom") == nil && !jam.inJam, library.message ?? "-")

            // Leave: the song plays on, yours
            _ = await jam.start(named: nil)
            snap("jam")
            await jam.leave()
            check("Leave: out of the jam, the player is yours again, the song plays on", !jam.inJam && player.jam == nil && player.isPlaying)
            other.close()
            for listing in [a, b, c, e, fallback] { try? FileManager.default.removeItem(at: AudioCache.shared.path(for: listing.key)) }
            finish()
        }
    }

    /// A listing as the server takes it in JSON (every field, missing ones as null).
    private static func json(_ listing: Listing) -> Any {
        (try? JSONEncoder().encode(listing)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
    }

    /// A tone of this many seconds as AAC in MP4, made with afconvert as the loader's test makes its file.
    private static func tone(seconds: Int) -> Data? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nn-jam-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 44100
        var wav = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = rate * seconds * 2
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(bytes)
        var samples = [Int16](repeating: 0, count: rate * seconds)
        for i in samples.indices { samples[i] = Int16(6000 * sin(Double(i) * 2 * .pi * 330 / Double(rate))) }
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        try? wav.write(to: dir.appending(path: "tone.wav"))
        let convert = Process()
        convert.executableURL = URL(filePath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "96000", dir.appending(path: "tone.wav").path, dir.appending(path: "tone.m4a").path]
        try? convert.run()
        convert.waitUntilExit()
        return try? Data(contentsOf: dir.appending(path: "tone.m4a"))
    }
}

/// The other member in the jam self-test: a second account on the same test server, over plain HTTP and a socket of its
/// own, keeping every message the room sends it.
@MainActor
private final class OtherMember {
    let token: String
    let id: UUID
    let name: String
    private var socket: URLSessionWebSocketTask?
    private(set) var messages: [String] = []

    init(_ session: SessionReply) {
        token = session.token
        id = session.user.id
        name = session.user.username
    }

    /// One request as this account: the status and the JSON object answered.
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> (status: Int, json: [String: Any]) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let reply = await SelfTest.raw(method, path, token: token, body: data)
        return (reply.status, (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:])
    }

    func connect(_ room: UUID) async {
        guard let ticket = await call("POST", "ws-ticket").json["ticket"] as? String,
              let url = API.socketURL("ws/jam", query: [URLQueryItem(name: "ticket", value: ticket),
                                                       URLQueryItem(name: "room_id", value: room.uuidString.lowercased())])
        else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        Task { [weak self] in
            while let message = try? await task.receive() {
                if case .string(let text) = message { self?.messages.append(text) }
            }
        }
    }

    func send(_ command: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    /// How many messages of this type the room has sent this member.
    func count(_ type: String) -> Int { messages.filter { $0.contains("\"type\":\"\(type)\"") }.count }

    func close() { socket?.cancel(with: .goingAway, reason: nil) }
}
#endif
