#if DEBUG
import AppKit

/// With `NN_SELFTEST_LIBRARYSEARCH=1` (test server only; no internet needed): a search lists your own songs first (#26).
/// The word rule against the server's own outputs; then a song the CI step stored on the test server ("Zanzibar
/// Lanterns" by Selftest Band, mac.yml), liked here and searched for with a typo: first on Search under In Your
/// Library, and first in the command bar under IN YOUR LIBRARY. Then the server is stopped, and both find it in the
/// library this app holds, Search saying why only your own songs show. With `NN_SELFTEST_SNAP=<folder>` and
/// `NN_SELFTEST_VISIBLE=1`: pictures of each.
extension SelfTest {
    private static var startedLibrarySearch = false
    /// What Search's songs show, top to bottom: headings and titles (SearchView sets it); and whether its server failed.
    static var searchLines: [String] = []
    static var searchFailed = false

    static func runLibrarySearchCheckIfAsked(library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LIBRARYSEARCH"] != nil, !startedLibrarySearch else { return }
        startedLibrarySearch = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("librarysearch \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func finish() {
                report("librarysearch: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 20) where !done() { try? await Task.sleep(for: .milliseconds(50)) }
                return done()
            }

            // ── the rule: what the server makes of these (backend services/matching.py, 18 Oct; the Windows app's test
            // holds the same) ──
            let server: [(String, String)] = [
                ("Bésame Mucho", "besame mucho"), ("ROSÉ & Bruno Mars - APT.", "rose bruno mars apt"), ("Don't Stop", "don t stop"),
                ("Beyoncé – Halo", "beyonce halo"), ("Straße", "straße"), ("Łódź", "łodz"), ("İstanbul", "istanbul"),
                ("हिंदी गाना", "ह द ग न"), ("हुआ", "ह आ"), ("Đà Lạt", "đa lat"),
                ("사랑해", "\u{1109}\u{1161}\u{1105}\u{1161}\u{11BC}\u{1112}\u{1162}"), ("Ǆemal", "dzemal"), ("ﬁne", "fine"),
                ("Café\u{301} Ole\u{301}", "cafe ole"), ("Ελλάδα", "ελλαδα"), ("Йод ёлка", "иод елка"), ("😀 smile", "smile"),
                ("Tum Hi Ho (From \"Aashiqui 2\")", "tum hi ho from aashiqui 2"), ("Ñandú", "nandu"), ("Ⅻ ①", "xii 1"),
                ("ＡＢＣ", "abc"), ("パプリカ", "ハフリカ"),
            ]
            for (text, expected) in server {
                let got = Matching.normalise(text)
                // compared scalar by scalar: Swift's == takes a composed letter and its parts as equal
                check("“\(text)” reads as the server reads it", Array(got.unicodeScalars) == Array(expected.unicodeScalars),
                      got.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
            }
            let alike: [(String, String, Bool)] = [
                ("tadipar", "tadipaar", true), ("kesriya", "kesariya", true), ("light", "lights", true), ("shap", "shape", true),
                ("black", "block", false), ("money", "honey", false), ("hi", "ho", false), ("sha", "shap", false),
                ("abcdefghijklmnopqrst", "abcdefghijklmnopqxyz", true), ("abcdefghijklmnopqr", "abcdefghijklmnoxyz", false),
                ("arjit", "arijit", true), ("singh", "sing", true),
            ]
            for (typed, word, expected) in alike {
                check("“\(typed)” \(expected ? "finds" : "does not find") “\(word)”, as on the server", Matching.found(typed, in: [word]) == expected)
            }
            let one = Listing(source: "jiosaavn", id: "rule-1", title: "Kesariya", artists: ["Pritam", "Arijit Singh"], album: nil,
                              duration: 268, popularity: nil, image: nil)
            let two = Listing(source: "jiosaavn", id: "rule-2", title: "Tum Hi Ho", artists: ["Arijit Singh"], album: nil,
                              duration: 262, popularity: nil, image: nil)
            let songs = [Track(best: one, listings: [one]), Track(best: two, listings: [two]), Track(best: one, listings: [one])]
            check("a song is found once, by every word typed (typos allowed), in the order given",
                  Matching.songs(matching: "kesriya", in: songs).map(\.title) == ["Kesariya"]
                  && Matching.songs(matching: "arijit singh", in: songs).map(\.title) == ["Kesariya", "Tum Hi Ho"]
                  && Matching.songs(matching: "kesariya remix", in: songs).isEmpty && Matching.songs(matching: "h", in: songs).isEmpty)

            // ── the server's search: the song CI stored, liked, and found by a typo of it ──
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else {
                report("librarysearch: refusing: not on its own test server"); NSApp.terminate(nil); return
            }
            let stored = Listing(source: "jiosaavn", id: "selftest-library-zanzibar", title: "Zanzibar Lanterns", artists: ["Selftest Band"],
                                 album: nil, duration: 201, popularity: nil, image: nil)
            do {
                _ = try await API.like([stored])
            } catch {
                check("the song mac.yml stores on the test server can be liked", false, error.localizedDescription); finish(); return
            }
            await library.refresh()
            check("it is in Liked Songs", library.liked.contains { $0.id == stored.key })

            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .selfTestSearch, object: "zanzbar lanterns")
            _ = await until(30) { searchLines.first == "In Your Library" }
            check("Search: In Your Library first, with the liked song (typed “zanzbar”)",
                  searchLines.prefix(2) == ["In Your Library", "Zanzibar Lanterns"], "\(searchLines)")
            check("…listed once", searchLines.filter { $0 == "Zanzibar Lanterns" }.count == 1, "\(searchLines)")
            check("…and anything the sources found after it, under Songs",
                  searchLines.count <= 2 || searchLines[2] == "Songs", "\(searchLines)")
            windowShot("librarysearch-search")

            let bar = CommandBarState.shared
            @MainActor func barRows(_ typed: String) async -> [String] {
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))   // Search has no bar
                try? await Task.sleep(for: .seconds(1))
                bar.summon()
                try? await Task.sleep(for: .milliseconds(400))
                if !bar.open { bar.focusChanged(true) }
                commandRows = []
                bar.query = typed
                _ = await until(30) { !bar.searching && commandRows.contains { $0 == "IN YOUR LIBRARY" || $0 == "SONGS" } }
                try? await Task.sleep(for: .milliseconds(300))
                return commandRows
            }
            var rows = await barRows("zanzbar lanterns")
            check("the command bar: IN YOUR LIBRARY, with the liked song under it",
                  rows.firstIndex(of: "IN YOUR LIBRARY").map { rows.indices.contains($0 + 1) && rows[$0 + 1] == "Zanzibar Lanterns" } ?? false, "\(rows)")
            windowShot("librarysearch-commandbar")
            bar.close()

            // ── no server: what this app holds ──
            ServerLauncher.shared.stop()
            for _ in 0..<40 { if !(await API.health()) { break }; try? await Task.sleep(for: .milliseconds(250)) }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .selfTestSearch, object: "zanzibar lantern")
            _ = await until(30) { searchFailed && !searchLines.isEmpty }
            check("with no server, Search finds it in the library this app holds, under In Your Library, and only it",
                  searchFailed && searchLines == ["In Your Library", "Zanzibar Lanterns"], "failed \(searchFailed), \(searchLines)")
            windowShot("librarysearch-search-noserver")
            rows = await barRows("zanzibar lantern")
            check("…and so does the command bar", rows.firstIndex(of: "IN YOUR LIBRARY").map {
                rows.indices.contains($0 + 1) && rows[$0 + 1] == "Zanzibar Lanterns" && !rows.contains("SONGS")
            } ?? false, "\(rows)")
            windowShot("librarysearch-commandbar-noserver")
            bar.close()
            finish()
        }
    }
}
#endif
