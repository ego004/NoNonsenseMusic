#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only, and only when started with `NN_SELFTEST=<folder>`:
/// draws the main window into `<folder>/window.png`, reports which view a click on each sidebar row would reach,
/// clicks the second row, then quits. Lets layout and click problems be checked without screen recording permission
/// (the app draws its own window; nothing else on screen is captured).
///
///     NN_SELFTEST=/tmp/nn mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense
enum SelfTest {
    private static var started = false
    /// Any NN_SELFTEST… variable set: the window shows a "Self-test" label, so it cannot pass for your app.
    static let isRunning = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("NN_SELFTEST") }

    static func runIfAsked() {
        guard !started, let folder = ProcessInfo.processInfo.environment["NN_SELFTEST"] else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(4))       // let the window lay out and the first requests finish
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let frame = window.contentView?.superview else { report("no window"); NSApp.terminate(nil); return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            report("window \(window.frame.size), key: \(window.isKeyWindow)")
            // the see-through background: the window must be non-opaque, with a blur view that samples what is BEHIND it
            let blurs = descendants(of: frame).compactMap { $0 as? NSVisualEffectView }
            let behind = blurs.filter { $0.blendingMode == .behindWindow }
            report("window opaque: \(window.isOpaque), background alpha \(window.backgroundColor.alphaComponent) | behind-window blur views: \(behind.count), blur amount \(behind.first.map { String(format: "%.2f", $0.alphaValue) } ?? "-")")
            let effectish = Set(descendants(of: frame).map { String(describing: type(of: $0)) }
                .filter { $0.range(of: "effect|glass|backdrop|material|vibran", options: [.regularExpression, .caseInsensitive]) != nil })
            report("effect-type views: \(effectish.sorted().joined(separator: ", "))")
            report("window background color alpha: \(window.backgroundColor.alphaComponent)")
            snapshot(frame, to: URL(filePath: folder).appending(path: "window.png"))

            // with NN_SELFTEST_SETTINGS: open Settings (⌘,) and draw it too
            if ProcessInfo.processInfo.environment["NN_SELFTEST_SETTINGS"] != nil {
                // the real "Settings…" item (⌘,) in the app menu, as a person would choose it
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    menu.performActionForItem(at: index)
                }
                try? await Task.sleep(for: .seconds(1.5))
                if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) }),
                   let settingsFrame = settings.contentView?.superview {
                    report("settings window: \(settings.title), \(settings.frame.size)")
                    snapshot(settingsFrame, to: URL(filePath: folder).appending(path: "settings.png"))
                    // then the Appearance tab, through its toolbar button
                    if let tab = settings.toolbar?.items.first(where: { $0.label == "Appearance" }), let action = tab.action {
                        NSApp.sendAction(action, to: tab.target, from: tab)
                        try? await Task.sleep(for: .seconds(0.8))
                        report("settings tab now: \(settings.title), \(settings.frame.size)")
                        snapshot(settingsFrame, to: URL(filePath: folder).appending(path: "settings-appearance.png"))
                        // do sections collapse? count the form's rows with Colours closed, then open (your setting is put back)
                        @MainActor func rows() -> [Int] { descendants(of: settingsFrame).compactMap { $0 as? NSTableView }.map { $0.numberOfRows } }
                        let keys = ["settings.open.colours", "settings.open.window", "settings.open.sizes"]
                        let savedAll = keys.map { UserDefaults.standard.object(forKey: $0) }
                        let saved = savedAll[0]
                        UserDefaults.standard.set(false, forKey: "settings.open.colours")
                        try? await Task.sleep(for: .seconds(0.6))
                        let closed = rows(), closedHeight = settings.frame.height
                        UserDefaults.standard.set(true, forKey: "settings.open.colours")
                        try? await Task.sleep(for: .seconds(0.6))
                        let open = rows(), openHeight = settings.frame.height
                        _ = saved
                        // twice: putting one back can make the page close another section (Colours opens on its own),
                        // which saves that; the second pass, after the page settles, leaves exactly what was there
                        for _ in 0..<2 {
                            for (key, value) in zip(keys, savedAll) {
                                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                            }
                            try? await Task.sleep(for: .seconds(0.4))
                        }
                        report("settings: Colours closed: window \(Int(closedHeight)) pt; Colours open: window \(Int(openHeight)) pt (screen: \(Int(settings.screen?.visibleFrame.height ?? 0)) pt usable)\(closed.isEmpty && open.isEmpty ? "" : "; rows \(closed) / \(open)")")
                    }
                } else {
                    report("settings window did not open")
                }
            }

            // the sidebar List is an NSTableView underneath; ask AppKit which view a click on each row would reach
            let tables = descendants(of: frame).compactMap { $0 as? NSTableView }
            for table in tables {
                report("table: \(table.numberOfRows) rows, frame in window \(table.convert(table.bounds, to: nil))")
                for row in 0..<table.numberOfRows {
                    let p = center(of: table.convert(table.rect(ofRow: row), to: nil))
                    let hit = frame.hitTest(p)     // the frame view has no superview, so window coordinates
                    report("row \(row) at \(p): click reaches \(describe(hit)); inside the table: \(hit?.isDescendant(of: table) ?? false)")
                }
            }

            // a real click on the second row, through the normal event queue
            if let table = tables.first, table.numberOfRows > 1 {
                let p = center(of: table.convert(table.rect(ofRow: 1), to: nil))
                let before = table.selectedRow
                // a background window takes its first click only to come forward, so click twice when not in front
                let clicks = window.isKeyWindow ? 1 : 2
                for type in Array(repeating: [NSEvent.EventType.leftMouseDown, .leftMouseUp], count: clicks).flatMap({ $0 }) {
                    if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
                report("clicked row 1: selected row \(before) -> \(table.selectedRow)  (window title: \(window.title))")
                // the same selection without a click (independent of focus): select row 2 the way a click ends,
                // and read the title SwiftUI sets from the screen it shows
                table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                try? await Task.sleep(for: .seconds(0.8))
                report("selected row 2 directly: selected row \(table.selectedRow), window title: \(window.title)")
                snapshot(frame, to: URL(filePath: folder).appending(path: "after-click.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static var startedPlayback = false
    /// Where the bar's ⏮ ▶ ⏭ are, in window points (PlayerBar sets it): the playback test checks they sit at the bar's centre.
    static var controlsFrame: CGRect = .zero
    /// What SearchView draws right now (it sets these): the search check samples them.
    static var noResultsShowing = false
    /// How many of each card appeared on screen (debug builds count them in .onAppear): the Home check reports it.
    static var appeared: [String: Int] = [:]
    static var searchResultCount = 0
    /// The search screen's top result as the copy that would play (SearchView sets it): the prefetch check times it.
    static var searchTop: Listing?
    /// Where the playlist screen's "No songs yet" sits (PlaylistView sets it): the playlist check measures its centring.
    static var emptyStateFrame: CGRect = .zero

    /// With `NN_SELFTEST_PLAY=1`: plays two songs built to fail, reports the player every second, then quits.
    /// 1. one copy that never plays  -> one serve_fresh retry, then "Couldn't play", then the next song
    /// 2. a bad best copy + a good one -> switch to the good one, and a background serve_fresh for the bad one
    /// Made-up JioSaavn ids answer 404 without touching YouTube. Point the app at a test server
    /// (`-serverURL http://127.0.0.1:8765` and `DATABASE_URL=postgresql:///music_test`) so your library stays clean.
    static func runPlaybackIfAsked(player: Player) {
        guard !startedPlayback, ProcessInfo.processInfo.environment["NN_SELFTEST_PLAY"] != nil else { return }
        startedPlayback = true
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }  // the app may be starting the server
            report("server: \(API.baseURL.absoluteString)")
            func listing(_ id: String) -> Listing {
                Listing(source: "jiosaavn", id: id, title: "Self-test \(id)", artists: ["Self-test"], album: nil,
                        duration: 200, popularity: nil, image: nil)
            }
            let onlyCopy = Track(best: listing("selftest-missing-1"), listings: [])
            let badBest = listing("selftest-missing-2")
            let twoCopies = Track(best: badBest, listings: [badBest, listing("fW-Mxsnu")])   // fW-Mxsnu: Blinding Lights
            if !player.isMuted { player.toggleMute() }               // tests stay silent
            // NN_SELFTEST_LISTINGS="ytmusic:ID,jiosaavn:ID": one song with exactly these copies, the first as default
            if let spec = ProcessInfo.processInfo.environment["NN_SELFTEST_LISTINGS"] {
                let copies = spec.split(separator: ",").map { part -> Listing in
                    let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
                    return Listing(source: bits[0], id: bits[1], title: "Self-test \(bits[1])", artists: ["Self-test"], album: nil,
                                   duration: 200, popularity: nil, image: nil)
                }
                player.play([Track(best: copies[0], listings: copies)])
            } else {
                player.play([onlyCopy, twoCopies])
            }
            for second in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                if second == 4, ProcessInfo.processInfo.environment["NN_SELFTEST_SWIPE"] != nil { swipeTest(player: player) }
                if second == 3 { snap("playing") }
                if second == 2 {
                    let bar = player.barFrame, controls = controlsFrame
                    report(String(format: "centre: bar %.1f (width %.0f), play button %.1f, off by %+.1f pt",
                                  bar.midX, bar.width, controls.midX, controls.midX - bar.midX))
                }
                report("t=\(second)s  song: \(player.current?.title ?? "-")  playing: \(player.isPlaying)  buffering: \(player.isBuffering)  message: \(player.errorMessage ?? "-")  problems (bar shakes): \(player.problems)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Posts a synthetic two-finger swipe (fingers moving left) over the player bar into the app's own event queue,
    /// then reports whether `next()` ran. Real trackpads send the same kind of scroll events.
    private static func swipeTest(player: Player) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let content = window.contentView else { report("swipe: no window"); return }
        let bar = player.barFrame
        report("swipe: player bar at \(bar.integral)")
        let inWindow = NSPoint(x: bar.midX, y: content.bounds.height - bar.midY)          // AppKit: bottom-left origin
        let onScreen = window.convertPoint(toScreen: inWindow)
        let screenTop = NSScreen.screens.first?.frame.height ?? 0
        let before = player.nextPresses
        for (phase, dx) in [(1, 0), (2, 30), (2, 30), (2, 30), (4, 0)] {                   // began, changed ×3, ended
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0)
            else { continue }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)            // a trackpad, not a mouse wheel
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            cg.location = CGPoint(x: onScreen.x, y: screenTop - onScreen.y)               // CG: top-left origin
            if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            report("swipe: next() ran \(player.nextPresses - before) time(s) (expected 1)")
        }
    }

    /// With `NN_SELFTEST_PRESENCE=1` (and `-discordEnabled NO`, so nothing is sent): what Discord would get,
    /// playing and paused in each mode. Your own "when paused" choice is put back afterwards.
    static func runPresenceCheckIfAsked(presence: Presence) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_PRESENCE"] != nil else { return }
        // the switches save themselves into YOUR settings: remember which were never set, and unset them again after
        let touched = ["discordWhenPaused", "discordSharePlaylist"]
        let before = touched.map { UserDefaults.standard.object(forKey: $0) }
        let original = presence.whenPaused
        let track = Track(best: Listing(source: "jiosaavn", id: "t", title: "Blinding Lights", artists: ["The Weeknd"],
                                        album: "After Hours", duration: 200, popularity: nil, image: "https://example.com/cover.jpg"), listings: [])
        let coverless = Track(best: Listing(source: "jiosaavn", id: "u", title: "No Cover Song", artists: ["Someone"],
                                            album: nil, duration: 200, popularity: nil, image: nil), listings: [])
        func describe(_ a: DiscordIPC.Activity?) -> String {
            guard let a else { return "nothing (status cleared)" }
            return "details: \(a.details ?? "-") | state: \(a.state ?? "-") | time bar: \(a.start != nil ? "yes" : "no") | picture: \(a.image.map { $0.hasPrefix("http") ? "cover URL" : $0 } ?? "-") | badge: \(a.smallImage ?? "-")"
        }
        report("playing           -> " + describe(presence.activity(for: track, isPlaying: true, position: 30)))
        report("playing, no cover -> " + describe(presence.activity(for: coverless, isPlaying: true, position: 30)))
        for mode in ["message", "keep", "clear"] {
            presence.whenPaused = mode
            report("paused, \(mode.padding(toLength: 8, withPad: " ", startingAt: 0))  -> " + describe(presence.activity(for: track, isPlaying: false, position: 30)))
        }
        presence.whenPaused = original
        let wasSharing = presence.sharePlaylist
        for on in [false, true] {
            presence.sharePlaylist = on
            report("from a playlist, playlist name \(on ? "on " : "off") -> " + describe(presence.activity(for: track, isPlaying: true, position: 30, playlist: "Gym")))
        }
        presence.sharePlaylist = wasSharing
        for (key, value) in zip(touched, before) where value == nil { UserDefaults.standard.removeObject(forKey: key) }
        // listing order: the default copy sits in the middle of what the server sent
        func listing(_ source: String, _ id: String, _ popularity: Int) -> Listing {
            Listing(source: source, id: id, title: "T", artists: ["A"], album: nil, duration: 200, popularity: popularity, image: nil)
        }
        let sent = [listing("ytmusic", "yt-big", 9_000_000), listing("jiosaavn", "js-low", 10), listing("jiosaavn", "js-default", 50),
                    listing("jiosaavn", "js-high", 99)]
        let ordered = Track(best: sent[2], listings: sent).listings.map(\.id)
        report("listings as sent: \(sent.map(\.id)) -> shown: \(ordered)")
        NSApp.terminate(nil)
    }

    /// With `NN_SELFTEST_THEME=1`: what each element's colour resolves to in each mode, with a green "song" colour.
    /// Your own colour settings are put back afterwards.
    static func runThemeCheckIfAsked(theme: ThemeStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_THEME"] != nil else { return }
        let saved = ThemeStore.Element.allCases.map { ($0, theme.mode($0), theme.hex($0)) }
        theme.songColor = Color(hex: "#34C759")
        for mode in ThemeStore.Mode.allCases {
            theme.setAll(mode)
            report("\(mode.label.padding(toLength: 6, withPad: " ", startingAt: 0)) -> " + ThemeStore.Element.allCases
                .map { "\($0.rawValue) \(theme.color($0)?.hexString ?? "system")" }.joined(separator: " | "))
        }
        for (element, mode, hex) in saved { theme.setMode(mode, for: element); theme.setHex(hex, for: element) }
        NSApp.terminate(nil)
    }

    /// With `NN_SELFTEST_LIKE="<search>"`: search like the app, take the first song, send the like exactly as
    /// API.like encodes it, and print the JSON sent and the server's whole answer. Point it at the test server.
    static func runLikeCheckIfAsked() {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_LIKE"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            do {
                let found = try await API.search(query)
                guard let song = found.songs.first else { report("like: no results"); NSApp.terminate(nil); return }
                let track = Track(song)
                struct Body: Encodable { let listings: [Listing] }
                let body = try JSONEncoder().encode(Body(listings: track.listings))
                report("like: sending \(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #"https?:[^"]*"#, with: "<url>", options: .regularExpression))")
                var request = URLRequest(url: API.baseURL.appending(path: "liked"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                let (data, response) = try await URLSession.shared.data(for: request)
                report("like: server answered \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data, as: UTF8.self).prefix(400))")
            } catch {
                report("like: failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_SEARCH="<query>"`: types the query into the search bar one letter every 120 ms (like a person),
    /// samples the window every 50 ms until 3 s after the last letter, and reports how often the "No Results" screen
    /// showed and whether results arrived. One real search goes out: the debounce cancels the partial ones.
    static func runSearchCheckIfAsked(player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_SEARCH"] else { return }
        // the rules of recent searches, on their own
        var raw = RecentSearches.adding("Arijit", to: "")
        raw = RecentSearches.adding("tum hi ho", to: raw)
        raw = RecentSearches.adding("ARIJIT", to: raw)
        report("search \(RecentSearches.list(raw) == ["ARIJIT", "tum hi ho"] ? "PASS" : "FAIL") recent searches: newest first, other capitals count once (got \(RecentSearches.list(raw)))")
        for n in 0..<20 { raw = RecentSearches.adding("q\(n)", to: raw) }
        report("search \(RecentSearches.list(raw).count == 12 && RecentSearches.list(raw).first == "q19" ? "PASS" : "FAIL") recent searches: at most 12")
        report("search \(!RecentSearches.list(RecentSearches.removing("q19", from: raw)).contains("q19") ? "PASS" : "FAIL") recent searches: remove one")
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))   // the app opens on Home
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let root = window.contentView?.superview,
                  let field = descendants(of: root).compactMap({ $0 as? NSTextField })
                      .first(where: { $0.placeholderString == "Songs, artists, albums" })
            else { report("search: no search field"); NSApp.terminate(nil); return }

            var samples = 0, noResults = 0, firstSeen: String?
            @MainActor func sample(_ moment: String) {
                samples += 1
                if noResultsShowing {
                    noResults += 1
                    if firstSeen == nil { firstSeen = moment }
                }
            }
            for n in 1...query.count {                         // type it: SwiftUI updates its binding from the delegate call
                field.stringValue = String(query.prefix(n))
                (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                for _ in 0..<2 { try? await Task.sleep(for: .milliseconds(60)); sample("after typing \"\(query.prefix(n))\"") }
            }
            for i in 0..<60 { try? await Task.sleep(for: .milliseconds(50)); sample(String(format: "%.2f s after the last letter", Double(i + 1) * 0.05)) }
            let rows = searchResultCount
            report("search: \"No Results\" showed in \(noResults) of \(samples) samples\(firstSeen.map { ", first \($0)" } ?? ""); result rows at the end: \(rows)")
            // play the first result (muted): the search should now be a recent search. Yours are put back after.
            let savedRecent = UserDefaults.standard.object(forKey: "recentSearches")
            UserDefaults.standard.removeObject(forKey: "recentSearches")
            if await onOwnTestServer() {
                if !player.isMuted { player.toggleMute() }
                NotificationCenter.default.post(name: .selfTestPlayFirstResult, object: nil)   // as a double-click on the first row
                try? await Task.sleep(for: .seconds(1))
                let recent = RecentSearches.list(UserDefaults.standard.string(forKey: "recentSearches") ?? "")
                report("search \(recent == [query] ? "PASS" : "FAIL") playing a result makes the search recent (got \(recent))")
            }
            if let savedRecent { UserDefaults.standard.set(savedRecent, forKey: "recentSearches") } else { UserDefaults.standard.removeObject(forKey: "recentSearches") }
            NSApp.terminate(nil)
        }
    }


    /// With `NN_SELFTEST_QUEUE=1`: checks every PlayQueue rule (shuffle, repeat, play next, a playlist's edits
    /// reaching its queue) on made-up songs, prints PASS/FAIL per rule, then quits. Plays no audio.
    static func runQueueCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_QUEUE"] != nil else { return }
        func song(_ name: String, by artist: String = "") -> Track {
            Track(best: Listing(source: "jiosaavn", id: "selftest-\(name)", title: name, artists: [artist.isEmpty ? "Artist \(name)" : artist],
                                album: nil, duration: 200, popularity: nil, image: nil), listings: [])
        }
        let abcde = ["a", "b", "c", "d", "e"].map { song($0) }
        let keys = ["k-a", "k-b", "k-c", "k-d", "k-e"]
        func names(_ q: PlayQueue) -> String { q.tracks.map(\.title).joined() }
        var failures = 0
        func check(_ rule: String, _ ok: Bool, _ got: String = "") {
            if !ok { failures += 1 }
            report("queue \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
        }

        var q = PlayQueue()
        q.load(abcde, startAt: 0, shuffled: false)
        q.move(to: 4)
        check("repeat off: the end stops", q.indexAfterEnd() == nil && q.indexAfterNext() == nil)
        q.repeatMode = .all
        check("repeat all: the end starts over", q.indexAfterEnd() == 0 && q.indexAfterNext() == 0)
        q.repeatMode = .one
        check("repeat one: a song that ends plays again", q.indexAfterEnd() == 4)
        check("repeat one: ⏭ still moves on", q.indexAfterNext() == 0)
        q.move(to: 0); q.repeatMode = .off
        check("⏮ on the first song, repeat off: nowhere to go", q.indexAfterPrevious() == nil)
        q.repeatMode = .all
        check("⏮ on the first song, repeat all: the last song", q.indexAfterPrevious() == 4)
        check("repeat steps off → all → one → off", PlayQueue.Repeat.off.next == .all && PlayQueue.Repeat.all.next == .one && PlayQueue.Repeat.one.next == .off)

        q = PlayQueue(); q.load(abcde, startAt: 2, shuffled: false)
        q.setShuffle(true)
        check("shuffle on: played songs and the current one stay", names(q).hasPrefix("abc") && q.index == 2, names(q))
        check("shuffle on: the rest are the same songs", Set(names(q).dropFirst(3)) == Set("de"), names(q))
        q.setShuffle(false)
        check("shuffle off: your order again, on the same song", names(q) == "abcde" && q.current?.title == "c", names(q))

        var shuffledLoad = PlayQueue(); shuffledLoad.load(abcde, startAt: 3, shuffled: true)
        check("a new queue with shuffle on: your song first, every other song after", shuffledLoad.current?.title == "d" && shuffledLoad.index == 0 && Set(names(shuffledLoad)) == Set("abcde"), names(shuffledLoad))
        var spread = PlayQueue()
        let twoArtists = (0..<10).map { song("x\($0)", by: $0 < 5 ? "One" : "Two") }
        var clumped = 0
        for _ in 0..<200 {
            spread.load(twoArtists, startAt: 0, shuffled: true)
            let artists = spread.tracks.map { $0.artists[0] }
            clumped += zip(artists, artists.dropFirst()).filter { $0 == $1 }.count
        }
        check("shuffle spreads each artist out (same artist back to back: \(String(format: "%.1f", Double(clumped) / 200)) of 9 per queue; random would be ~4)", Double(clumped) / 200 < 3)

        q = PlayQueue(); q.load(abcde, startAt: 1, shuffled: false)
        q.insertNext(song("X"))
        check("play next: right after the current song", names(q) == "abXcde", names(q))
        q.setShuffle(true); q.setShuffle(false)
        check("play next: still after it once shuffle is off again", names(q) == "abXcde", names(q))

        q = PlayQueue(); q.load(abcde, startAt: 0, keys: keys, source: "playlist:1", shuffled: false)
        let item = { (k: String) in (key: k, track: abcde[keys.firstIndex(of: k)!]) }
        q.sync(source: "playlist:1", items: ["k-a", "k-d", "k-b", "k-c", "k-e"].map(item))
        check("your case: abcde → adbce while a plays, d is next", names(q) == "adbce" && q.current?.title == "a" && q.upNext.first?.title == "d", names(q))
        q.sync(source: "playlist:1", items: ["k-d", "k-b", "k-a", "k-c", "k-e"].map(item))
        check("moving the playing song: it plays on, and the next one follows its new place", names(q) == "dbace" && q.current?.title == "a" && q.upNext.first?.title == "c", names(q))
        q.sync(source: "playlist:1", items: ["k-d", "k-b", "k-a", "k-e"].map(item))
        check("removing a song that has not played: it leaves the queue", names(q) == "dbae", names(q))
        q.sync(source: "playlist:1", items: ["k-d", "k-b", "k-e"].map(item))
        check("removing the playing song: it plays on", names(q) == "dbae" && q.current?.title == "a", names(q))
        q.sync(source: "playlist:1", items: ["k-d", "k-b", "k-e"].map(item) + [(key: "k-f", track: song("f"))])
        check("adding a song: it joins the queue", names(q).contains("f") && q.current?.title == "a", names(q))
        let before = names(q)
        q.sync(source: "playlist:2", items: [item("k-e")])
        check("another playlist's edit: this queue does not change", names(q) == before, names(q))

        let twice = song("t")
        q = PlayQueue(); q.load([abcde[0], twice, abcde[1], twice], startAt: 0, keys: ["i1", "i2", "i3", "i4"], source: "playlist:3", shuffled: false)
        q.sync(source: "playlist:3", items: [(key: "i1", track: abcde[0]), (key: "i3", track: abcde[1]), (key: "i4", track: twice)])
        check("a song in twice: removing one copy keeps the other", names(q) == "abt", names(q))

        // Play Next songs are not the playlist's: a sync (each time it is opened, too) keeps them, still next
        q = PlayQueue(); q.load(abcde, startAt: 0, keys: keys, source: "playlist:4", shuffled: false)
        q.insertNext(song("X"))
        q.sync(source: "playlist:4", items: keys.map(item))                  // opened again, unchanged
        check("play next: survives the playlist being opened again", names(q) == "aXbcde" && q.upNext.first?.title == "X", names(q))
        q.sync(source: "playlist:4", items: ["k-a", "k-c", "k-b", "k-d", "k-e"].map(item))
        check("play next: still next after the playlist is reordered", names(q) == "aXcbde", names(q))
        q.setShuffle(true); q.setShuffle(false)
        check("play next: still next once shuffle is off again", names(q) == "aXcbde", names(q))

        // Add to Queue: the end of Up Next, kept by a playlist sync, still last once shuffle is off again
        q = PlayQueue(); q.load(abcde, startAt: 1, keys: keys, source: "playlist:5", shuffled: false)
        q.append(song("Y"))
        check("add to queue: after everything queued", names(q) == "abcdeY", names(q))
        q.sync(source: "playlist:5", items: keys.map(item))
        check("add to queue: survives the playlist being opened again", names(q) == "abcdeY", names(q))
        q.setShuffle(true); q.setShuffle(false)
        check("add to queue: still last once shuffle is off again", names(q) == "abcdeY", names(q))

        // Up Next by hand
        q = PlayQueue(); q.load(abcde, startAt: 0, keys: keys, source: "playlist:9", shuffled: false)
        q.moveUpcoming(fromOffsets: IndexSet([3]), toOffset: 0)          // e (4th after a) to the front of Up Next
        check("drag in Up Next: e moves to next, a still playing", names(q) == "aebcd" && q.current?.title == "a" && q.upNext.first?.title == "e", names(q))
        q.moveUpcoming(fromOffsets: IndexSet([0]), toOffset: 4)          // e back to the end
        check("drag in Up Next: back to the end", names(q) == "abcde", names(q))
        q.moveUpcoming(fromOffsets: IndexSet([2]), toOffset: 0)          // d to next
        q.sync(source: "playlist:9", items: ["k-a", "k-b", "k-c", "k-d", "k-e"].map(item))
        check("after a drag the queue is yours: a playlist sync no longer reorders it", names(q) == "adbce", names(q))
        check("after a drag the queue still says where it came from (“From Gym”)", q.origin == "playlist:9", q.origin ?? "nil")
        q.setShuffle(true); q.setShuffle(false)
        check("after a drag, shuffle on and off comes back to the dragged order", names(q) == "adbce" && q.current?.title == "a", names(q))
        q.removeUpcoming(at: 1)                                         // b
        check("remove from Up Next", names(q) == "adce", names(q))
        q.clearUpcoming()
        check("clear Up Next: the current song stays", names(q) == "a" && q.current?.title == "a", names(q))

        report("queue: \(failures == 0 ? "all rules pass" : "\(failures) FAILED")")
        NSApp.terminate(nil)
    }

    /// With `NN_SELFTEST_PLAYLISTS="<search>"` (and a test server: `-serverURL http://127.0.0.1:8765`,
    /// `DATABASE_URL=postgresql:///music_test`): the whole playlist flow through LibraryStore and the Player, checking
    /// the app, the server and the playing queue agree at each step. Muted; one real search; snapshots with NN_SELFTEST_SNAP.
    static func runPlaylistCheckIfAsked(library: LibraryStore, player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_PLAYLISTS"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("playlists: refusing: the server answering was not started by this test (it may hold your library)"); NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            // Play and Shuffle remember shuffle in YOUR settings (a test window shares them): put it back before quitting
            let savedShuffle = UserDefaults.standard.object(forKey: "shuffle")
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("playlists \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func titles(_ tracks: [Track]) -> [String] { tracks.map(\.title) }

            let name = "Self-test \(Int.random(in: 1000...9999))"
            check("create", await library.createPlaylist(named: name) == nil)
            guard let summary = library.playlists.first(where: { $0.name == name }) else { report("playlists: not in the list"); NSApp.terminate(nil); return }
            let again = await library.createPlaylist(named: name)
            check("the same name again: the server's reason comes back", again == "A playlist with this name already exists", again ?? "nil")

            // the empty playlist first: is "No songs yet" centred in the screen beside the sidebar?
            NotificationCenter.default.post(name: .selfTestOpen, object: summary.id)
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                let empty = emptyStateFrame
                let sidebarWidth = descendants(of: window.contentView!).compactMap { $0 as? NSTableView }.map(\.frame.width).min() ?? 0
                let detailMid = sidebarWidth + (window.frame.width - sidebarWidth) / 2
                report("playlists: \"No songs yet\" centre x \(Int(empty.midX)), screen beside the sidebar centre x \(Int(detailMid)) (sidebar \(Int(sidebarWidth)) pt)")
                check("\"No songs yet\" is centred (within 30 pt)", abs(empty.midX - detailMid) < 30, "\(Int(empty.midX - detailMid)) pt off")
            }
            guard let found = try? await API.search(query) else { report("playlists: search failed"); NSApp.terminate(nil); return }
            let songs = found.songs.prefix(4).map(Track.init)
            for song in songs { await library.add(song, to: summary) }
            check("adding shows ✓ Added to …", library.message == "Added to “\(name)”" && library.messageSymbol == "checkmark.circle.fill", library.message ?? "nil")
            await library.loadPlaylist(summary.id)
            guard let detail = library.details[summary.id] else { report("playlists: did not load"); NSApp.terminate(nil); return }
            check("4 songs, in the order added", titles(detail.tracks) == titles(songs), titles(detail.tracks).joined(separator: " | "))
            check("the list shows the count", library.playlists.first { $0.id == summary.id }?.songCount == 4)

            NotificationCenter.default.post(name: .selfTestOpen, object: summary.id)
            player.playInOrder(detail.tracks, keys: detail.keys, source: detail.queueSource)
            check("Play: the queue is the playlist", titles(player.queue) == titles(detail.tracks))
            try? await Task.sleep(for: .seconds(3))
            snap("playlist")
            // pictures cannot show lists (their table views draw outside both snapshot methods), so count their rows
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let root = window.contentView?.superview {
                let tables = descendants(of: root).compactMap { $0 as? NSTableView }.map(\.numberOfRows).sorted()
                report("playlists: table views in the window, rows each: \(tables)")
                check("the playlist screen has its header and 4 song rows", tables.contains(5), "\(tables)")
            }

            await library.moveItems(in: summary.id, from: IndexSet([3]), to: 1)          // the 4th song up to 2nd
            let moved = library.details[summary.id].map { titles($0.tracks) } ?? []
            let expected = [songs[0], songs[3], songs[1], songs[2]].map(\.title)
            check("drag the 4th song up: the screen", moved == expected, moved.joined(separator: " | "))
            check("… the playing queue follows, and the next song is the moved one", titles(player.queue) == expected && player.upNext.first?.title == songs[3].title)
            await library.loadPlaylist(summary.id)
            check("… the server agrees", library.details[summary.id].map { titles($0.tracks) } == expected)

            if let entry = library.details[summary.id]?.items.last {
                await library.remove(entry, from: summary.id)
            }
            check("remove the last song: 3 left, and out of the queue", library.details[summary.id]?.items.count == 3 && player.queue.count == 3)

            let renamed = name + " renamed"
            check("rename", await library.renamePlaylist(summary, to: renamed) == nil && library.playlists.contains { $0.name == renamed })
            snap("playlist-after")

            if let current = library.playlists.first(where: { $0.id == summary.id }) { await library.deletePlaylist(current) }
            check("delete: gone from the list", !library.playlists.contains { $0.id == summary.id })
            check("… and the server says 404", !(await library.loadPlaylist(summary.id)))

            if let savedShuffle { UserDefaults.standard.set(savedShuffle, forKey: "shuffle") } else { UserDefaults.standard.removeObject(forKey: "shuffle") }
            report("playlists: \(failures == 0 ? "all steps pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_HOME="<search>"` (test server only): fills the test library (a playlist of 4 songs, 3 liked
    /// songs), waits on Home, reports what Home holds and snapshots it, then cleans up (unlikes, deletes the playlist).
    static func runHomeCheckIfAsked(library: LibraryStore, player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_HOME"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("home: refusing: the server answering was not started by this test (it may hold your library)"); NSApp.terminate(nil); return }
            guard let found = try? await API.search(query) else { report("home: search failed"); NSApp.terminate(nil); return }
            let songs = found.songs.prefix(6).map(Track.init)
            let name = "Self-test Mix \(Int.random(in: 100...999))"
            _ = await library.createPlaylist(named: name)
            if let playlist = library.playlists.first(where: { $0.name == name }) {
                for song in songs.prefix(4) { await library.add(song, to: playlist) }
            }
            var likedHere: [Track] = []
            for song in songs.suffix(3) where !library.isLiked(song) { await library.toggleLike(song); likedHere.append(song) }
            await library.refresh()
            report("home: recent \(library.recent.count), liked \(library.liked.count), playlists \(library.playlists.count)")
            try? await Task.sleep(for: .seconds(4))              // covers download, sections fade in
            snap("home")
            report("home: on screen: \(appeared.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))")
            // window pictures cannot draw scroll views: draw the cards themselves, off screen, to see their design
            let sample = VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(library.recent.prefix(3)), id: \.id) { CoverTile(track: $0) {} }
                    ForEach(library.playlists.prefix(2)) { PlaylistCard(playlist: $0, side: Look.cardSize) {} }
                    PlaylistCover(images: PlaylistCover.images(of: library.liked + library.recent), size: Look.cardSize, seed: "grid")
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(library.liked.prefix(3)), id: \.id) { CompactSongTile(track: $0, width: 300) {} }
                }
            }
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(library).environment(player)
            let renderer = ImageRenderer(content: sample)
            renderer.scale = 2
            if let folder = ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"], let image = renderer.nsImage,
               let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let url = URL(filePath: folder).appending(path: "home-cards.png")
                do { try png.write(to: url); report("wrote \(url.path)") } catch { report("could not write \(url.path)") }
            }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                report("home: window title \(window.title.isEmpty ? "-" : window.title)")
            }
            for song in likedHere { await library.toggleLike(song) }
            if let playlist = library.playlists.first(where: { $0.name == name }) { await library.deletePlaylist(playlist) }
            report("home: cleaned up")
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_NOWPLAYING="<search>"` (test server only, muted): plays 4 songs, then draws Now Playing off screen
    /// in each layout (alone, Lyrics, Up Next) into `nowplaying-<layout>.png`. Your remembered layout is put back after.
    static func runNowPlayingCheckIfAsked(library: LibraryStore, player: Player, theme: ThemeStore) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_NOWPLAYING"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("nowplaying: refusing: the server answering was not started by this test (it may hold your library)"); NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            guard let found = try? await API.search(query) else { report("nowplaying: search failed"); NSApp.terminate(nil); return }
            player.play(found.songs.prefix(4).map(Track.init))
            try? await Task.sleep(for: .seconds(3))                 // the cover downloads
            // your remembered layout is put back before quitting (a defer would never run: terminate ends the app first)
            let saved = UserDefaults.standard.string(forKey: "nowPlayingPanel")
            for panel in [NowPlayingPanel.none, .lyrics, .upNext] {
                UserDefaults.standard.set(panel.rawValue, forKey: "nowPlayingPanel")
                let view = NowPlayingView().frame(width: 1200, height: 760)
                    .environment(player).environment(library).environment(theme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                if let folder = ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"], let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    let url = URL(filePath: folder).appending(path: "nowplaying-\(panel.rawValue).png")
                    do { try png.write(to: url); report("wrote \(url.path)") } catch { report("could not write \(url.path)") }
                }
            }
            if let saved { UserDefaults.standard.set(saved, forKey: "nowPlayingPanel") } else { UserDefaults.standard.removeObject(forKey: "nowPlayingPanel") }
            report("nowplaying: song \(player.current?.title ?? "-"), up next \(player.upNext.count)")
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_SIZES=1`: measures text drawn with `textStyle` at text sizes 0.85, 1 and 1.3, and checks
    /// scale 1 matches the Mac's own `.font(.body)` exactly. Needs no server.
    static func runSizesCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SIZES"] != nil else { return }
        func width(_ view: some View) -> CGFloat { ImageRenderer(content: view.fixedSize()).nsImage?.size.width ?? -1 }
        let mac = width(Text("Songs, artists, albums").font(.body))
        let scaled = [0.85, 1.0, 1.3].map { s in width(Text("Songs, artists, albums").textStyle(.body).environment(\.textScale, s)) }
        report("sizes: .font(.body) \(Int(mac)) pt; textStyle(.body) at 0.85 / 1 / 1.3: \(scaled.map { String(Int($0)) }.joined(separator: " / ")) pt")
        report("sizes \(abs(scaled[1] - mac) < 1 ? "PASS" : "FAIL") scale 1 looks exactly as before")
        report("sizes \(scaled[0] < scaled[1] && scaled[1] < scaled[2] ? "PASS" : "FAIL") smaller and larger really change the size")
        NSApp.terminate(nil)
    }

    /// With `NN_SELFTEST_IDLE=<seconds>`: sits on Home that long, then (with NN_SELFTEST_IDLE_PLAY="<search>") plays a
    /// song, muted, for as long again; then quits. Measure the app's CPU from outside while it runs.
    static func runIdleIfAsked(player: Player) {
        guard let seconds = ProcessInfo.processInfo.environment["NN_SELFTEST_IDLE"].flatMap(Double.init) else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            report("idle: on Home now")
            try? await Task.sleep(for: .seconds(seconds))
            if let query = ProcessInfo.processInfo.environment["NN_SELFTEST_IDLE_PLAY"], await onOwnTestServer(),
               let found = try? await API.search(query) {
                if !player.isMuted { player.toggleMute() }
                player.play(found.songs.prefix(3).map(Track.init))
                report("idle: playing now")
                try? await Task.sleep(for: .seconds(seconds))
            }
            report("idle: done")
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_PREFETCH="<search>|<search>"` (test server only, muted): A. plays a queue from the first
    /// search, waits, and times /play for the next songs; B. types the second search on the Search screen, waits, and
    /// times /play for its top result. Prefetched songs answer from the cache: single-digit milliseconds.
    static func runPrefetchCheckIfAsked(player: Player) {
        guard let spec = ProcessInfo.processInfo.environment["NN_SELFTEST_PREFETCH"] else { return }
        let parts = spec.split(separator: "|").map(String.init)
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), parts.count == 2 else { report("prefetch: test server and two searches needed"); NSApp.terminate(nil); return }
            let noRedirect = URLSession(configuration: .ephemeral, delegate: StopRedirects(), delegateQueue: nil)
            func time(_ listing: Listing) async -> String {
                let start = Date()
                let status = ((try? await noRedirect.data(from: API.playURL(listing)))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                return String(format: "%@ %d in %.1f ms", listing.source, status, Date().timeIntervalSince(start) * 1000)
            }
            if !player.isMuted { player.toggleMute() }

            // A. a queue
            guard let found = try? await API.search(parts[0]) else { report("prefetch: search failed"); NSApp.terminate(nil); return }
            player.play(found.songs.prefix(6).map(Track.init))
            try? await Task.sleep(for: .seconds(4))               // 0.3 s settle + lookups in the background
            for (n, track) in player.upNext.prefix(3).enumerated() {
                report("prefetch A: queue song \(n + 2) (\(track.title)): \(await time(track.best))")
            }

            // B. the search screen
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let field = descendants(of: window.contentView!.superview!).compactMap({ $0 as? NSTextField })
                      .first(where: { $0.placeholderString == "Songs, artists, albums" }) else { report("prefetch: no search field"); NSApp.terminate(nil); return }
            field.stringValue = parts[1]
            (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            for _ in 0..<40 where searchTop == nil { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(4))
            if let top = searchTop { report("prefetch B: search top result: \(await time(top))") }
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_UPNEXT="<search>"` (test server only, muted): plays 5 songs, opens Now Playing on Up Next,
    /// counts its rows, then moves and removes songs the way a drag and the ✕ do. Your Now Playing layout is put back.
    static func runUpNextCheckIfAsked(player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_UPNEXT"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), let found = try? await API.search(query) else { report("upnext: test server and a search needed"); NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            let saved = UserDefaults.standard.string(forKey: "nowPlayingPanel")
            UserDefaults.standard.set("upNext", forKey: "nowPlayingPanel")
            player.play(found.songs.prefix(5).map(Track.init))
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                let rows = descendants(of: window.contentView!.superview!).compactMap { $0 as? NSTableView }.map(\.numberOfRows)
                report("upnext: list rows on screen \(rows) (Up Next holds \(player.upNext.count))")
            }
            let before = player.upNext.map(\.title)
            player.moveUpNext(fromOffsets: IndexSet([3]), toOffset: 0)
            report("upnext \(player.upNext.map(\.title) == [before[3], before[0], before[1], before[2]] ? "PASS" : "FAIL") drag the last song to next")
            player.removeFromUpNext(at: 0)
            report("upnext \(player.upNext.map(\.title) == Array(before.prefix(3)) ? "PASS" : "FAIL") remove it again")
            if let saved { UserDefaults.standard.set(saved, forKey: "nowPlayingPanel") } else { UserDefaults.standard.removeObject(forKey: "nowPlayingPanel") }
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_DOWNLOADS="<search>"` (test server only, muted, the Downloads-selftest folder): downloads two
    /// songs, checks the files and the index, then STOPS THE SERVER and plays a download: it must play from its file.
    static func runDownloadsCheckIfAsked(player: Player, downloads: DownloadStore) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_DOWNLOADS"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), downloads.folder.lastPathComponent == "Downloads-selftest",
                  let found = try? await API.search(query) else { report("downloads: test server, test folder and a search needed"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("downloads \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            downloads.removeAll()
            if !player.isMuted { player.toggleMute() }
            let songs = found.songs.prefix(2).map(Track.init)
            let start = Date()
            for song in songs { await downloads.download(song, quietly: true) }
            let sizes = downloads.items.map { formatBytes($0.bytes) }
            report(String(format: "downloads: 2 songs in %.1f s: %@ (%@)", Date().timeIntervalSince(start), songs.map(\.title).joined(separator: ", "), sizes.joined(separator: ", ")))
            check("both downloaded, files on disk, each over 500 KB", downloads.items.count == 2 && downloads.items.allSatisfy {
                $0.bytes > 500_000 && FileManager.default.fileExists(atPath: downloads.folder.appending(path: $0.file).path) })
            check("the index is saved: a fresh store finds both", DownloadStore().items.count == 2)
            check("songs know they are downloaded", songs.allSatisfy(downloads.isDownloaded))

            ServerLauncher.shared.stop()                                  // now no server at all
            try? await Task.sleep(for: .seconds(1))
            check("the server is really off", !(await API.health()))
            player.play([songs[1]])
            try? await Task.sleep(for: .seconds(3))
            let position = player.livePosition
            report(String(format: "downloads: with the server off: playing %@, from its file: %@, buffering: %@, position %.1f s", songs[1].title,
                          player.playingFile ? "yes" : "no", player.isBuffering ? "yes" : "no", position))
            check("with the server off, a download plays from its file", player.playingFile && player.isPlaying && !player.isBuffering && position > 0.5)

            downloads.remove(songs[0])
            check("remove one: its file is gone", downloads.items.count == 1 && !songs[0].listings.contains { downloads.localURL(for: $0) != nil })
            downloads.removeAll()
            let left = (try? FileManager.default.contentsOfDirectory(atPath: downloads.folder.path))?.filter { $0 != "index.json" } ?? []
            check("remove all: the folder is empty", downloads.items.isEmpty && left.isEmpty, "\(left)")
            report("downloads: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// Where views are, in window points, by name (`selfTestFrame`): "sidebar.title:Home", "bar.progress", …
    static var frames: [String: CGRect] = [:]

    /// With `NN_SELFTEST_SIDEBAR=1`: the "New Playlist" row (it used to be a + in the section header, out at the
    /// sidebar's edge). Pictures cannot draw lists, and SwiftUI shows an in-app accessibility walk nothing, so each row
    /// reports where its icon and title are: New Playlist must line up with the others. Then a real click on it must
    /// ask for the New Playlist sheet.
    static func runSidebarCheckIfAsked(library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SIDEBAR"] != nil else { return }
        Task {
            for _ in 0..<40 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            await library.refresh()
            try? await Task.sleep(for: .seconds(1.5))
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("sidebar \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let names = SidebarItem.allCases.map(\.title) + library.playlists.map(\.name)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let newTitle = frames["sidebar.title:New Playlist"], let newIcon = frames["sidebar.icon:New Playlist"],
                  names.allSatisfy({ frames["sidebar.title:\($0)"] != nil }) else {
                report("sidebar: frames missing: \(frames.keys.sorted())"); NSApp.terminate(nil); return
            }
            for name in names + ["New Playlist"] {
                let t = frames["sidebar.title:\(name)"]!, i = frames["sidebar.icon:\(name)"]!
                report("sidebar: \(name == "New Playlist" ? "NEW " : "    ")icon centre x \(String(format: "%.1f", i.midX)), title starts x \(String(format: "%.1f", t.minX)), y \(Int(t.midY))")
            }
            let titleOffsets = names.map { frames["sidebar.title:\($0)"]!.minX - newTitle.minX }
            let iconOffsets = names.map { frames["sidebar.icon:\($0)"]!.midX - newIcon.midX }
            check("New Playlist's title starts where every other title starts (within 1 pt)", titleOffsets.allSatisfy { abs($0) <= 1 }, "\(titleOffsets)")
            check("its + is centred in the same icon column (within 1 pt)", iconOffsets.allSatisfy { abs($0) <= 1 }, "\(iconOffsets)")
            let lastPlaylistY = library.playlists.compactMap { frames["sidebar.title:\($0.name)"]?.midY }.max() ?? 0
            check("it is the last row of Playlists", newTitle.midY > lastPlaylistY)

            // a real click on its title, through the normal event queue (window points have y going up)
            library.newPlaylistRequest = nil
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            let height = window.contentView!.frame.height
            let p = NSPoint(x: newTitle.midX, y: height - newTitle.midY)
            for type in Array(repeating: [NSEvent.EventType.leftMouseDown, .leftMouseUp], count: window.isKeyWindow ? 1 : 2).flatMap({ $0 }) {
                if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            if window.isKeyWindow {
                check("clicking it asks for the New Playlist sheet", library.newPlaylistRequest != nil && library.newPlaylistRequest?.track == nil)
            } else {
                report("sidebar SKIP the click: the window cannot become key while another app is in use (a click only selects it)")
            }
            library.newPlaylistRequest = nil
            report("sidebar: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_SETTINGS_FIT=1`: opens Settings, visits every tab with every section open, and checks the
    /// window stays on screen (Discord with everything open ran past the bottom, 6 Oct). Section settings are put back.
    static func runSettingsFitCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SETTINGS_FIT"] != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("settings-fit \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let keys = ["settings.open.window", "settings.open.sizes", "settings.open.colours", "settings.open.share", "settings.open.preview"]
                + ["settings.open.surfaces"]
            borrowDefaults(keys)
            for key in keys where key != "settings.open.colours" { UserDefaults.standard.set(true, forKey: key) }
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
            else { report("settings-fit: no Settings item"); NSApp.terminate(nil); return }
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .seconds(1.5))
            guard let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) }),
                  let screen = settings.screen?.visibleFrame else { report("settings-fit: Settings did not open"); NSApp.terminate(nil); return }
            for item in settings.toolbar?.items ?? [] {
                guard let action = item.action else { continue }
                NSApp.sendAction(action, to: item.target, from: item)
                try? await Task.sleep(for: .seconds(1.2))
                let f = settings.frame
                report("settings-fit: \(item.label): window \(Int(f.height)) pt tall, bottom at y \(Int(f.minY)); usable screen y \(Int(screen.minY))…\(Int(screen.maxY)) (\(Int(screen.height)) pt)")
                check("\(item.label) fits on the screen", f.height <= screen.height && f.minY >= screen.minY - 1 && f.maxY <= screen.maxY + 1,
                      "\(Int(f.height)) pt, bottom \(Int(f.minY))")
            }
            returnDefaults()
            try? await Task.sleep(for: .seconds(0.4))
            report("settings-fit: \(failures == 0 ? "all tabs fit" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// True only for a server this test app started itself (with the test database from its environment), on a port
    /// that is not 8000. "Not 8000" alone was not enough: on 7 Oct your own app's server sat on 8765 (your saved address
    /// had become the test one), a test found it answering, used it, and wrote one play into your library.
    /// Waits for the launcher to finish starting (it marks its server started only on its own next check, up to half a
    /// second after /health first answers: checking sooner refused a good run, 7 Oct).
    static func onOwnTestServer() async -> Bool {
        await ServerLauncher.shared.ensureRunning()
        return API.baseURL.port != 8000 && ServerLauncher.shared.state == .started
    }

    /// Where a self-test saves the settings it is about to change (`borrowDefaults`).
    private static let restoreFile = FileManager.default.temporaryDirectory.appending(path: "nn-selftest-defaults.plist")

    /// Saves these settings to a file before a test changes them. `returnDefaults` puts them back; if the test dies
    /// first, the next self-test launch does (a crash on 6 Oct left four Settings sections changed).
    static func borrowDefaults(_ keys: [String]) {
        var saved: [String: Any] = [:], missing: [String] = []
        for key in keys { if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value } else { missing.append(key) } }
        (["saved": saved, "missing": missing] as NSDictionary).write(to: restoreFile, atomically: true)
    }

    /// Puts back what `borrowDefaults` saved, if anything is waiting. Runs at every self-test launch, before the window.
    static func returnDefaults() {
        guard let plist = NSDictionary(contentsOf: restoreFile) as? [String: Any] else { return }
        for (key, value) in plist["saved"] as? [String: Any] ?? [:] { UserDefaults.standard.set(value, forKey: key) }
        for key in plist["missing"] as? [String] ?? [] { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: restoreFile)
        report("returned \((plist["saved"] as? [String: Any])?.count ?? 0) saved settings and removed \((plist["missing"] as? [String])?.count ?? 0) new ones")
    }

    /// With `NN_SELFTEST_BAR="<search>"` (test server only, muted): the player bar's layout, measured (pictures
    /// cannot draw glass), at the window's size and at its narrowest; then each surface setting, checked by the
    /// blur view it must create. Your settings are borrowed and put back.
    static func runBarCheckIfAsked(player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_BAR"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), let found = try? await API.search(query), found.songs.count >= 2,
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let root = window.contentView?.superview
            else { report("bar: test server, a search and a window needed"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("bar \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let keys = ["sidebarBlur", "sidebarSolid", "barStyle", "barBlur", "barSolid", "nowPlayingBlur", "nowPlayingSolid", "nowPlayingColour"]
            borrowDefaults(keys)
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }     // start from the defaults
            if !player.isMuted { player.toggleMute() }
            player.play(found.songs.prefix(2).map(Track.init))
            try? await Task.sleep(for: .seconds(4))

            @MainActor func layout(_ label: String) {
                guard let bar = frames["bar"], let song = frames["bar.song"], let centre = frames["bar.centre"], let buttons = frames["bar.buttons"],
                      let progress = frames["bar.progress"]
                else { check("\(label): every part reports where it is", false, "\(frames.keys.filter { $0.hasPrefix("bar") }.sorted())"); return }
                let controls = controlsFrame
                report(String(format: "bar: %@: bar %.0f × %.0f pt; centre %.0f pt wide; progress line %.0f pt; buttons %.0f pt; controls centre off by %.1f pt",
                              label, bar.width, bar.height, centre.width, progress.width, buttons.width, controls.midX - bar.midX))
                check("\(label): ⏮ ▶ ⏭ at the bar's exact centre (within 1 pt)", abs(controls.midX - bar.midX) <= 1, String(format: "%.1f", controls.midX - bar.midX))
                check("\(label): the progress line is under the controls, not on the bar's edge",
                      progress.minY >= controls.maxY - 1 && bar.maxY - progress.maxY >= 6, String(format: "%.0f pt from the bottom", bar.maxY - progress.maxY))
                check("\(label): the timeline (both times and the line) fits in the centre column", progress.minX >= centre.minX - 0.5 && progress.maxX <= centre.maxX + 0.5)
                check("\(label): the song, the centre and the buttons do not overlap", song.maxX <= centre.minX + 0.5 && buttons.minX >= centre.maxX - 0.5,
                      String(format: "song ends %.0f, centre %.0f…%.0f, buttons start %.0f", song.maxX, centre.minX, centre.maxX, buttons.minX))
                check("\(label): the buttons stay inside the bar", buttons.maxX <= bar.maxX - 8, String(format: "%.0f > %.0f", buttons.maxX, bar.maxX - 8))
            }
            // the window opens at whatever size your own app was left at (they share settings): set the wide size first
            let saved = window.frame
            window.setFrame(NSRect(x: saved.minX, y: saved.minY, width: 1180, height: saved.height), display: true)
            try? await Task.sleep(for: .seconds(1))
            layout("at \(Int(window.frame.width)) pt")
            let wide = buttonsWidth()
            // the timeline moves by itself: a Core Animation animation on the played part, and the time text ticking
            if let timeline = descendants(of: window.contentView!.superview!).compactMap({ $0 as? TimelineLayersView }).first {
                let before = timeline.debugState
                try? await Task.sleep(for: .seconds(2.2))
                let after = timeline.debugState
                let seen = window.occlusionState.contains(.visible)
                report("bar: timeline: animating \(after.animating), elapsed \(before.elapsed) -> \(after.elapsed), window visible: \(seen), playing \(player.isPlaying), buffering \(player.isBuffering), live \(String(format: "%.1f", player.livePosition)) s")
                check("the played line is a running Core Animation animation (the app draws no frames for it)", after.animating)
                if seen {
                    check("the elapsed time advances by itself", before.elapsed != after.elapsed)
                } else {
                    report("bar SKIP the elapsed time: the window is covered, and the times update only while it can be seen (by design)")
                }
            } else {
                check("the bar's timeline is there", false)
            }
            window.setFrame(NSRect(x: saved.minX, y: saved.minY, width: 900, height: saved.height), display: true)
            try? await Task.sleep(for: .seconds(1))
            layout("narrowest window, \(Int(window.frame.width)) pt")
            check("narrow: the volume slider folds away to make room", buttonsWidth() < wide, "\(Int(buttonsWidth())) vs \(Int(wide))")
            window.setFrame(saved, display: true)
            try? await Task.sleep(for: .seconds(0.8))

            // surfaces: each setting must make (or not make) its blur view, at its strength
            @MainActor func effects(in region: CGRect) -> [NSVisualEffectView] {
                descendants(of: root).compactMap { $0 as? NSVisualEffectView }.filter {
                    let f = $0.convert($0.bounds, to: nil); let r = CGRect(x: region.minX, y: root.bounds.height - region.maxY, width: region.width, height: region.height)
                    return r.insetBy(dx: -2, dy: -2).contains(f) && f.width > 4
                }
            }
            @MainActor func describe(_ views: [NSVisualEffectView]) -> String {
                views.map { String(format: "alpha %.2f %@", $0.alphaValue, $0.blendingMode == .withinWindow ? "within" : "behind") }.joined(separator: ", ")
            }
            let sidebar = CGRect(x: 0, y: 0, width: 240, height: root.bounds.height)
            let before = effects(in: sidebar).count
            check("sidebar at 0 / 0 adds no blur view (the glass alone, as before)", before == 0, describe(effects(in: sidebar)))
            UserDefaults.standard.set(0.6, forKey: "sidebarBlur")
            try? await Task.sleep(for: .seconds(0.6))
            let side = effects(in: sidebar)
            check("sidebar blur 0.6: one behind-window blur at 0.6 inside the sidebar", side.count == 1 && abs(side[0].alphaValue - 0.6) < 0.01 && side[0].blendingMode == .behindWindow, describe(side))

            let barRect = frames["bar"] ?? .zero
            check("bar as Liquid Glass adds no blur view", effects(in: barRect).isEmpty, describe(effects(in: barRect)))
            UserDefaults.standard.set("frosted", forKey: "barStyle")
            UserDefaults.standard.set(0.5, forKey: "barBlur")
            try? await Task.sleep(for: .seconds(0.6))
            let bar = effects(in: frames["bar"] ?? barRect)
            check("bar Frosted, blur 0.5: one within-window blur at 0.5 inside the bar", bar.count == 1 && abs(bar[0].alphaValue - 0.5) < 0.01 && bar[0].blendingMode == .withinWindow, describe(bar))
            layout("Frosted bar")

            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.2))
            let whole = CGRect(origin: .zero, size: root.bounds.size)
            @MainActor func nowPlayingBlur() -> [NSVisualEffectView] {
                effects(in: whole).filter { $0.blendingMode == .withinWindow && $0.convert($0.bounds, to: nil).width >= root.bounds.width - 2 }
            }
            check("Now Playing at its default: a full-window blur at 1.0", nowPlayingBlur().map(\.alphaValue) == [1], describe(nowPlayingBlur()))
            UserDefaults.standard.set(0.3, forKey: "nowPlayingBlur")
            try? await Task.sleep(for: .seconds(0.6))
            check("Now Playing blur 0.3: the blur follows", nowPlayingBlur().count == 1 && abs(nowPlayingBlur()[0].alphaValue - 0.3) < 0.01, describe(nowPlayingBlur()))
            check("… and with little blur, the fill keeps the floor (readable)", abs(Look.readable(solid: 0, blur: 0.3) - 0.21) < 0.001 && Look.readable(solid: 0.5, blur: 0) == 0.5)
            player.showNowPlaying = false
            try? await Task.sleep(for: .seconds(0.8))

            returnDefaults()
            try? await Task.sleep(for: .seconds(0.4))
            report("bar: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    @MainActor private static func buttonsWidth() -> CGFloat { frames["bar.buttons"]?.width ?? 0 }

    /// With `NN_SELFTEST_PERF="<search>"` (test server, muted; add NN_FORCE_MOTION=1 so the background moves even
    /// with the window behind others): plays the first result, then holds each screen for NN_SELFTEST_PERF_HOLD
    /// seconds (default 12), reporting "perf: phase <name>" as each starts, so CPU can be sampled from outside.
    static func runPerfIfAsked(player: Player) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_PERF"] else { return }
        let hold = ProcessInfo.processInfo.environment["NN_SELFTEST_PERF_HOLD"].flatMap(Double.init) ?? 12
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), let found = try? await API.search(query), !found.songs.isEmpty
            else { report("perf: test server and a search needed"); NSApp.terminate(nil); return }
            borrowDefaults(["nowPlayingPanel", "animateBackdrop"])
            if !player.isMuted { player.toggleMute() }
            // above other windows for the run: a covered window is not drawn, so "visible" phases measured nothing (7 Oct)
            NSApp.windows.first { $0.styleMask.contains(.titled) }?.level = .floating
            player.play(found.songs.prefix(3).map(Track.init))
            try? await Task.sleep(for: .seconds(6))                       // buffering, artwork, the first lyrics
            // (name, Now Playing open, its panel, background moving)
            let phases: [(String, Bool, NowPlayingPanel, Bool)] = [
                ("main window", false, .none, true), ("Now Playing alone", true, .none, true),
                ("Now Playing + Up Next", true, .upNext, true), ("Now Playing + Lyrics", true, .lyrics, true),
                ("Lyrics, still bg", true, .lyrics, false), ("Up Next, still bg", true, .upNext, false),
                ("Now Playing alone, still bg", true, .none, false), ("main window, still bg", false, .none, false),
                ("Recently Played, playing song shown", false, .none, false),
                ("idle: paused, Home", false, .none, false),
                ("playing, window minimised", false, .none, false),
                ("playing, Home, window visible", false, .none, false),
            ]
            // NN_SELFTEST_PERF_PHASES="main window|Now Playing alone": only these
            let only = ProcessInfo.processInfo.environment["NN_SELFTEST_PERF_PHASES"].map { Set($0.split(separator: "|").map(String.init)) }
            for (name, open, panel, moving) in phases where only?.contains(name) ?? true {
                UserDefaults.standard.set(moving, forKey: "animateBackdrop")
                UserDefaults.standard.set(panel.rawValue, forKey: "nowPlayingPanel")
                player.showNowPlaying = open
                // the list where the playing song shows its animated speaker (its play was just recorded)
                if name == "Recently Played, playing song shown" { NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.recent)) }
                let window = NSApp.windows.first { $0.styleMask.contains(.titled) && $0.title != "Settings" }
                if name.hasPrefix("idle") || name.hasPrefix("playing, ") {
                    NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
                }
                if name.hasPrefix("idle") { if player.isPlaying { player.togglePlayPause() } }
                if name.hasPrefix("playing, ") && !player.isPlaying { player.togglePlayPause() }
                if name == "playing, window minimised" { window?.miniaturize(nil) }
                if name == "playing, Home, window visible" { window?.deminiaturize(nil) }
                try? await Task.sleep(for: .seconds(2))                   // transitions finish before sampling
                report("perf: phase \(name)")
                if let w = window { report("perf: window visible \(w.occlusionState.contains(.visible)), minimised \(w.isMiniaturized)") }
                try? await Task.sleep(for: .seconds(hold))
            }
            await interactionPhases(player: player, songs: found.songs.map(Track.init), hold: hold, only: only)
            report("perf: done")
            returnDefaults()
            NSApp.terminate(nil)
        }
    }

    /// Interactions, each repeated for the whole hold so the samples measure what it costs while you use the app
    /// ("about 1% while interacting", 7 Oct). The window is not the active one (a test cannot make it so), but it is
    /// above the others, so it is drawn. Each reports what it did, as evidence that it really happened.
    private static func interactionPhases(player: Player, songs: [Track], hold: Double, only: Set<String>?) async {
        UserDefaults.standard.set(false, forKey: "animateBackdrop")
        let window = NSApp.windows.first { $0.styleMask.contains(.titled) && $0.title != "Settings" }
        var done = 0
        let phases: [(String, @MainActor () async -> Void, @MainActor () async -> Void)] = [
            ("act: Now Playing opens and closes every 2 s", {
                player.showNowPlaying = false
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            }, {
                player.showNowPlaying.toggle(); done += 1
                try? await Task.sleep(for: .seconds(2))
            }),
            ("act: Now Playing panels switch every 2 s", {
                player.showNowPlaying = true
            }, {
                let order: [NowPlayingPanel] = [.upNext, .lyrics, .none]
                UserDefaults.standard.set(order[done % 3].rawValue, forKey: "nowPlayingPanel"); done += 1
                try? await Task.sleep(for: .seconds(2))
            }),
            ("act: the next song every 3 s", {
                player.showNowPlaying = false
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            }, {
                player.play(songs, startAt: done % max(1, min(songs.count, 4))); done += 1
                try? await Task.sleep(for: .seconds(3))
            }),
            ("act: scrolling Recently Played", {
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.recent))
            }, {
                // a trackpad flick down, then back up: 20 steps over 0.4 s each way, the way fingers move
                let down = await scroll(window, by: -12, steps: 20)
                let up = await scroll(window, by: 12, steps: 20)
                if down && up { done += 1 }
                try? await Task.sleep(for: .seconds(1))
            }),
            ("act: typing a search", {
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            }, {
                // "arijit singh" at 150 ms a letter (one search fires, after the 350 ms pause), its results, then cleared
                guard let root = window?.contentView?.superview,
                      let field = descendants(of: root).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Songs, artists, albums" })
                else { try? await Task.sleep(for: .seconds(1)); return }
                for text in (1...12).map({ String("arijit singh".prefix($0)) }) + ["", ""] {
                    field.stringValue = text
                    (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    try? await Task.sleep(for: .milliseconds(text.isEmpty ? 1000 : 150))
                    if text.count == 12 { try? await Task.sleep(for: .seconds(2)) }   // the results arrive and show
                }
                done += 1
            }),
        ]
        for (name, setup, step) in phases where only?.contains(name) ?? true {
            if !player.isPlaying { player.togglePlayPause() }
            await setup()
            try? await Task.sleep(for: .seconds(1.5))
            done = 0
            let actions = Task { @MainActor in while !Task.isCancelled { await step() } }
            try? await Task.sleep(for: .seconds(1))
            report("perf: phase \(name)")
            try? await Task.sleep(for: .seconds(hold))
            actions.cancel()
            report("perf: \(name): \(done) time(s)")
            try? await Task.sleep(for: .seconds(0.5))
        }
        player.showNowPlaying = false
    }

    /// Posts trackpad scroll events (began, changed…, ended) at the middle of the window's content, into the app's
    /// own queue, 20 ms apart. True if a scroll view under that point moved.
    private static func scroll(_ window: NSWindow?, by dy: Int32, steps: Int) async -> Bool {
        guard let window, let content = window.contentView else { return false }
        let inWindow = NSPoint(x: content.bounds.midX + 80, y: content.bounds.midY)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let screenTop = NSScreen.screens.first?.frame.height ?? 0
        let scrollView = content.hitTest(inWindow).flatMap { v in sequence(first: v, next: \.superview).first { $0 is NSScrollView } } as? NSScrollView
        let before = scrollView?.contentView.bounds.origin.y
        for i in 0...(steps + 1) {
            let phase: Int64 = i == 0 ? 1 : i == steps + 1 ? 4 : 2                       // began, changed, ended
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: phase == 2 ? dy : 0, wheel2: 0, wheel3: 0)
            else { continue }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            cg.location = CGPoint(x: onScreen.x, y: screenTop - onScreen.y)
            if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
        return before != nil && scrollView?.contentView.bounds.origin.y != before
    }

    /// With `NN_SELFTEST_CONNECTION=1` (its own test server, muted): five songs that cannot play stop the player at the
    /// third with a "Stopped" message (they used to cycle through the whole queue); then the server stops, the banner's
    /// state turns to "not connected", and Try Again's steps bring it back.
    static func runConnectionCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_CONNECTION"] != nil else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("connection: refusing: the server answering was not started by this test"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("connection \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            if !player.isMuted { player.toggleMute() }
            // made-up JioSaavn ids: the server answers 404 at once, nothing outside is asked
            let broken = (1...5).map { n in
                Track(best: Listing(source: "jiosaavn", id: "selftest-gone-\(n)", title: "Gone \(n)", artists: ["Self-test"], album: nil,
                                    duration: 200, popularity: nil, image: nil), listings: [])
            }
            player.play(broken)
            var stopped = false
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                if !player.isPlaying && !player.isBuffering && (player.errorMessage ?? "").hasPrefix("Stopped") { stopped = true; break }
            }
            report("connection: now on \(player.current?.title ?? "-"), playing \(player.isPlaying), message: \(player.errorMessage ?? "-")")
            check("five songs that cannot play: it stops at the third and says so", stopped && player.current?.title == "Gone 3")

            check("the server answers at first: no banner", Connectivity.shared.serverAnswers)
            ServerLauncher.shared.stop()
            try? await Task.sleep(for: .seconds(1))
            await Connectivity.shared.checkServer()
            check("the server stopped: the banner says Server not connected", !Connectivity.shared.serverAnswers)
            await ServerLauncher.shared.ensureRunning()                          // what Try Again does
            let back = await Connectivity.shared.checkServer()
            check("Try Again: the server starts again and the banner goes", back && Connectivity.shared.serverAnswers)
            report("connection: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_COVERS="<search>|<search>"`: loads the results' covers at list size (44 pt), then at Now Playing
    /// size (560 pt), and reports the decoded pixels held for each (the app's phys_footprint did not show them, 7 Oct).
    static func runCoversCheckIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["NN_SELFTEST_COVERS"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("covers: refusing: the server answering was not started by this test"); NSApp.terminate(nil); return }
            var urls: [URL] = []
            for q in spec.split(separator: "|") {
                if let found = try? await API.search(String(q)) { urls += found.songs.compactMap { Track(best: $0.best, listings: $0.listings).image } }
            }
            urls = Array(Set(urls))
            @MainActor func pixelsMB(_ size: CGFloat) async -> (mb: Double, side: Int) {
                var bytes = 0, side = 0
                for url in urls {
                    if let cg = await ArtworkCache.shared.image(for: url, size: size)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        bytes += cg.bytesPerRow * cg.height; side = max(side, cg.width)
                    }
                }
                return (Double(bytes) / 1_048_576, side)
            }
            let s = await pixelsMB(44)
            let l = await pixelsMB(560)
            report(String(format: "covers: decoded pixels held: list size %.1f MB (largest %d px), Now Playing size %.1f MB (largest %d px)", s.mb, s.side, l.mb, l.side))
            NSApp.terminate(nil)
        }
    }

    /// With `NN_SELFTEST_EXPLICIT="<search>"` (its own test server): a song that has an explicit and a clean version
    /// plays the explicit one by default and the clean one with Settings › Playback › clean; the flags reach the app.
    static func runExplicitCheckIfAsked() {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_EXPLICIT"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), let found = try? await API.search(query) else { report("explicit: refusing, or the search failed"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("explicit \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let flagged = found.songs.flatMap(\.listings).filter { $0.explicit != nil }.count
            let total = found.songs.flatMap(\.listings).count
            check("every listing in the search carries the flag", flagged == total, "\(flagged) of \(total)")
            guard let both = found.songs.first(where: { s in s.listings.contains { $0.explicit == true } && s.listings.contains { $0.explicit == false } }) else {
                check("a song with both versions in the results", false); NSApp.terminate(nil); return
            }
            report("explicit: \(both.title): \(both.listings.filter { $0.explicit == true }.count) explicit and \(both.listings.filter { $0.explicit == false }.count) clean copies; the server's pick is \(both.best.explicit == true ? "explicit" : "clean")")
            borrowDefaults(["versionPreference"])
            UserDefaults.standard.removeObject(forKey: "versionPreference")
            check("by default the explicit version is the one that plays", Track(best: both.best, listings: both.listings).best.explicit == true)
            UserDefaults.standard.set("clean", forKey: "versionPreference")
            check("with Playback › clean, the clean version plays", Track(best: both.best, listings: both.listings).best.explicit == false)
            returnDefaults()
            report("explicit: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// What Settings › Footprint shows (it sets this each second).
    static var footprint: (app: FootprintMeter.Reading?, server: FootprintMeter.Reading?) = (nil, nil)

    /// With `NN_SELFTEST_FOOTPRINT=1`: opens Settings › Footprint and reports its readings for ~8 s, each line with the
    /// time, so `top` run alongside can be compared.
    static func runFootprintCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_FOOTPRINT"] != nil else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
            else { report("footprint: no Settings item"); NSApp.terminate(nil); return }
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .seconds(1.5))
            guard let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) }),
                  let tab = settings.toolbar?.items.first(where: { $0.label == "Footprint" }), let action = tab.action
            else { report("footprint: no Footprint tab"); NSApp.terminate(nil); return }
            NSApp.sendAction(action, to: tab.target, from: tab)
            report("footprint: app pid \(getpid()), server pids \(ServerLauncher.shared.serverPIDs)")
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                let (a, s) = footprint
                report(String(format: "footprint: t=%.0f app %@ | server %@", Date().timeIntervalSince1970,
                              a.map { String(format: "%.1f%% %.0f MB", $0.cpu, Double($0.memory) / 1_048_576) } ?? "-",
                              s.map { String(format: "%.1f%% %.0f MB (%d)", $0.cpu, Double($0.memory) / 1_048_576, $0.processes) } ?? "-"))
            }
            NSApp.terminate(nil)
        }
    }

    /// The lyrics panel's lit line, and which screen it shows ("loading", "none", "plain", "unreachable"); the
    /// panel sets them, the lyrics check reads them.
    static var lyricsCurrent: Int?
    /// Clicks line N (TimedLines sets it): for when the window cannot become key, so a posted click cannot reach it.
    static var lyricsJump: ((Int) -> Void)?
    static var lyricsShown = ""

    /// With `NN_SELFTEST_LYRICS="<timed song>|<instrumental>|<a JioSaavn song>"` (test server only, muted, the
    /// Downloads-selftest folder). Reports counts, line numbers and positions: never a lyric.
    static func runLyricsCheckIfAsked(player: Player, lyrics: LyricsStore, downloads: DownloadStore) {
        guard let spec = ProcessInfo.processInfo.environment["NN_SELFTEST_LYRICS"] else { return }
        let parts = spec.split(separator: "|").map(String.init)
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), parts.count == 3, downloads.folder.lastPathComponent == "Downloads-selftest",
                  let found = try? await API.search(parts[0]), found.songs.count >= 3,
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })
            else { report("lyrics: test server, three searches and the test folder needed"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("lyrics \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func finish() {
                returnDefaults()
                report("lyrics: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            @MainActor func waitFound(_ track: Track, seconds: Double = 25) async -> Lyrics? {
                for _ in 0..<Int(seconds * 10) {
                    if case .found(let found) = lyrics.state(for: track) { return found }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return nil
            }
            @MainActor func describe(_ l: Lyrics?) -> String {
                guard let l else { return "nothing" }
                return "\(l.sourceName ?? "nobody"), \(l.synced ? "timed" : "not timed"), \(l.lines.count) lines"
            }
            borrowDefaults(["lyricsFetch", "nowPlayingPanel"])
            UserDefaults.standard.set(LyricsFetch.songStart.rawValue, forKey: "lyricsFetch")
            UserDefaults.standard.set(NowPlayingPanel.lyrics.rawValue, forKey: "nowPlayingPanel")
            if !player.isMuted { player.toggleMute() }

            // 1. a song starts: its lyrics, and the next song's, arrive without opening anything
            let songs = found.songs.prefix(3).map(Track.init)
            let start = Date()
            player.play(Array(songs))
            let timed = await waitFound(songs[0])
            report(String(format: "lyrics: %@: %@, after %.1f s", songs[0].title, describe(timed), Date().timeIntervalSince(start)))
            check("the playing song's lyrics arrive when it starts", timed != nil)
            let next = await waitFound(songs[1])
            report("lyrics: the next song, \(songs[1].title): \(describe(next))")
            check("the next song's lyrics are fetched ahead", next != nil)
            guard let timed, timed.synced, timed.lines.count >= 20, let firstStart = timed.lines[0].startMs else {
                check("the first song has timed lyrics with 20+ lines (pick another search)", false); finish(); return
            }

            // 2. Now Playing with Lyrics: the lines are there; a seek lights its line and brings it to the middle
            player.showNowPlaying = true
            if player.isPlaying { player.togglePlayPause() }               // paused: the light follows the seek exactly
            try? await Task.sleep(for: .seconds(1.5))
            check("the panel shows every line", (0..<timed.lines.count).allSatisfy { frames["lyrics.line.\($0)"] != nil })
            if firstStart > 1500 {
                player.seek(to: 0)
                try? await Task.sleep(for: .seconds(0.6))
                check("before the first line (the intro): nothing is lit", lyricsCurrent == nil, "\(String(describing: lyricsCurrent))")
            }
            player.seek(to: Double(timed.lines[10].startMs ?? 0) / 1000 + 0.3)
            try? await Task.sleep(for: .seconds(1.4))                       // the scroll animation takes 0.55 s
            check("seek into line 10: line 10 is lit", lyricsCurrent == 10, "\(String(describing: lyricsCurrent))")
            if let line = frames["lyrics.line.10"], let panel = frames["lyrics.panel"] {
                report(String(format: "lyrics: line 10's centre is %.0f pt from the panel's centre", line.midY - panel.midY))
                check("… and sits in the middle of the panel (within 40 pt)", abs(line.midY - panel.midY) < 40)
            }

            // 3. a real click on line 13: the song plays from where that line starts
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            if let row = frames["lyrics.line.13"], let panel = frames["lyrics.panel"], panel.contains(CGPoint(x: row.minX + 30, y: row.midY)) {
                let p = NSPoint(x: row.minX + 30, y: window.contentView!.frame.height - row.midY)
                // macOS refuses to bring an app forward while you use another one, and a click on a window that is
                // not key only selects it: then the line's own action is called, and the report says so
                if !window.isKeyWindow {
                    report("lyrics: the window cannot become key now (another app is in use): calling line 13's action instead of a click")
                    lyricsJump?(13)
                } else { for type in Array(repeating: [NSEvent.EventType.leftMouseDown, .leftMouseUp], count: window.isKeyWindow ? 1 : 2).flatMap({ $0 }) {
                    if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                } }
                try? await Task.sleep(for: .seconds(0.3))
                let target = Double(timed.lines[13].startMs ?? 0) / 1000
                report(String(format: "lyrics: clicked line 13 (starts %.2f s): now at %.2f s, %@", target, player.position, player.isPlaying ? "playing" : "paused"))
                check("click line 13: the song jumps to where it starts, and plays", abs(player.position - target) < 0.6 && player.isPlaying)
                try? await Task.sleep(for: .seconds(0.4))
                check("… and line 13 is lit", lyricsCurrent == 13, "\(String(describing: lyricsCurrent))")
            } else {
                check("line 13 is on screen to click", false)
            }

            // with NN_SELFTEST_LYRICS_HOLD=<seconds>: stay playing that long with Lyrics, then with Up Next, so the
            // panel's CPU can be measured from outside (top), against the same screen without it
            if let hold = ProcessInfo.processInfo.environment["NN_SELFTEST_LYRICS_HOLD"].flatMap(Double.init) {
                report("lyrics: hold lyrics \(Date().timeIntervalSince1970)")
                try? await Task.sleep(for: .seconds(hold))
                UserDefaults.standard.set(NowPlayingPanel.upNext.rawValue, forKey: "nowPlayingPanel")
                report("lyrics: hold upnext \(Date().timeIntervalSince1970)")
                try? await Task.sleep(for: .seconds(hold))
                player.showNowPlaying = false
                report("lyrics: hold closed \(Date().timeIntervalSince1970)")
                try? await Task.sleep(for: .seconds(hold))
                player.showNowPlaying = true
                report("lyrics: hold end \(Date().timeIntervalSince1970)")
                UserDefaults.standard.set(NowPlayingPanel.lyrics.rawValue, forKey: "nowPlayingPanel")
            }

            // 3b. switching from Up Next to Lyrics opens at the playing line, not scrolled there in front of you
            if player.isPlaying { player.togglePlayPause() }
            UserDefaults.standard.set(NowPlayingPanel.upNext.rawValue, forKey: "nowPlayingPanel")
            try? await Task.sleep(for: .seconds(1))
            player.seek(to: Double(timed.lines[24].startMs ?? 0) / 1000 + 0.3)
            try? await Task.sleep(for: .seconds(0.5))
            UserDefaults.standard.set(NowPlayingPanel.lyrics.rawValue, forKey: "nowPlayingPanel")
            try? await Task.sleep(for: .seconds(0.15))                      // far less than any animation
            if let line = frames["lyrics.line.24"], let panel = frames["lyrics.panel"] {
                report(String(format: "lyrics: 0.15 s after switching to Lyrics, line 24 is %.0f pt from the panel's centre", line.midY - panel.midY))
                check("switching to Lyrics opens at the playing line (within 40 pt at once)", abs(line.midY - panel.midY) < 40 && lyricsCurrent == 24,
                      String(format: "%.0f pt, lit %@", line.midY - panel.midY, String(describing: lyricsCurrent)))
            } else {
                check("the lyrics panel came back", false)
            }

            // 4. an instrumental: nobody has words, the panel says so
            if let instrumental = try? await API.search(parts[1]), let song = instrumental.songs.first.map(Track.init) {
                player.play([song])
                let none = await waitFound(song)
                try? await Task.sleep(for: .seconds(1))
                report("lyrics: \(song.title): \(describe(none)); the panel shows \"\(lyricsShown)\"")
                check("an instrumental: no lines, and the panel says Couldn't find lyrics", none?.lines.isEmpty == true && lyricsShown == "none")
            }
            player.showNowPlaying = false

            // 5. a download keeps its lyrics, and they show with the server off
            downloads.removeAll()
            guard let jio = try? await API.search(parts[2]),
                  let song = jio.songs.map(Track.init).first(where: { $0.best.source == "jiosaavn" }) else {
                check("a JioSaavn song to download", false); finish(); return
            }
            let downloaded = await downloads.download(song, quietly: true)
            var saved: Lyrics?
            for _ in 0..<150 where saved == nil {                          // the download hands its lyrics over in the background
                saved = downloads.lyrics(for: song)
                if saved == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            report("lyrics: downloaded \(song.title): \(downloaded ? "yes" : "no"); lyrics kept beside it: \(describe(saved))")
            check("a download keeps its lyrics beside the file", downloaded && saved != nil)
            let fromServer = try? await API.lyrics(for: song)
            check("… the same lyrics the server gives", saved != nil && saved == fromServer)

            ServerLauncher.shared.stop()
            try? await Task.sleep(for: .seconds(1))
            check("the server is really off", !(await API.health()))
            lyrics.forget(song)
            lyrics.fetch(song)
            check("server off: the downloaded song's lyrics come from its file", lyrics.state(for: song) == saved.map { .found($0) })
            lyrics.forget(songs[2])
            lyrics.fetch(songs[2])
            for _ in 0..<50 where lyrics.state(for: songs[2]) == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            check("server off, not downloaded: the panel can say it couldn't reach the server", lyrics.state(for: songs[2]) == .unreachable,
                  "\(String(describing: lyrics.state(for: songs[2])))")

            downloads.removeAll()
            let left = (try? FileManager.default.contentsOfDirectory(atPath: downloads.folder.path))?.filter { $0 != "index.json" } ?? []
            check("remove all: the lyrics files go too", left.isEmpty, "\(left.count) files left")
            finish()
        }
    }

    /// With `NN_SELFTEST_SNAP=<folder>`: saves the app's own window as `<folder>/<name>.png` (no screen recording:
    /// the window draws itself into an image). Scenarios call it at the moments worth looking at.
    static func snap(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"],
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let frame = window.contentView?.superview else { return }
        snapshot(frame, to: URL(filePath: folder).appending(path: "\(name).png"))
        // the same window drawn from its layers: lists (table views) draw into layers, which the method above can miss
        if let layer = frame.layer {
            let scale = window.backingScaleFactor
            let size = CGSize(width: frame.bounds.width * scale, height: frame.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                if frame.isFlipped { ctx.translateBy(x: 0, y: frame.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let url = URL(filePath: folder).appending(path: "\(name)-layers.png")
                    do { try rep.representation(using: .png, properties: [:])?.write(to: url); report("wrote \(url.path)") }
                    catch { report("could not write \(url.path)") }
                }
            }
        }
    }

    /// Written straight through, not buffered: with the output going to a file, `print` held every line until the
    /// app quit, so nothing outside could follow a run while it happened (6 Oct).
    static func report(_ line: String) { FileHandle.standardOutput.write(Data("SELFTEST \(line)\n".utf8)) }

    private static func center(of r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// "ClassName < Parent < Grandparent": enough to tell the sidebar from the detail column
    private static func describe(_ view: NSView?) -> String {
        var names: [String] = []
        var v = view
        while let current = v, names.count < 5 { names.append(String(describing: type(of: current))); v = current.superview }
        return names.isEmpty ? "nothing" : names.joined(separator: " < ")
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let png = { view.cacheDisplay(in: view.bounds, to: rep); return rep.representation(using: .png, properties: [:]) }()
        else { report("could not draw the window"); return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            report("wrote \(url.path)")
        } catch {
            report("could not write \(url.path): \(error.localizedDescription)")    // never claim a file that is not there
        }
    }
}

// inside #if DEBUG with the rest: in a Release build this file has no imports, and only debug code uses these
extension Notification.Name {
    /// A self-test asks RootView to show something (object: a playlist's UUID, or a Destination).
    static let selfTestOpen = Notification.Name("NNSelfTestOpen")
    /// A self-test asks SearchView to play its first result, as a double-click on that row would.
    static let selfTestPlayFirstResult = Notification.Name("NNSelfTestPlayFirstResult")
}
#endif
