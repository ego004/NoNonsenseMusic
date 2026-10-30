import Foundation
#if os(macOS)
import AppKit
#endif
import Observation

/// Songs kept on this Mac, to play without the server or the internet.
/// The folder (`folder`: the one chosen in Settings › Footprint › Downloads, else
/// ~/Library/Application Support/NoNonsense/Downloads) holds only their audio, each file named after its song, so it
/// reads well in the Finder and can be shared with a Windows PC. The list of them, with each song's details, and their
/// kept covers and lyrics are the app's own, in `dataFolder`, named by the downloaded copy: a rename or a move never
/// touches them, and the Downloads list works even when the server is off. Before 15 Oct all of it lay in the folder
/// beside the audio (`moveDetailsOut`). A download is whatever `/play` points to (this Mac has the server's IP, so
/// YouTube's IP-bound URLs work too); the player plays the file instead of asking the server. The Windows app keeps
/// downloads by the same rules (core/download_store.dart). Self-tests use folders of their own.
@Observable
final class DownloadStore {
    struct Item: Codable, Identifiable {
        let key: String              // the downloaded copy: "source:id"
        /// Its name in the folder: the song's title ("source-id.m4a" before 15 Oct). A move to another folder may change it.
        var file: String
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
    /// File names given to downloads in progress (lower case), so two songs of one title never share one.
    @ObservationIgnored private var naming: Set<String> = []

    /// Where the songs' audio is. Nil while downloads are off: the chosen folder was not there.
    private(set) var folder: URL? = nil
    /// The chosen folder when it was not there at launch (its drive unplugged): downloads are off until it is back or
    /// another is chosen, and the list stays as it was. Dropping its songs as removed by hand would lose them all.
    private(set) var missingFolder: URL? = nil
    /// A downloads folder is in use: Download, the Downloads list and Show in Finder are offered only then.
    var available: Bool { folder != nil }
    /// Every download is moving to another folder (`moveTo`): new downloads refuse meanwhile.
    private(set) var moving = false
    /// Where songs download to when no folder is chosen.
    @ObservationIgnored let defaultFolder: URL
    /// The app's own folder for the list of downloads and their kept covers and lyrics.
    @ObservationIgnored let dataFolder: URL
    @ObservationIgnored private var indexURL: URL { dataFolder.appending(path: "index.json") }
    /// Messages ("Downloaded …", "Couldn't download …") go through the library's message line.
    @ObservationIgnored var notify: (String, String) -> Void = { _, _ in }
    /// Called after each song is downloaded: the app saves its lyrics with it (LyricsStore.keep).
    @ObservationIgnored var downloaded: (Track) -> Void = { _ in }

    /// The app's downloads: in the folder chosen in Settings › Footprint › Downloads (`downloadFolder`), else the app's
    /// own. A self-test has a pair of folders of its own and never reads your choice: a test must never touch your
    /// downloads.
    convenience init() {
        let app = URL.applicationSupportDirectory.appending(path: "NoNonsense")
        #if DEBUG && os(macOS)        // the self-tests are the Mac app's
        if SelfTest.isRunning {
            self.init(folder: nil, defaultFolder: app.appending(path: "Downloads-selftest"), dataFolder: app.appending(path: "DownloadData-selftest"))
            return
        }
        #endif
        let chosen = UserDefaults.standard.string(forKey: "downloadFolder") ?? ""     // empty: the app's own
        self.init(folder: chosen.isEmpty ? nil : URL(filePath: chosen), defaultFolder: app.appending(path: "Downloads"),
                  dataFolder: app.appending(path: "DownloadData"))
    }

    /// Downloads in `folder` (nil: `defaultFolder`), their list and details in `dataFolder`. Self-tests make stores on
    /// temporary folders with it.
    init(folder chosen: URL?, defaultFolder: URL, dataFolder: URL) {
        self.defaultFolder = defaultFolder
        self.dataFolder = dataFolder
        load(at: chosen ?? defaultFolder)
    }

