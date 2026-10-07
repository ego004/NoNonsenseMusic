import AppKit
import Darwin
import Observation

/// Starts your backend when the app opens and nothing answers at the server address, so you never have to remember.
/// Only for an address on this Mac. A server the app started is stopped when the app quits;
/// a server you started yourself (in a terminal) is found by its /health answer and left alone.
@Observable
final class ServerLauncher {
    /// The one launcher. SwiftUI may build an App's @State starting values more than once and keep one; a second
    /// launcher would add a second quit observer and could own a server nobody stops. One shared instance cannot.
    static let shared = ServerLauncher()

    enum State: Equatable {
        case checking
        case alreadyRunning          // something already answered /health
        case starting
        case started                 // the app started it, and it answers
        case notLocal                // the address is another machine: nothing to start here
        case failed(String)
    }

    private(set) var state: State = .checking
    @ObservationIgnored private var process: Process?
    /// A start in progress: a second ensureRunning() waits for it instead of starting a second server (which would
    /// lose the port race, die, and leave the app remembering the dead one while the first kept running).
    @ObservationIgnored private var starting: Task<Bool, Never>?

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Built from the home folder, so no user name is written in the code (the repo is public).
    static let defaultBackendFolder = home + "/projects/music/backend"
    static var backendFolder: String { UserDefaults.standard.string(forKey: "backendFolder") ?? defaultBackendFolder }
    /// The server's output. Opens in Console; or `tail -f ~/Library/Logs/NoNonsense/server.log` in a terminal.
    /// Self-tests write their test servers' output to server-selftest.log: they made over half of your log (7 Oct).
    static let logURL: URL = {
        var name = "server.log"
        #if DEBUG
        if SelfTest.isRunning { name = "server-selftest.log" }
        #endif
        return URL(filePath: home + "/Library/Logs/NoNonsense/" + name)
    }()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.note("app quitting: \(self?.process == nil ? "no server of ours to stop" : "stopping our server")")
                self?.stop()
            }
        }
    }

    var summary: String {
        switch state {
        case .checking: "Checking…"
        case .alreadyRunning: "Already running (not started by the app)"
        case .starting: "Starting…"
        case .started: "Started by the app; stops when the app quits"
        case .notLocal: "Off: the address is not this Mac"
        case .failed(let why): "Couldn't start: \(why)"
        }
    }

    /// Returns true once the server answers.
    @discardableResult
    func ensureRunning() async -> Bool {
        if let starting { return await starting.value }
        let attempt = Task { await startIfNeeded() }
        starting = attempt
        let ok = await attempt.value
        starting = nil
        return ok
    }

    /// Settings › Server › Reload when the backend's code changes. Off: one lean process. On: `fastapi dev`.
    static var reloads: Bool { UserDefaults.standard.bool(forKey: "serverReload") }

    private func startIfNeeded() async -> Bool {
        if process?.isRunning == true, await API.health() { state = .started; return true }
        state = .checking
        if await API.health() { state = .alreadyRunning; return true }
        guard let host = API.baseURL.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else { state = .notLocal; return false }
        if process?.isRunning == true { stop() }          // ours, but not answering: replace it rather than leave it running
        do { try await start(port: API.baseURL.port ?? 8000) } catch { state = .failed(error.localizedDescription); return false }
        state = .starting
        // the first start can take a while: uv checks the packages, the server opens the database pool
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if await API.health() { state = .started; return true }
            if process?.isRunning == false { state = .failed("the server exited, see the log"); return false }
        }
        state = .failed("no answer after 30 s, see the log")
        return false
    }

    private func start(port: Int) async throws {
        let fm = FileManager.default
        // an app opened from the Dock does not get your terminal's PATH, so look in the usual places
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", Self.home + "/.local/bin/uv", Self.home + "/.cargo/bin/uv"]
        guard let uv = candidates.first(where: fm.isExecutableFile) else { throw Failure("uv not found") }
        let folder = Self.backendFolder
        guard fm.fileExists(atPath: folder + "/pyproject.toml") else { throw Failure("no backend in \(folder)") }

        try fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        Self.trimLog()
        // O_APPEND: every write lands at the end. With a plain handle each writer kept its own position, so two
        // servers (8000 and a test one on 8765) and the app's own notes overwrote each other's lines (6 Oct).
        let fd = open(Self.logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw Failure("can't open the log") }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", Self.home + "/.local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let p = Process()
        p.currentDirectoryURL = URL(filePath: folder)
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        if Self.reloads {
            // `fastapi dev`: restarts on every save of the backend. Four processes, ~236 MB (measured 7 Oct)
            p.executableURL = URL(filePath: uv)
            p.arguments = ["run", "fastapi", "dev", "src/music_backend/main.py", "--port", String(port)]
        } else {
            // one process, ~96 MB (measured 7 Oct). `uv sync` first installs anything the backend newly needs (what
            // `uv run` did on every start), then exits; it does not stay behind holding 28 MB the way `uv run` did
            let sync = Process()
            sync.executableURL = URL(filePath: uv)
            sync.arguments = ["sync", "--quiet"]
            sync.currentDirectoryURL = URL(filePath: folder)
            sync.environment = env
            sync.standardOutput = log
            sync.standardError = log
            // the handler is set before the process starts: set after, a quick exit could resume this twice
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                sync.terminationHandler = { _ in done.resume() }
                do { try sync.run() } catch { sync.terminationHandler = nil; done.resume(throwing: error) }
            }
            let fastapi = folder + "/.venv/bin/fastapi"
            guard fm.isExecutableFile(atPath: fastapi) else { throw Failure("no .venv/bin/fastapi in \(folder): uv sync failed, see the log") }
            p.executableURL = URL(filePath: fastapi)
            // --host 127.0.0.1: on its own, `fastapi run` listens on every network this Mac is on
            p.arguments = ["run", "--host", "127.0.0.1", "src/music_backend/main.py", "--port", String(port)]
        }
        try p.run()
        process = p
        Self.note("started a server on port \(port) (\(Self.reloads ? "reloading on code changes" : "one process")): pid \(p.processIdentifier)")
    }

    /// Stops the server this app started, and starts it again (to apply a change of mode). A server you started
    /// yourself is left alone.
    func restart() async {
        guard process != nil else { return }
        stop()
        await ensureRunning()
    }

    /// The log only ever grew (1 MB in two days, 7 Oct): past 512 KB, keep its last 2,000 lines.
    private static func trimLog() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 512 * 1024,
              let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(2000).joined(separator: "\n")
        try? Data(("NoNonsense: log trimmed to its last 2,000 lines\n" + kept).utf8).write(to: logURL, options: .atomic)
    }

    /// Stops the server only if this app started it, with everything under it (in reload mode: `uv`, the `fastapi dev`
    /// reloader under it, and the worker under that). SIGTERM to `uv` alone usually stopped all three (5 Oct), but on 6 Oct the reloader outlived it, kept the
    /// port, and even ignored its own SIGTERM. So: SIGTERM to the whole family, up to 2 s to finish, then SIGKILL.
    func stop() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        let family = [p.processIdentifier] + Self.descendants(of: p.processIdentifier)
        for pid in family { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, family.contains(where: { kill($0, 0) == 0 }) { usleep(50_000) }
        let stubborn = family.filter { kill($0, 0) == 0 }
        for pid in stubborn { kill(pid, SIGKILL) }
        Self.note("stopped the server: pids \(family)\(stubborn.isEmpty ? "" : ", forced after 2 s: \(stubborn)")")
    }

    /// One line from the app itself into the server log, so the log tells the whole story of a server's life.
    private static func note(_ line: String) {
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(Data("NoNonsense: \(line)\n".utf8))
    }

    /// The server this app started, with every process under it (Settings › Footprint measures them). Empty when
    /// the app started none: a server you started yourself is not ours to measure.
    var serverPIDs: [pid_t] {
        guard let p = process, p.isRunning else { return [] }
        return [p.processIdentifier] + Self.descendants(of: p.processIdentifier)
    }

    /// Every process under `pid`: children, their children, and so on.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var waiting = [pid]
        while let parent = waiting.popLast() {
            let estimate = proc_listchildpids(parent, nil, 0)
            guard estimate > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(estimate) + 8)
            let n = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            let kids = children.prefix(Int(max(n, 0))).filter { $0 > 0 }
            found += kids
            waiting += kids
        }
        return found
    }
}
