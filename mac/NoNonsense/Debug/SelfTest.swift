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
                report("t=\(second)s  song: \(player.current?.title ?? "-")  playing: \(player.isPlaying)  buffering: \(player.isBuffering)  message: \(player.errorMessage ?? "-")")
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

    private static func report(_ line: String) { print("SELFTEST", line) }

    private static func center(of r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

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
#endif
