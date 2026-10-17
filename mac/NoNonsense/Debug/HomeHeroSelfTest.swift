#if DEBUG
import AppKit
import AVFoundation

/// With `NN_SELFTEST_HOMEHERO=1` (and NN_SELFTEST_VISIBLE=1 with NN_SELFTEST_SNAP=<folder> for the window pictures and a
/// time that can tick): Home as in the Windows app (15 Oct). The greeting and Your Library's columns as rules; then,
/// at 1180×760 and 1600×1000, Home with nothing playing and with five made-up songs loaded and paused (the Now card,
/// Up Next under it or beside it), then playing: the time line must be the only part of Home that changes. The made-up
/// songs play a minute of silence put in the audio cache, so the player really loads, pauses and plays with no server
/// and no internet. Only the Resume card and Jump Back In's More arrow need songs the server knows (a search: the
/// internet); without them those checks are skipped, and say so.
extension SelfTest {
    private static var startedHomeHero = false
    /// Home's parts as they draw (they call `drew` from their bodies): how often each body ran, and what it showed last.
    static var homeDraws: [String: Int] = [:]
    static var homeShows: [String: String] = [:]
    /// Jump Back In's More arrow, as a click would press it (the shelf sets it): an invisible window takes no clicks.
    static var homeShelfMore: (() -> Void)?
    /// Where Jump Back In's clip view is, how wide, and its end, as AppKit has them (the shelf sets it).
    static var homeShelfReading: (() -> ShelfReading?)?

    static func drew(_ part: String, _ showing: String = "") {
        homeDraws[part, default: 0] += 1
        homeShows[part] = showing
    }

