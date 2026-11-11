import Foundation

/// Where the time goes when a song starts. A song that took "a fair while" left nothing to look at (7 Nov: the server was
/// healthy, the lookup took 1.4 s when tried afterwards, and the app logged nothing), so each start is timed in its
/// stages and written as one line to `playback.log` (Mac: ~/Library/Logs/NoNonsense/, as server.log; iPhone: the app's
/// support folder):
///
///     2026-11-11 12:03:04  ok      stream  ytmusic  link 0.52 s · ready 1.20 s · audio 1.45 s  “Whatchu Thought” (-lxJACRRNWQ)
///
///  - link: the copy's address arrived (YouTube: the lookup on this Mac; JioSaavn: the server's answer). "–" for a song
///    played from this device (`cache` or `file`).
///  - ready: the player had enough of the file to start. audio: sound was flowing (the spinner stopped).
///  - SLOW at the start of the line when it took 5 s or more; "failed: …" with the time it took when a copy did not
///    start (the next copy is a new line); "replaced" for a start you skipped after 2 s or more.
/// Titles stay on this device. The log is cut to its last part when it passes 400 KB.
@MainActor
final class StartTiming {
    static let shared = StartTiming()
    /// A start this long is SLOW in the log, and the player says it is still working.
    nonisolated static let slowSeconds = 5.0

    private struct Attempt {
        let title: String, source: String, copy: String
        let began = Date()
        var how = "stream"
        var link: Date?, ready: Date?
    }
    private var attempt: Attempt?

    /// A copy begins to load: an earlier one still open was skipped.
    func began(title: String, listing: Listing) {
        if let old = attempt, Date().timeIntervalSince(old.began) >= 2 { record(old, outcome: "replaced", audio: nil) }
        attempt = Attempt(title: title, source: listing.source, copy: listing.id)
    }
    /// "cache" or "file": played from this device, so there is no link to wait for.
    func how(_ kind: String) { attempt?.how = kind }
    func gotLink() { attempt?.link = Date() }
    func ready() { if attempt?.ready == nil { attempt?.ready = Date() } }
    /// Sound is flowing: the start is over.
    func audio() {
        guard let done = attempt else { return }
        attempt = nil
        record(done, outcome: "ok", audio: Date())
    }
    func failed(_ why: String) {
        guard let done = attempt else { return }
        attempt = nil
        record(done, outcome: "failed: " + why, audio: nil)
    }

    private func record(_ a: Attempt, outcome: String, audio: Date?) {
        let line = Self.line(at: Date(), title: a.title, source: a.source, copy: a.copy, how: a.how, outcome: outcome,
                             link: a.link.map { $0.timeIntervalSince(a.began) }, ready: a.ready.map { $0.timeIntervalSince(a.began) },
                             audio: audio.map { $0.timeIntervalSince(a.began) }, total: Date().timeIntervalSince(a.began))
        Self.append(line)
    }

    /// One log line. `link`, `ready` and `audio` are seconds from the start (nil: that stage did not happen); `total` is
    /// the whole time, for a failure that never reached audio.
    nonisolated static func line(at date: Date, title: String, source: String, copy: String, how: String, outcome: String,
                                 link: Double?, ready: Double?, audio: Double?, total: Double) -> String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "–" }
        let slow = (audio ?? total) >= slowSeconds ? "SLOW " : ""
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let end = audio.map { "audio \(seconds($0))" } ?? "after \(seconds(total))"
        return "\(formatter.string(from: date))  \(slow)\(outcome)  \(how)  \(source)  link \(seconds(link)) · ready \(seconds(ready)) · \(end)"
            + "  “\(title)” (\(copy))"
    }

    nonisolated static var logURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NN_PLAYBACK_LOG"] { return URL(filePath: path) }   // the writer's test
        #endif
        #if os(macOS)
        return URL.homeDirectory.appending(path: "Library/Logs/NoNonsense/playback.log")
        #else
        return URL.applicationSupportDirectory.appending(path: "NoNonsense/playback.log")
        #endif
    }

    /// One queue for every write: two on the concurrent queue raced to create the file, and one truncated the other (the
    /// writer's test, 11 Nov: the first of two lines was gone).
    private static let writer = DispatchQueue(label: "app.nononsense.starttiming", qos: .utility)

    private static func append(_ line: String) {
        #if DEBUG && os(macOS)
        if SelfTest.isRunning { return }                       // the self-tests play songs of their own
        #endif
        writer.async {
            let url = logURL, fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 400_000,
               let data = try? Data(contentsOf: url) {
                // the last 100 KB, from the start of a line
                let tail = data.suffix(100_000)
                let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
                try? Data(tail[start...]).write(to: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
