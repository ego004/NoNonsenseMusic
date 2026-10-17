#if DEBUG
import AppKit

/// With `NN_SELFTEST_SHELL=1` (own test server; with `NN_SELFTEST_VISIBLE=1` and `NN_SELFTEST_SNAP=<folder>` it also
/// takes window pictures; the internet only for the "1 song" part, skipped without it): the window's frame as in the
/// Windows app (15 Oct). The sidebar has the logo, then exactly Home, Library and Friends as places (no Search); the
/// collections and a playlist say how many songs; Downloads only while there is a place for downloads; who is signed in
/// and the gear at the bottom. Library lists the collections, then the playlists, and a click on a card opens it. Jam
/// in the toolbar says Jam, shows LIVE only in a jam, and its panel opens from elsewhere (JamPanelState).
extension SelfTest {
    /// What some views show, by name, for checks that need the words and not only the place: "sidebar.detail:<row>"
    /// ("12 songs"), "sidebar.account" (the username).
    static var shownText: [String: String] = [:]
    /// Whether the toolbar's Jam shows LIVE now.
    static var jamLive = false
    private static var startedShell = false

    static func runShellCheckIfAsked(account: Account, library: LibraryStore, player: Player, downloads: DownloadStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SHELL"] != nil, !startedShell else { return }
        startedShell = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("shell \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            @MainActor func finish() {
                report("shell: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("shell: this app's own test server needed"); NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            await library.refresh()
            let name = "Shell test " + String(UInt32.random(in: 0 ... .max), radix: 16)
            check("make a playlist", await library.createPlaylist(named: name) == nil)
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            _ = await until(5) { frames["sidebar.title:\(name)"] != nil }
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let list = frames["sidebar.list"] else {
                check("the window and its sidebar", false); finish(); return
            }
            /// A click at the middle of a view, through the normal event queue (window points have y going up).
            @MainActor func click(_ frame: CGRect) {
                let p = NSPoint(x: frame.midX, y: window.contentView!.frame.height - frame.midY)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }

            // ── the sidebar: the logo, the places, then the collections and playlists with how many songs ──
            let places = frames.keys.filter { $0.hasPrefix("sidebar.place:") }.map { String($0.dropFirst("sidebar.place:".count)) }
                .sorted { frames["sidebar.place:\($0)"]!.minY < frames["sidebar.place:\($1)"]!.minY }
            check("the places are Home, Library, Friends, in that order", places == ["Home", "Library", "Friends"], "\(places)")
            check("…and Search is not one (it is the command bar's)", frames["sidebar.title:Search"] == nil)
            if let brand = frames["sidebar.brand"], let home = frames["sidebar.place:Home"] {
                check("the logo and the app's name are over Home", brand.maxY <= home.minY && brand.height >= 20, "\(brand)")
            } else { check("the logo and the app's name", false) }
            for item in [SidebarItem.liked, .recent] {
                let want = SongListView.count(item.songCount(library: library, downloads: downloads))
                check("\(item.title) says “\(want)”", shownText["sidebar.detail:\(item.title)"] == want, shownText["sidebar.detail:\(item.title)"] ?? "nothing")
            }
            if downloads.available {
                let want = SongListView.count(downloads.items.count)
                check("Downloads says “\(want)”", shownText["sidebar.detail:Downloads"] == want, shownText["sidebar.detail:Downloads"] ?? "nothing")
                report("shell SKIP no Downloads row without a place for downloads: that cannot be arranged in a test")
            } else {
                check("no place for downloads: no Downloads row", frames["sidebar.title:Downloads"] == nil)
            }
            if let friends = frames["sidebar.place:Friends"], let liked = frames["sidebar.row:Liked Songs"],
               let recent = frames["sidebar.row:Recently Played"], let mine = frames["sidebar.row:\(name)"] {
                check("under the places: Liked Songs, Recently Played, then your playlists",
                      friends.maxY < liked.minY && liked.maxY <= recent.minY + 1 && recent.maxY <= mine.minY + 1)
            } else {
                check("the collection and playlist rows", false, "\(frames.keys.filter { $0.hasPrefix("sidebar.row:") }.sorted())")
            }
            check("the new playlist says “0 songs”", shownText["sidebar.detail:\(name)"] == "0 songs", shownText["sidebar.detail:\(name)"] ?? "nothing")
            if let song = (try? await API.search("blinding lights the weeknd"))?.songs.first.map(Track.init),
               let playlist = library.ownPlaylists.first(where: { $0.name == name }) {
                await library.add(song, to: playlist)
                check("a song added: it says “1 song”", await until(5) { shownText["sidebar.detail:\(name)"] == "1 song" },
                      shownText["sidebar.detail:\(name)"] ?? "nothing")
                await library.toggleLike(song)
                check("a song liked: Liked Songs says “1 song”", await until(5) { shownText["sidebar.detail:Liked Songs"] == "1 song" },
                      shownText["sidebar.detail:Liked Songs"] ?? "nothing")
            } else {
                report("shell SKIP a song in the playlist: no search results (no internet?)")
            }
            if let row = frames["sidebar.account"], let gear = frames["sidebar.settings"] {
                let me = account.user?.username ?? ""
                check("at the bottom, who is signed in", !me.isEmpty && shownText["sidebar.account"] == me, shownText["sidebar.account"] ?? "nothing")
                check("…under the rows, at the sidebar's foot", row.minY > (frames["sidebar.row:\(name)"]?.maxY ?? 0) && row.maxY > list.maxY - 60,
                      "row \(row), list \(list)")
                check("…with the gear at its right end", gear.minX > row.midX && gear.maxX <= row.maxX + 1, "gear \(gear), row \(row)")
            } else {
                check("the account row and its gear", false)
            }
            windowShot("shell-home")

            // ── Jam beside the bell ──
            check("the toolbar's Jam shows the word, not only the people", (frames["jam.title"]?.width ?? 0) > 10,
                  frames["jam.title"].map { "\($0.width) pt" } ?? "not shown")
            check("…and no LIVE outside a jam", !JamSession.shared.inJam && !jamLive)
            @MainActor func popoverShowing() -> Bool { NSApp.windows.contains { $0.isVisible && "\(type(of: $0))".contains("Popover") } }
            JamPanelState.shared.shown = true                      // as the command bar's "Start or Join a Jam" does
            check("JamPanelState opens the Jam panel", await until(3) { popoverShowing() })
            JamPanelState.shared.shown = false
            check("…and closes it", await until(3) { !popoverShowing() })
            check("start a jam (this account alone, on the test server)", await JamSession.shared.start(named: nil) == nil, JamSession.shared.problem ?? "")
            check("…LIVE shows while in it", await until(3) { jamLive })
            windowShot("shell-jam-live")
            await JamSession.shared.leave()
            check("…and goes when you leave", await until(3) { !jamLive })

            // ── the gear opens Settings ──
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            let clicks = window.isKeyWindow
            if clicks, let gear = frames["sidebar.settings"] {
                @MainActor func settings() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) } }
                click(gear)
                check("the gear opens Settings", await until(3) { settings() != nil })
                settings()?.close()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.5))
            } else {
                report("shell SKIP the clicks: the window cannot become key while another app is in use")
            }

            // ── Library: the collections, then the playlists ──
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.library))
            check("Library opens", await until(3) { frames["library.title"] != nil })
            try? await Task.sleep(for: .seconds(1))
            let collections = SidebarItem.collections(downloads).map(\.title)
            let cards = collections.compactMap { frames["library.collection:\($0)"] }
            check("it lists the collections: \(collections.joined(separator: ", "))", cards.count == collections.count, "\(cards.count) of \(collections.count)")
            check("…side by side, in that order", zip(cards, cards.dropFirst()).allSatisfy { $0.maxX < $1.minX && abs($0.minY - $1.minY) < 1 })
            if !downloads.available {
                check("…without Downloads while there is no place for downloads", frames["library.collection:Downloads"] == nil)
            }
            if let first = cards.first, let card = frames["library.card:\(name)"] {
                check("then the playlists, the new one among them", card.minY > first.maxY, "card \(card), collections \(first)")
            } else {
                check("the new playlist's card", false)
            }
            if let title = frames["library.title"] {
                let margin = title.minX - list.maxX
                check("the page's margin is 32 (from the sidebar's edge, within 16)", margin >= 31 && margin <= 49, "\(margin)")
            }
            windowShot("shell-library")
            // a click on Liked Songs opens it: the sidebar then selects its row
            if clicks, let liked = frames["library.collection:Liked Songs"], let row = frames["sidebar.row:Liked Songs"] {
                click(liked)
                try? await Task.sleep(for: .seconds(1))
                let sidebar = descendants(of: window.contentView!).compactMap { $0 as? NSTableView }
                    .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                let selected = sidebar.flatMap { $0.selectedRow >= 0 ? $0.convert($0.rect(ofRow: $0.selectedRow), to: nil) : nil } ?? .zero
                check("a click on Liked Songs opens it (the sidebar selects its row)",
                      selected.contains(NSPoint(x: row.midX, y: window.contentView!.frame.height - row.midY)), "selected \(selected)")
            }

            if let mine = library.ownPlaylists.first(where: { $0.name == name }) { await library.deletePlaylist(mine) }
            finish()
        }
    }
}
#endif
