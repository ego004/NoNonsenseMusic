import AppKit
import Observation

/// Starts your backend when the app opens and nothing answers at the server address, so you never have to remember.
/// Only for an address on this Mac. A server the app started is stopped when the app quits;
/// a server you started yourself (in a terminal) is found by its /health answer and left alone.
@Observable
final class ServerLauncher {
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

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Built from the home folder, so no user name is written in the code (the repo is public).
    static let defaultBackendFolder = home + "/projects/music/backend"
    static var backendFolder: String { UserDefaults.standard.string(forKey: "backendFolder") ?? defaultBackendFolder }
    /// The server's output. Opens in Console; or `tail -f ~/Library/Logs/NoNonsense/server.log` in a terminal.
    static let logURL = URL(filePath: home + "/Library/Logs/NoNonsense/server.log")

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
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
        if process?.isRunning == true, await API.health() { state = .started; return true }
        state = .checking
        if await API.health() { state = .alreadyRunning; return true }
        guard let host = API.baseURL.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else { state = .notLocal; return false }
        do { try start(port: API.baseURL.port ?? 8000) } catch { state = .failed(error.localizedDescription); return false }
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

    private func start(port: Int) throws {
        let fm = FileManager.default
        // an app opened from the Dock does not get your terminal's PATH, so look in the usual places
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", Self.home + "/.local/bin/uv", Self.home + "/.cargo/bin/uv"]
        guard let uv = candidates.first(where: fm.isExecutableFile) else { throw Failure("uv not found") }
        let folder = Self.backendFolder
        guard fm.fileExists(atPath: folder + "/pyproject.toml") else { throw Failure("no backend in \(folder)") }

        try fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: Self.logURL)
        log.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(filePath: uv)
        // `fastapi dev`: reloads when you edit the backend, and listens on 127.0.0.1 only
        // (`fastapi run` would listen on every network this Mac is on)
        p.arguments = ["run", "fastapi", "dev", "src/music_backend/main.py", "--port", String(port)]
        p.currentDirectoryURL = URL(filePath: folder)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", Self.home + "/.local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        try p.run()
        process = p
    }

    /// Stops the server only if this app started it. SIGTERM to `uv` also stops the server under it (checked 5 Oct 2026).
    func stop() {
        process?.terminate()
        process = nil
    }
}