    /// Opens the audio folder `audio` and reads the list. A folder that cannot be made (its drive unplugged) turns
    /// downloads off and leaves the list on disk as it is.
    private func load(at audio: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        do {
            try files.createDirectory(at: audio, withIntermediateDirectories: true)
        } catch {
            folder = nil
            missingFolder = audio
            items = []
            return
        }
        folder = audio
        missingFolder = nil
        moveDetailsOut(of: audio)
        let saved = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        // a file removed by hand is no longer a download, and its kept cover and lyrics go
        var kept: [Item] = []
        for item in saved {
            if files.fileExists(atPath: audio.appending(path: item.file).path) { kept.append(item) } else { forgetDetails(item) }
        }
        items = kept
    }

    /// Downloads from before 15 Oct: the list, covers and lyrics lay in the folder beside the audio, and each file was
    /// named "source-id.m4a". The details move to the data folder and the files take their songs' names, once: after it
    /// the folder holds no list. A file that cannot be renamed now keeps its old name.
    private func moveDetailsOut(of folder: URL) {
        let files = FileManager.default
        let old = folder.appending(path: "index.json")
        guard files.fileExists(atPath: old.path), !files.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: old), var found = try? JSONDecoder().decode([Item].self, from: data) else { return }
        var taken = Set<String>()
        for position in found.indices {
            let item = found[position]
            try? files.moveItem(at: folder.appending(path: item.file + ".cover"), to: coverURL(item))
            try? files.moveItem(at: folder.appending(path: item.file + ".lyrics.json"), to: lyricsURL(item))
            let audio = folder.appending(path: item.file)
            guard files.fileExists(atPath: audio.path) else { continue }
            let name = Self.freeName(title: item.best.title, artists: item.best.artists, in: folder, taken: &taken)
            do {
                try files.moveItem(at: audio, to: folder.appending(path: name))
                found[position].file = name
            } catch {}                                                   // in use: it keeps its old name
        }
        // the details of songs no longer in the list (their audio removed by hand): nothing else in the folder is the app's
        let leftovers = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".m4a.cover") || $0.hasSuffix(".m4a.lyrics.json") }
        for name in leftovers { try? files.removeItem(at: folder.appending(path: name)) }
        write(found)
        try? files.removeItem(at: old)
    }

    // MARK: - file names

    /// `title` as a file name every system takes: the characters Windows forbids become their full-width look-alikes
    /// ("Why？", as yt-dlp names them), and a name Windows keeps for a device ("CON") or ending in a dot is mended, so
    /// the folder can be shared with a Windows PC.
    nonisolated static func fileTitle(_ title: String) -> String {
        let lookalike: [Unicode.Scalar: Unicode.Scalar] = ["<": "＜", ">": "＞", ":": "：", "\"": "＂", "/": "⧸", "\\": "⧹",
                                                           "|": "｜", "?": "？", "*": "＊"]
        var scalars = String.UnicodeScalarView()
        for c in title.unicodeScalars where c.value >= 0x20 { scalars.append(lookalike[c] ?? c) }   // control characters go
        var s = String(scalars).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.utf16.count > 120 {
            var units = Array(s.utf16.prefix(120))
            if 0xD800...0xDBFF ~= units[119] { units.removeLast() }                     // half a character
            s = String(decoding: units, as: UTF16.self)
        }
        s = s.replacingOccurrences(of: "[. ]+$", with: "", options: .regularExpression)
        if s.isEmpty { return "Song" }
        let stem = s.prefix { $0 != "." }.trimmingCharacters(in: .whitespaces)
        let device = stem.range(of: "^(con|prn|aux|nul|com[1-9]|lpt[1-9])$", options: [.regularExpression, .caseInsensitive]) != nil
        return device ? s + " (song)" : s
    }

    /// A name for a song's file that nothing in `folder` has: its title; when another song of that title is there, with
    /// its artists too; then numbered. A `<name>.part` file (a Windows PC sharing the folder, writing that song) takes
    /// the name too, and so does `taken`: names given to downloads not written yet (lower case), the new one added.
    nonisolated static func freeName(title: String, artists: [String], in folder: URL, taken: inout Set<String>) -> String {
        let given = taken
        func isFree(_ name: String) -> Bool {
            !given.contains(name.lowercased())
                && !FileManager.default.fileExists(atPath: folder.appending(path: name).path)
                && !FileManager.default.fileExists(atPath: folder.appending(path: name + ".part").path)
        }
        let plain = fileTitle(title)
        let named = artists.isEmpty ? plain : fileTitle("\(title) - \(artists.joined(separator: ", "))")
        var name = plain + ".m4a"
        if !isFree(name) { name = named + ".m4a" }
        var number = 2
        while !isFree(name) {
            name = "\(named) (\(number)).m4a"
            number += 1
        }
        taken.insert(name.lowercased())
        return name
    }

    // MARK: - moving to another folder

    /// Why `moveTo` refused.
    struct Busy: LocalizedError {
        var errorDescription: String? { "songs are downloading or moving" }
    }

    /// Moves every download to `target`, the folder chosen in Settings › Footprint › Downloads, where new downloads then
    /// go. Each file keeps its song's name unless a file of that name is there already. The files move off the main
    /// thread (to another disk they are copied); meanwhile `moving` is set and new downloads refuse. On a failure the
    /// files moved so far go back, last first, and it throws. Refused while songs download or another move runs.
    func moveTo(_ target: URL) async throws {
        guard inProgress.isEmpty, !moving else { throw Busy() }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // the chosen folder was not there at launch: the list is read again for the new one
        guard let from = folder else { load(at: target); return }
        guard !Self.isSameFolder(from, target) else { return }
        moving = true
        defer { moving = false }
        let songs = items.map { (file: $0.file, title: $0.best.title, artists: $0.best.artists) }
        let keys = items.map(\.key)
        let names = try await Task.detached(priority: .utility) { try DownloadStore.moveFiles(songs, from: from, to: target) }.value
        let renamed = Dictionary(zip(keys, names), uniquingKeysWith: { first, _ in first })
        items = items.map { item in
            var item = item
            item.file = renamed[item.key] ?? item.file
            return item
        }
        folder = target
        save()
    }

    /// Moves each song's file to `to` under a free name there, in order, and returns the new names. On a failure the
    /// files moved so far go back to their old names, last first, and it throws.
    private nonisolated static func moveFiles(_ songs: [(file: String, title: String, artists: [String])], from: URL, to: URL) throws -> [String] {
        var names: [String] = [], taken = Set<String>()
        do {
            for song in songs {
                let name = freeName(title: song.title, artists: song.artists, in: to, taken: &taken)
                try FileManager.default.moveItem(at: from.appending(path: song.file), to: to.appending(path: name))
                names.append(name)
            }
            return names
        } catch {
            for (song, name) in zip(songs, names).reversed() {
                try? FileManager.default.moveItem(at: to.appending(path: name), to: from.appending(path: song.file))
            }
            throw error
        }
    }

    /// One folder under two paths (a link, or other capitals on a disk that ignores case)?
    private static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        let ids = [a, b].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier }
        guard let first = ids[0], let second = ids[1] else { return false }
        return first.isEqual(second)
    }

    // MARK: - songs

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
        guard let folder, let item = item(for: track) else { return nil }
        let listing = track.listings.first { $0.key == item.key } ?? item.best
        return (folder.appending(path: item.file), listing)
    }

    /// The file for one copy, if that copy is the downloaded one.
    func localURL(for listing: Listing) -> URL? {
        guard let folder else { return nil }
        return byKey[listing.key].map { folder.appending(path: $0.file) }
    }

    /// The song's file in the Finder, selected (its menu › Show in Finder). Nothing when it is not downloaded.
    func revealInFinder(_ track: Track) {
        guard let url = file(for: track)?.url else { return }
        #if DEBUG && os(macOS)        // the self-tests are the Mac app's
        if SelfTest.isRunning { SelfTest.revealed = url; return }          // a test opens no Finder windows
        #endif
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Downloads the song: its best copy, else the others in turn. Says so when done or when no copy works. Refuses
    /// while downloads are off or moving to another folder.
    @discardableResult
    func download(_ track: Track, quietly: Bool = false) async -> Bool {
        guard let folder, !moving else { return false }
        guard !isDownloaded(track), !isDownloading(track) else { return true }
        inProgress.insert(track.id)
        let file = Self.freeName(title: track.title, artists: track.artists, in: folder, taken: &naming)
        defer {
            inProgress.remove(track.id)
            naming.remove(file.lowercased())
        }
        let target = folder.appending(path: file)
        for listing in [track.best] + track.listings.filter({ $0.key != track.best.key }) {
            do {
                try? FileManager.default.removeItem(at: target)                // what a copy that failed left
                if let cached = await AudioCache.shared.file(for: listing.key) {
                    // played before: the whole song is already on this Mac. On the same disk the copy is an APFS clone,
                    // instant; to a folder on another disk it is a real copy, off the main thread
                    try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: cached, to: target) }.value
                } else {
                    // fetched as playback fetches: bounded ranges at full speed. One open-ended request went at about
                    // playback speed on YouTube (a song took as long to download as to play)
                    let fetch = AudioDownload(key: listing.key, link: try await API.audioURL(listing), caches: false)
                    await fetch.whole()
                    guard let data = await fetch.contents() else { continue }
                    // a whole song, off the main thread (#12)
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
        guard let folder, let item = item(for: track) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: item.file))
        forgetDetails(item)
        items.removeAll { $0.key == item.key }
        save()
    }

    func removeAll() {
        guard let folder else { return }                    // downloads off: the list is kept for when the folder is back
        for item in items {
            try? FileManager.default.removeItem(at: folder.appending(path: item.file))
            forgetDetails(item)
        }
        items = []
        save()
    }

    // MARK: - details kept with downloads
    // A downloaded song's cover and lyrics are kept in the data folder, named by the downloaded copy's key with every
    // character but letters, digits and "-" as "_" ("jiosaavn:a" → jiosaavn_a.cover, jiosaavn_a.lyrics.json).
    // ArtworkCache reads the cover before the network. Before 12 Oct covers showed offline only while URLSession's own
    // HTTP cache (Cache.db, a few MB) still held them, and macOS empties that cache when it likes.

    private func detailsName(_ item: Item) -> String {
        item.key.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "_", options: .regularExpression)
    }
    private func coverURL(_ item: Item) -> URL { dataFolder.appending(path: detailsName(item) + ".cover") }
    private func lyricsURL(_ item: Item) -> URL { dataFolder.appending(path: detailsName(item) + ".lyrics.json") }

    /// Its kept cover and lyrics go.
    private func forgetDetails(_ item: Item) {
        try? FileManager.default.removeItem(at: coverURL(item))
        try? FileManager.default.removeItem(at: lyricsURL(item))
    }

    /// The lyrics kept with a downloaded song, so they show offline.
    func lyrics(for track: Track) -> Lyrics? {
        guard let item = item(for: track), let data = try? Data(contentsOf: lyricsURL(item)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    func saveLyrics(_ lyrics: Lyrics, for track: Track) {
        guard let item = item(for: track), let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: lyricsURL(item), options: .atomic)
    }

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

    private func save() { write(items) }

    private func write(_ list: [Item]) {
        do {
            try JSONEncoder().encode(list).write(to: indexURL, options: .atomic)
        } catch {
            // the list is what the next launch knows the downloads by: a full disk used to lose them without a word
            notify("Couldn't save the list of downloads: \(error.localizedDescription)", "exclamationmark.triangle.fill")
        }
    }
}

/// "48 MB", "1.2 GB"
func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
