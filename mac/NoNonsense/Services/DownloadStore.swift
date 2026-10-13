import Foundation
import Observation

/// Songs kept on this Mac, to play without the server or the internet.
/// Files live in ~/Library/Application Support/NoNonsense/Downloads, with `index.json` beside them holding each
/// song's details, so the Downloads list works even when the server is off. A download is whatever `/play`
/// points to (this Mac has the server's IP, so YouTube's IP-bound URLs work too); the player plays the file
/// instead of asking the server. Self-tests use a separate folder.
@Observable
final class DownloadStore {
    struct Item: Codable, Identifiable {
        let key: String              // the downloaded copy: "source:id"
        let file: String             // its file name in the folder
        let best: Listing            // the song as the app shows it
        let listings: [Listing]
        /// The song's cover as shown when it was downloaded (nil in downloads made before covers were stored).
        var image: String? = nil
        let bytes: Int
        let added: Date
        var id: String { key }
    }

    /// Newest first.
    private(set) var items: [Item] = [] { didSet { index() } }
    /// The downloads by copy key and by cover address: every song row asks (twice) whether it is downloaded, and every
    /// cover not in memory whether a download kept it; a scan of every download each time (#12).
    @ObservationIgnored private var byKey: [String: Item] = [:]
    @ObservationIgnored private var byCover: [String: Item] = [:]

