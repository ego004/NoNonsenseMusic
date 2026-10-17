#if DEBUG
import AppKit

/// With `NN_SELFTEST_DOWNLOADFILES=1` (no network; the window can stay invisible): downloads as files (15 Oct), by the
/// rules the Windows app's download_files_test.dart checks, on stores of their own in a temporary folder (never your
/// downloads): file names from song titles, two songs of one title, the move from the old layout, a move to another
/// folder and its rollback, a chosen folder that is not there, Show in Finder; then Settings › Footprint › Downloads
/// shows the folder in use. With `NN_SELFTEST_SNAP=<folder>` that Settings page is drawn to `downloads-settings.png`.
extension SelfTest {
    static func runDownloadFilesCheckIfAsked(downloads: DownloadStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_DOWNLOADFILES"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("downloadfiles \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let files = FileManager.default
            let temp = files.temporaryDirectory.appending(path: "nn-downloadfiles-\(UUID().uuidString)")
            @MainActor func finish() {
                try? files.removeItem(at: temp)
                returnDefaults()
                report("downloadfiles: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            @MainActor func names(_ folder: URL) -> [String] { ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
            /// A made-up song with one copy and no cover: nothing here asks the network.
            @MainActor func song(_ id: String, _ title: String, _ artists: [String]) -> Track {
                let copy = Listing(source: "jiosaavn", id: id, title: title, artists: artists, album: nil, duration: 200, popularity: nil, image: nil)
                return Track(best: copy, listings: [copy])
            }

            // 1. a file is named after its song, with what Windows forbids swapped for look-alikes
            let examples = [("Blinding Lights", "Blinding Lights"), ("Who Am I?", "Who Am I？"),
                            ("AC/DC: \"Live\" | *1991*", "AC⧸DC： ＂Live＂ ｜ ＊1991＊"), ("  Hello,   Goodbye  ", "Hello, Goodbye"),
                            ("Mr.", "Mr"), ("CON", "CON (song)"), ("...", "Song")]
            for (title, name) in examples {
                let got = DownloadStore.fileTitle(title)
                check("“\(title)” is named “\(name)”", got == name, got)
            }
            check("a long title is cut at 120 characters", DownloadStore.fileTitle(String(repeating: "a", count: 300)).utf16.count == 120)
            check("… never in the middle of one", DownloadStore.fileTitle(String(repeating: "a", count: 119) + "😀") == String(repeating: "a", count: 119))

            // 2. two songs of one title: the second takes its artists; the folder holds only their audio. Each download
            // copies a made-up file from the audio cache, as a song played before does
            let folder = temp.appending(path: "Downloads"), details = temp.appending(path: "DownloadData")
            let kanye = song("selftest-a", "Heartless", ["Kanye West"]), weeknd = song("selftest-b", "Heartless", ["The Weeknd"])
            borrowDefaults(["audioCacheMB"])
            UserDefaults.standard.set(500, forKey: "audioCacheMB")               // the cache on, whatever you chose
            try? files.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
            for track in [kanye, weeknd] { try? Data(repeating: 7, count: 1000).write(to: AudioCache.shared.path(for: track.best.key)) }
            let store = DownloadStore(folder: folder, defaultFolder: folder, dataFolder: details)
            let first = await store.download(kanye, quietly: true)
            let second = await store.download(weeknd, quietly: true)
            for track in [kanye, weeknd] { await AudioCache.shared.remove(track.best.key) }
            check("two songs called Heartless: Heartless.m4a, then Heartless - The Weeknd.m4a, and nothing else in the folder",
                  first && second && names(folder) == ["Heartless - The Weeknd.m4a", "Heartless.m4a"], names(folder).joined(separator: ", "))
            check("… each plays from its own file", store.file(for: kanye)?.url.lastPathComponent == "Heartless.m4a"
                  && store.file(for: weeknd)?.url.lastPathComponent == "Heartless - The Weeknd.m4a")
            store.saveLyrics(Lyrics(lyricsSource: "lrclib", synced: false, lines: [LyricLine(startMs: nil, text: "a line")]), for: kanye)
            check("the list and the lyrics are the app's own, named by the copy", names(details) == ["index.json", "jiosaavn_selftest-a.lyrics.json"],
                  names(details).joined(separator: ", "))
            let restarted = DownloadStore(folder: folder, defaultFolder: folder, dataFolder: details)
            check("a restart finds both, and the lyrics", restarted.items.map(\.file) == ["Heartless - The Weeknd.m4a", "Heartless.m4a"]
                  && restarted.lyrics(for: kanye)?.lines.first?.text == "a line")

            // 3. what takes a name: a file, a `.part` file, a download not written yet (whatever its case)
            let clash = temp.appending(path: "Clash")
            try? files.createDirectory(at: clash, withIntermediateDirectories: true)
            try? Data().write(to: clash.appending(path: "Blinding Lights.m4a.part"))
            var none = Set<String>()
            let partName = DownloadStore.freeName(title: "Blinding Lights", artists: ["The Weeknd"], in: clash, taken: &none)
            check("a name a Windows PC is downloading to (.part) is taken", partName == "Blinding Lights - The Weeknd.m4a", partName)
            var holding: Set<String> = ["intro.m4a"]
            let numbered = DownloadStore.freeName(title: "Intro", artists: [], in: clash, taken: &holding)
            check("a name given to a download not written yet is taken, whatever its case; with no artists the next is numbered",
                  numbered == "Intro (2).m4a" && holding.contains("intro (2).m4a"), numbered)

            // 4. downloads from before 15 Oct: their details move out, their files take their songs' names, once
            let old = temp.appending(path: "Old"), oldData = temp.appending(path: "OldData")
            try? files.createDirectory(at: old, withIntermediateDirectories: true)
            let lights = song("selftest-c", "Blinding Lights", ["The Weeknd"]), whoAmI = song("selftest-d", "Who Am I?", [])
            let before = [lights, whoAmI].map {
                DownloadStore.Item(key: $0.best.key, file: "jiosaavn-\($0.best.id).m4a", best: $0.best, listings: $0.listings,
                                   image: "http://img.test/\($0.best.id).jpg", bytes: 3, added: .now)
            }
            try? JSONEncoder().encode(before).write(to: old.appending(path: "index.json"))
            for item in before {
                try? Data([1, 2, 3]).write(to: old.appending(path: item.file))
                try? Data([9]).write(to: old.appending(path: item.file + ".cover"))
            }
            try? JSONEncoder().encode(Lyrics(lyricsSource: "lrclib", synced: false, lines: [LyricLine(startMs: nil, text: "kept")]))
                .write(to: old.appending(path: "jiosaavn-selftest-c.m4a.lyrics.json"))
            // a song whose audio was removed by hand left its details behind
            try? Data([9]).write(to: old.appending(path: "jiosaavn-gone.m4a.cover"))
            try? Data("{}".utf8).write(to: old.appending(path: "jiosaavn-gone.m4a.lyrics.json"))
            let migrated = DownloadStore(folder: old, defaultFolder: old, dataFolder: oldData)
            let renamed = ["Blinding Lights.m4a", "Who Am I？.m4a"]
            check("the old files take their songs' names, and the old list leaves the folder", names(old) == renamed, names(old).joined(separator: ", "))
            check("covers and lyrics move to the data folder, named by the copy; those of songs gone are deleted",
                  names(oldData) == ["index.json", "jiosaavn_selftest-c.cover", "jiosaavn_selftest-c.lyrics.json", "jiosaavn_selftest-d.cover"],
                  names(oldData).joined(separator: ", "))
            let audio = migrated.file(for: lights).flatMap { try? Data(contentsOf: $0.url) }
            let cover = migrated.keptCover(for: URL(string: "http://img.test/selftest-d.jpg")!).flatMap { try? Data(contentsOf: $0) }
            check("… and each is still found: the audio, the lyrics, the cover", migrated.items.count == 2 && audio == Data([1, 2, 3])
                  && migrated.lyrics(for: lights)?.lines.first?.text == "kept" && cover == Data([9]))
            check("once: a second start finds it done",
                  DownloadStore(folder: old, defaultFolder: old, dataFolder: oldData).items.map(\.file).sorted() == renamed)

            // 5. a move to another folder takes every file there, under its song's name, and the list follows
            let music = temp.appending(path: "Music")
            do {
                try await migrated.moveTo(music)
                check("a move takes every file to the new folder, under its song's name",
                      names(music) == renamed && names(old).isEmpty && migrated.folder == music, names(music).joined(separator: ", "))
                check("… the songs play from there, and a restart there finds them",
                      migrated.file(for: lights).map { files.fileExists(atPath: $0.url.path) } == true
                      && DownloadStore(folder: music, defaultFolder: old, dataFolder: oldData).items.count == 2)
            } catch {
                check("a move to another folder", false, error.localizedDescription)
            }

            // 6. a move that fails midway (the second song's file went missing): what moved goes back, and it throws
            let order = migrated.items.map(\.file)                                  // the order the files move in
            if order.count == 2 {
                let elsewhere = temp.appending(path: "Elsewhere")
                try? files.removeItem(at: music.appending(path: order[1]))
                var threw = false
                do { try await migrated.moveTo(elsewhere) } catch {
                    threw = true
                    report("downloadfiles: the failed move said: \(error.localizedDescription)")
                }
                check("a move that fails midway throws", threw)
                check("… the file it had moved goes back, under its old name", names(music) == [order[0]] && names(elsewhere).isEmpty,
                      "\(names(music)) and \(names(elsewhere))")
                check("… and the downloads stay where they were", migrated.folder == music && migrated.items.map(\.file) == order && !migrated.moving)
            } else {
                check("two downloads to move", false, "\(order.count)")
            }

            // 7. Show in Finder: the song's own file, selected; nothing for a song not downloaded
            revealed = nil
            migrated.revealInFinder(lights)
            check("Show in Finder selects the song's file", revealed != nil && revealed == migrated.file(for: lights)?.url
                  && revealed.map { files.fileExists(atPath: $0.path) } == true)
            revealed = nil
            migrated.revealInFinder(kanye)
            check("… and shows nothing for a song not downloaded", revealed == nil)
            check("available: a downloads folder is in use", migrated.available)

            // 8. a chosen folder that is not there (its drive unplugged): downloads off, the list left as it was
            let list = try? Data(contentsOf: oldData.appending(path: "index.json"))
            let blocked = temp.appending(path: "not a folder")
            try? Data().write(to: blocked)
            let unplugged = blocked.appending(path: "Music")                     // under a file: it cannot be made
            let gone = DownloadStore(folder: unplugged, defaultFolder: old, dataFolder: oldData)
            check("a folder that cannot be made turns downloads off", !gone.available && gone.missingFolder == unplugged && gone.items.isEmpty)
            let refused = await gone.download(lights, quietly: true)
            gone.revealInFinder(lights)
            check("… a download refuses, Show in Finder shows nothing", !refused && revealed == nil)
            check("… and the list is left as it was", list != nil && (try? Data(contentsOf: oldData.appending(path: "index.json"))) == list)
            do {
                try await gone.moveTo(music)
                check("choosing another folder then reads the list for it", gone.available && gone.folder == music
                      && gone.items.count == names(music).count && !gone.items.isEmpty, "\(gone.items.count) songs")
            } catch {
                check("choosing another folder then reads the list for it", false, error.localizedDescription)
            }

            // 9. this app's own downloads: folders of their own in a self-test
            check("a self-test's downloads are in folders of their own", downloads.folder?.lastPathComponent == "Downloads-selftest"
                  && downloads.dataFolder.lastPathComponent == "DownloadData-selftest")

            // 10. Settings › Footprint › Downloads: the folder in use (the Settings scene must have the store)
            try? await Task.sleep(for: .seconds(1))
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else {
                check("Settings opens", false); finish(); return
            }
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .seconds(1.5))
            guard let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) }),
                  let tab = settings.toolbar?.items.first(where: { $0.label == "Footprint" }), let action = tab.action else {
                check("Settings › Footprint opens", false); finish(); return
            }
            NSApp.sendAction(action, to: tab.target, from: tab)
            try? await Task.sleep(for: .seconds(1.2))
            let shown = downloads.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
            check("Settings › Footprint shows Downloads › Download location", frames["settings.downloadLocation"] != nil)
            check("… with the folder in use, ~ for the home folder", downloadLocationNote == shown && shown.hasPrefix("~/"), downloadLocationNote)
            if let pictures = ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"], let frame = settings.contentView?.superview {
                snapshot(frame, to: URL(filePath: pictures).appending(path: "downloads-settings.png"))
            }
            finish()
        }
    }
}
#endif
