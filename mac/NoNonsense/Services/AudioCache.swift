import Foundation

/// Songs' audio kept on this Mac (8 Oct, TICKETS 0b): a song played before starts from its file, with no link lookup
/// and no network. Measured 8 Oct: a cold YouTube click took 0.73–0.93 s to sound (the link, a new connection to
/// YouTube's audio server, the player's own start); from a file a song starts in ~0.15 s. On by default (your choice,
/// 8 Oct), 500 MB (~120 songs); the least recently played go first past the limit. Settings › Footprint shows the size,
/// changes the limit (Off turns it off) and clears it. In Caches: macOS may empty it when the disk is full.
actor AudioCache {
    static let shared = AudioCache()
    static let defaultLimitMB = 500
    /// The limit in bytes; 0 = off.
    static var limit: Int { (UserDefaults.standard.object(forKey: "audioCacheMB") as? Int ?? defaultLimitMB) * 1_000_000 }

    nonisolated let folder: URL = {
        #if DEBUG
        // a self-test's own folder: the test app shares yours, and its eviction check must not empty it
        if let dir = ProcessInfo.processInfo.environment["NN_CACHE_DIR"] { return URL(filePath: dir) }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.nononsense.music/Audio")
    }()

    /// "ytmusic:J7p4bzqLvCw" → ".../ytmusic_J7p4bzqLvCw.m4a" (the extension tells AVPlayer what the file is)
    nonisolated func path(for key: String) -> URL {
        folder.appending(path: String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) + ".m4a")
    }

    /// The song's file, if it is here; marked as just played (eviction goes by that date).
    func file(for key: String) -> URL? {
        guard Self.limit > 0 else { return nil }
        let url = path(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// A whole song, fetched: kept, then the oldest removed past the limit.
    func store(_ data: Data, for key: String) {
        guard Self.limit > 0, !data.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: path(for: key), options: .atomic)
        evict()
    }

    /// A cached file that would not play: gone, so the next play fetches it again.
    func remove(_ key: String) { try? FileManager.default.removeItem(at: path(for: key)) }

    /// Bytes on disk.
    func size() -> Int { files().reduce(0) { $0 + $1.size } }

    func clear() { try? FileManager.default.removeItem(at: folder) }

    /// The least recently played first, until the rest fit the limit (a lowered limit applies at the next store).
    func evict() {
        var all = files().sorted { $0.used < $1.used }
        var total = all.reduce(0) { $0 + $1.size }
        while total > Self.limit, let oldest = all.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }

    private func files() -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
    }
}

/// One song's audio, fetched once from its start to its end in bounded ranges (YouTube sends an open-ended request at
/// about playback speed; a bounded one at full speed: 256 KB in ~70 ms, 8 Oct). The player is fed from it as the bytes
/// arrive (BoundedRangeLoader); a seek far past what has arrived is fetched on its own. Complete, it goes to the cache.
actor AudioDownload {
    nonisolated let key: String
    nonisolated let link: URL
    private var data = Data()
    private var length: Int?
    private var finished = false
    private var failure: Error?
    private var task: Task<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private static let session = URLSession(configuration: .ephemeral)

    init(key: String, link: URL) {
        self.key = key
        self.link = link
        // YouTube's links say the length (`clen`): the player is answered without a request
        length = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "clen" }?.value.flatMap(Int.init)
    }

    /// Starts fetching (once): the first range small, so sound can start, then 1 MB at a time.
    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        wake()
    }

    var isComplete: Bool { finished && failure == nil }

    /// The whole file's length (asks for the first range when the link does not say).
    func totalLength() async throws -> Int {
        start()
        while length == nil {
            if let failure { throw failure }
            if finished { break }
            await withCheckedContinuation { waiting.append($0) }
        }
        return length ?? data.count
    }

    /// Bytes `from`…`to`, both included, as soon as the first of them has arrived (possibly fewer than asked);
    /// empty past the end.
    func bytes(_ from: Int, _ to: Int) async throws -> Data {
        start()
        while true {
            if data.count > from { return data.subdata(in: from ..< min(to + 1, data.count)) }
            if let failure { throw failure }
            if finished || Task.isCancelled { return Data() }
            // a seek far ahead: fetched on its own, not waited for
            if from > data.count + 2 * BoundedRangeLoader.range { return try await Self.fetch(link, from: from, to: to).data }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func run() async {
        var size = BoundedRangeLoader.firstRange
        while !Task.isCancelled {
            let from = data.count
            if let length, from >= length { break }
            do {
                let piece = try await Self.fetch(link, from: from, to: from + size - 1)
                if length == nil { length = piece.total }
                if piece.data.isEmpty { break }
                data.append(piece.data)
                wake()
            } catch {
                failure = error
                break
            }
            size = BoundedRangeLoader.range
        }
        finished = true
        if failure == nil, !Task.isCancelled, let length, data.count >= length {
            await AudioCache.shared.store(data, for: key)
        }
        wake()
    }

    private func wake() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }

    /// One bounded range: bytes `from` to `to`, both included. `total`: the whole file's length, from Content-Range.
    static func fetch(_ link: URL, from: Int, to: Int) async throws -> (data: Data, total: Int?) {
        var request = URLRequest(url: link, timeoutInterval: 15)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, status == 206 || status == 200 else { throw URLError(.badServerResponse) }
        let total = (http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        return (data, total)
    }
}

/// The songs being fetched: the playing one, the next, and one more (an older one is stopped when a fourth starts).
actor AudioDownloads {
    static let shared = AudioDownloads()
    private var recent: [AudioDownload] = []

    func download(_ key: String, link: URL) -> AudioDownload {
        // the same song by the same link: the one already fetching (a new link, after a failure, starts afresh)
        if let i = recent.firstIndex(where: { $0.key == key && $0.link == link }) {
            let known = recent.remove(at: i)
            recent.append(known)
            return known
        }
        let fresh = AudioDownload(key: key, link: link)
        recent.append(fresh)
        if recent.count > 3 {
            let old = recent.removeFirst()
            Task { await old.cancel() }
        }
        return fresh
    }
}