    private func index() {
        byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        byCover = Dictionary(items.compactMap { item in item.image.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
    }
    /// Songs being downloaded now (by Track.id): rows show a spinner.
    private(set) var inProgress: Set<String> = []

    @ObservationIgnored let folder: URL
    @ObservationIgnored private var indexURL: URL { folder.appending(path: "index.json") }
    /// Messages ("Downloaded …", "Couldn't download …") go through the library's message line.
    @ObservationIgnored var notify: (String, String) -> Void = { _, _ in }
    /// Called after each song is downloaded: the app saves its lyrics beside it (LyricsStore.keep).
    @ObservationIgnored var downloaded: (Track) -> Void = { _ in }

    init() {
        var name = "Downloads"
        #if DEBUG
        if SelfTest.isRunning { name = "Downloads-selftest" }   // a test must never touch your downloads
        #endif
        folder = URL.applicationSupportDirectory.appending(path: "NoNonsense/\(name)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // a file removed by hand is no longer a download
            items = saved.filter { FileManager.default.fileExists(atPath: folder.appending(path: $0.file).path) }
        }
    }

    var tracks: [Track] { items.map { Track(best: $0.best, listings: $0.listings, image: $0.image) } }
    var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    /// The downloaded item for this song, if any of its copies is downloaded.
    func item(for track: Track) -> Item? {
        // `listings` holds `best` too
        track.listings.lazy.compactMap { self.byKey[$0.key] }.first
    }

    func isDownloaded(_ track: Track) -> Bool { item(for: track) != nil }
    func isDownloading(_ track: Track) -> Bool { inProgress.contains(track.id) }

    /// The file for this song, and the copy it is.
    func file(for track: Track) -> (url: URL, listing: Listing)? {
        guard let item = item(for: track) else { return nil }
        let listing = track.listings.first { $0.key == item.key } ?? item.best
        return (folder.appending(path: item.file), listing)
    }

    /// The file for one copy, if that copy is the downloaded one.
    func localURL(for listing: Listing) -> URL? {
        byKey[listing.key].map { folder.appending(path: $0.file) }
    }

    /// Downloads the song: its best copy, else the others in turn. Says so when done or when no copy works.
    @discardableResult
    func download(_ track: Track, quietly: Bool = false) async -> Bool {
        guard !isDownloaded(track), !isDownloading(track) else { return true }
        inProgress.insert(track.id)
        defer { inProgress.remove(track.id) }
        for listing in [track.best] + track.listings.filter({ $0.key != track.best.key }) {
            do {
                let file = "\(listing.source)-\(listing.id)".replacingOccurrences(of: "/", with: "_") + ".m4a"
                let target = folder.appending(path: file)
                try? FileManager.default.removeItem(at: target)
                if let cached = await AudioCache.shared.file(for: listing.key) {
                    // played before: the whole song is already on this Mac
                    try FileManager.default.copyItem(at: cached, to: target)
                } else {
                    // fetched as playback fetches: bounded ranges at full speed. One open-ended request went at about
                    // playback speed on YouTube (a song took as long to download as to play)
                    let fetch = AudioDownload(key: listing.key, link: try await API.audioURL(listing), caches: false)
                    await fetch.whole()
                    guard let data = await fetch.contents() else { continue }
                    // a whole song, off the main thread (#12); a copy from the cache above is an APFS clone, instant
                    try await Task.detached(priority: .utility) { try data.write(to: target, options: .atomic) }.value
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
                items.insert(Item(key: listing.key, file: file, best: track.best, listings: track.listings,
                                  image: track.image?.absoluteString, bytes: bytes, added: .now), at: 0)
                save()
                if !quietly { notify("Downloaded “\(track.title)”", "arrow.down.circle.fill") }
                downloaded(track)
                if let saved = items.first { await keepCover(saved) }
                return true
            } catch {
                continue
            }
        }
        if !quietly { notify("Couldn't download “\(track.title)”: no copy could be fetched", "exclamationmark.triangle.fill") }
        return false
    }

    /// Downloads every song not downloaded yet, one at a time, then says how many.
    func download(all tracks: [Track], name: String) async {
        let missing = tracks.filter { !isDownloaded($0) }
        guard !missing.isEmpty else { notify("Everything in “\(name)” is downloaded", "arrow.down.circle.fill"); return }
        notify("Downloading \(missing.count) songs from “\(name)”…", "arrow.down.circle")
        var done = 0
        for track in missing where await download(track, quietly: true) { done += 1 }
        notify(done == missing.count ? "Downloaded “\(name)” (\(done) songs)" : "Downloaded \(done) of \(missing.count) songs from “\(name)”",
               done == missing.count ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
    }

    func remove(_ track: Track) {
        guard let item = item(for: track) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: item.file))
        try? FileManager.default.removeItem(at: lyricsURL(item))
        try? FileManager.default.removeItem(at: coverURL(item))
        items.removeAll { $0.key == item.key }
        save()
    }

    func removeAll() {
        for item in items {
            try? FileManager.default.removeItem(at: folder.appending(path: item.file))
            try? FileManager.default.removeItem(at: lyricsURL(item))
            try? FileManager.default.removeItem(at: coverURL(item))
        }
        items = []
        save()
    }

    /// The lyrics kept with a downloaded song (`<file>.lyrics.json`, beside it), so they show offline.
    func lyrics(for track: Track) -> Lyrics? {
        guard let item = item(for: track), let data = try? Data(contentsOf: lyricsURL(item)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    func saveLyrics(_ lyrics: Lyrics, for track: Track) {
        guard let item = item(for: track), let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: lyricsURL(item), options: .atomic)
    }

    private func lyricsURL(_ item: Item) -> URL { folder.appending(path: item.file + ".lyrics.json") }

    // MARK: covers kept with downloads
    // A downloaded song's cover is kept beside it (`<file>.cover`), and ArtworkCache reads it before the network. Before
    // 12 Oct covers showed offline only while URLSession's own HTTP cache (Cache.db, a few MB) still held them, and
    // macOS empties that cache when it likes.

    private func coverURL(_ item: Item) -> URL { folder.appending(path: item.file + ".cover") }

    /// The kept cover for this cover address, if a download has it.
    func keptCover(for image: URL) -> URL? {
        let address = image.absoluteString
        guard let item = byCover[address] else { return nil }
        let url = coverURL(item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func keepCover(_ item: Item) async {
        guard let address = item.image, let image = URL(string: address),
              !FileManager.default.fileExists(atPath: coverURL(item).path),
              let (data, response) = try? await URLSession.shared.data(from: image),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
        try? data.write(to: coverURL(item), options: .atomic)
    }

    /// Downloads made before covers were kept: each gets its cover once, while there is internet.
    func keepMissingCovers() async {
        for item in items { await keepCover(item) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }
}

/// "48 MB", "1.2 GB"
func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