    static func runHomeHeroCheckIfAsked(player: Player, library: LibraryStore, downloads: DownloadStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_HOMEHERO"] != nil, !startedHomeHero else { return }
        startedHomeHero = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("homehero \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func skip(_ rule: String, _ why: String) { report("homehero SKIP \(rule): \(why)") }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }

            // the rules
            let greetings: [(hour: Int, name: String?, says: String)] = [
                (0, "sam", "Good night, Sam"), (4, "sam", "Good night, Sam"), (5, "sam", "Good morning, Sam"),
                (11, "sam", "Good morning, Sam"), (12, "sam", "Good afternoon, Sam"), (16, "sam", "Good afternoon, Sam"),
                (17, "sam", "Good evening, Sam"), (23, "sam", "Good evening, Sam"), (9, "mcKay", "Good morning, McKay"),
                (9, "élodie", "Good morning, Élodie"), (9, "", "Good morning"), (9, nil, "Good morning"),
            ]
            let wrong = greetings.filter { HomeView.greeting(hour: $0.hour, name: $0.name) != $0.says }
            check("the greeting: night before 5, morning before 12, afternoon before 17, then evening; the name with a capital first letter; no name, no comma",
                  wrong.isEmpty, wrong.map { "\($0.hour) h, \($0.name ?? "nil"): \(HomeView.greeting(hour: $0.hour, name: $0.name))" }.joined(separator: "; "))
            let columns: [(width: CGFloat, count: Int)] = [(500, 2), (899, 2), (900, 3), (1199, 3), (1200, 4), (1499, 4), (1500, 5), (2400, 5)]
            let off = columns.filter { TileGrid.columns(for: $0.width) != $0.count }
            check("Your Library: floor(width / 300) columns, never under 2 or over 5", off.isEmpty,
                  off.map { "\(Int($0.width)) pt: \(TileGrid.columns(for: $0.width))" }.joined(separator: "; "))

            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let root = window.contentView?.superview else { report("homehero: no window"); finishHomeHero(failures); return }
            borrowDefaults(["autoplay", "audioCacheMB", "shuffle"])
            UserDefaults.standard.set(false, forKey: "autoplay")              // Up Next stays the made-up songs
            UserDefaults.standard.removeObject(forKey: "audioCacheMB")        // the audio cache on, at its default size
            if !player.isMuted { player.toggleMute() }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            let saved = window.frame
            let sizes: [(width: CGFloat, height: CGFloat)] = [(1180, 760), (1600, 1000)]
            @MainActor func resize(_ width: CGFloat, _ height: CGFloat) async {
                window.setFrame(NSRect(x: saved.minX, y: saved.maxY - height, width: width, height: height), display: true)
                try? await Task.sleep(for: .seconds(1.2))
            }
            @MainActor func named(_ size: (width: CGFloat, height: CGFloat)) -> String { "\(Int(size.width))x\(Int(size.height))" }
            try? await Task.sleep(for: .seconds(1.5))

            // A. a new account, nothing played: nothing at Home's top
            if player.current == nil && library.recent.isEmpty {
                check("nothing played yet: no card at Home's top", homeDraws["home.now"] == nil && homeDraws["home.resume"] == nil)
            }

            // B. nothing playing, songs played before: the Resume card; Jump Back In's More arrow
            var played = false
            if await onOwnTestServer(), let found = try? await API.search("the weeknd"), found.songs.count >= 2 {
                for song in found.songs.prefix(14) { try? await API.event(song.listings, type: "play", position: 0) }
                await library.refreshRecent()
                played = !library.recent.isEmpty
            }
            if !played { skip("the Resume card and the More arrow", "no songs the server knows (no internet, or not this test's server)") }
            for size in sizes {
                await resize(size.width, size.height)
                if played {
                    check("\(named(size)), nothing playing: the Resume card, with the last song played",
                          frames["home.resume"] != nil && homeShows["home.resume"] == library.recent.first?.title, homeShows["home.resume"] ?? "no card")
                }
                windowShot("homehero-\(named(size))-nothing-playing")
            }
            if played {
                await resize(sizes[0].width, sizes[0].height)
                let count = min(20, library.recent.count)
                @MainActor func describe(_ r: ShelfReading?) -> String {
                    r.map { String(format: "at %.1f of %.1f, %.1f wide", $0.origin, $0.end, $0.width) } ?? "no reading"
                }
                // the covers' frames, for comparison: where the last one ends against the page's right margin
                @MainActor func lastCover() -> String {
                    guard let shelf = frames["home.recentShelf"], let last = frames["home.cover:\(count - 1)"] else { return "-" }
                    return String(format: "%.1f pt past the margin", last.maxX - shelf.maxX)
                }
                let rest = homeShelfReading?()
                report("homehero: shelf at rest: \(describe(rest)); the page \(Int(frames["home.recentShelf"]?.width ?? 0)) pt wide; last cover \(lastCover())")
                check("Jump Back In: the More arrow shows exactly while more lies to the right",
                      rest != nil && (homeShows["home.shelf"] == "more") == (rest.map { $0.origin < $0.end - 4 } ?? false),
                      "\(homeShows["home.shelf"] ?? "-"), \(describe(rest))")
                // the scroll view runs under the sidebar: a press is 80% of what shows between the margins, not of that
                let page = frames["home.recentShelf"]?.width ?? 0
                check("Jump Back In: what shows is the page's width between its margins", rest.map { abs($0.width - page) < 2 } ?? false,
                      "\(describe(rest)), the page \(Int(page)) pt")
                var presses = 0
                while homeShows["home.shelf"] == "more", presses < 8, let before = homeShelfReading?() {
                    homeShelfMore?()
                    try? await Task.sleep(for: .seconds(0.9))
                    presses += 1
                    let after = homeShelfReading?()
                    // 80% of what shows (the shelf runs a margin past the page on each side), or what is left
                    let expected = min(before.width * 0.8, before.end - before.origin)
                    let moved = (after?.origin ?? before.origin) - before.origin
                    report("homehero: press \(presses): \(describe(before)) → \(describe(after)); last cover \(lastCover())")
                    check("More, press \(presses): the shelf moves on by 80% of its width, or to its end", abs(moved - expected) < 2,
                          String(format: "moved %.1f pt, expected %.1f", moved, expected))
                }
                if presses == 0 {
                    skip("pressing More", "all \(count) songs fit in the shelf")
                } else {
                    let end = homeShelfReading?()
                    check("at the end, the More arrow is gone", homeShows["home.shelf"] == "end" && end.map { $0.origin >= $0.end - 4 } == true,
                          "\(homeShows["home.shelf"] ?? "-"), \(describe(end))")
                    windowShot("homehero-\(named(sizes[0]))-shelf-end")
                }
            }

            // C. five made-up songs, loaded and paused. Their audio: a minute of silence in the audio cache
            let songs = (1...5).map { n in
                Track(best: Listing(source: "jiosaavn", id: "selftest-home-\(n)", title: "Made-Up Song \(n)", artists: ["Self-test"],
                                    album: nil, duration: 60, popularity: nil, image: nil), listings: [])
            }
            do {
                let silence = FileManager.default.temporaryDirectory.appending(path: "nn-selftest-silence.m4a")
                try? FileManager.default.removeItem(at: silence)
                try writeSilence(to: silence, seconds: 60)
                try FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
                for song in songs {
                    let file = AudioCache.shared.path(for: song.best.key)
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.copyItem(at: silence, to: file)
                }
            } catch {
                report("homehero: could not write the made-up songs' audio: \(error.localizedDescription)")
            }
            player.playInOrder(songs)
            player.togglePlayPause()                                       // loaded, not playing
            _ = await until(5) { player.itemStatusForTests == "ready" }
            try? await Task.sleep(for: .seconds(1))
            check("five songs loaded, paused: the Now card says PAUSED, with the song's title",
                  !player.isPlaying && homeShows["home.now"] == "PAUSED · \(songs[0].title)", homeShows["home.now"] ?? "no Now card")
            check("the Up Next card begins with the next song", homeShows["home.upNext"] == songs[1].title, homeShows["home.upNext"] ?? "no Up Next card")
            check("the Downloads tile shows exactly while downloads are available", (frames["home.tile:Downloads"] != nil) == downloads.available)
            var widths: [CGFloat] = []
            for size in sizes {
                await resize(size.width, size.height)
                if let grid = frames["home.library"], let liked = frames["home.tile:Liked Songs"] {
                    let n = CGFloat(TileGrid.columns(for: grid.width))
                    check("\(named(size)): Your Library's tiles fill its columns, 12 apart", abs(liked.width - (grid.width - 12 * (n - 1)) / n) < 1,
                          String(format: "tile %.0f pt in %.0f pt, %.0f columns", liked.width, grid.width, n))
                }
                guard let hero = frames["home.hero"], let now = frames["home.now"], let next = frames["home.upNext"] else {
                    check("\(named(size)): the Now and Up Next cards are there", false); continue
                }
                widths.append(hero.width)
                if hero.width < HeroLayout.narrow {
                    check("\(named(size)), Home \(Int(hero.width)) pt wide: Up Next under the Now card, as wide",
                          next.minY >= now.maxY + 15 && abs(next.minX - now.minX) < 1 && abs(next.width - now.width) < 1,
                          "now \(now.integral), up next \(next.integral)")
                } else {
                    check("\(named(size)), Home \(Int(hero.width)) pt wide: Up Next beside the Now card, 3 : 2, one height",
                          next.minX >= now.maxX + 15 && abs(next.minY - now.minY) < 1 && abs(next.height - now.height) < 1
                              && abs(now.width / next.width - 1.5) < 0.02,
                          "now \(now.integral), up next \(next.integral)")
                }
                windowShot("homehero-\(named(size))-paused")
            }
            check("the two sizes show both layouts (under 900 pt and over)",
                  widths.contains { $0 < HeroLayout.narrow } && widths.contains { $0 >= HeroLayout.narrow }, "\(widths.map { Int($0) })")

            // D. playing: the time line is the only part of Home that changes
            player.togglePlayPause()
            let sounding = await until(6) { player.isPlaying && !player.isBuffering && player.livePosition > 0.2 }
            try? await Task.sleep(for: .seconds(1.5))                      // the label and the line settle
            check("playing: the Now card says NOW PLAYING", homeShows["home.now"] == "NOW PLAYING · \(songs[0].title)", homeShows["home.now"] ?? "no Now card")
            let line = descendants(of: root).compactMap { $0 as? TimelineLayersView }.first { $0.debugState.elapsed.contains(" / ") }
            check("Home's time line reads “m:ss / m:ss”, the song's length after the slash",
                  line?.debugState.elapsed.hasSuffix(" / \(formatTime(player.duration))") == true, line?.debugState.elapsed ?? "no time line")
            if sounding {
                let drawn = homeDraws, shown = line?.debugState.elapsed
                try? await Task.sleep(for: .seconds(3.2))
                let again = homeDraws.filter { drawn[$0.key] != $0.value }.map { $0.key }.sorted()
                check("while it plays, no part of Home is drawn again", again.isEmpty, again.joined(separator: ", "))
                check("the time line moves by itself: one Core Animation animation", line?.debugState.animating == true)
                if window.occlusionState.contains(.visible) {
                    check("…and its time changes by itself", line?.debugState.elapsed != shown, "\(shown ?? "-") → \(line?.debugState.elapsed ?? "-")")
                } else {
                    skip("the time changing", "the window cannot be seen (NN_SELFTEST_VISIBLE=1 shows it); the time changes only while it can")
                }
                player.showNowPlaying = true
                try? await Task.sleep(for: .seconds(1))
                check("under Now Playing, Home's line holds still", line?.debugState.animating == false)
                player.showNowPlaying = false
                try? await Task.sleep(for: .seconds(1))
            } else {
                skip("Home while playing", "the silent song did not start on this Mac (playing \(player.isPlaying), buffering "
                     + "\(player.isBuffering), at \(String(format: "%.1f", player.livePosition)) s)")
            }
            windowShot("homehero-\(named(sizes[1]))-playing")

            // E. the queue emptied: the Resume card again
            frames["home.now"] = nil
            frames["home.resume"] = nil
            homeShows["home.resume"] = nil
            player.stop()
            try? await Task.sleep(for: .seconds(1))
            if played {
                check("the queue empty, songs played before: the Resume card, no Now card",
                      frames["home.resume"] != nil && frames["home.now"] == nil && homeShows["home.resume"] == library.recent.first?.title,
                      homeShows["home.resume"] ?? "no card")
            }

            for song in songs { await AudioCache.shared.remove(song.best.key) }
            window.setFrame(saved, display: true)
            finishHomeHero(failures)
        }
    }

    /// `seconds` of silence as an AAC file: the made-up songs' audio.
    private static func writeSilence(to url: URL, seconds: Int) throws {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0,
                                                               AVNumberOfChannelsKey: 1])
        guard let second = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100),
              let samples = second.floatChannelData else { return }
        second.frameLength = 44_100
        samples[0].update(repeating: 0, count: 44_100)
        for _ in 0..<seconds { try file.write(from: second) }
    }

    private static func finishHomeHero(_ failures: Int) {
        returnDefaults()
        report("homehero: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
        NSApp.terminate(nil)
    }
}
#endif
