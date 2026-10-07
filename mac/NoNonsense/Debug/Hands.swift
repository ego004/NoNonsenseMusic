#if DEBUG
import AppKit
import SwiftUI

/// Real input, for the checks that need hands: events posted where the trackpad's go (the system's HID event tap), so
/// they reach the app the way yours do, through the window server, with the real pointer moving. Synthetic events
/// posted into the app's own queue skip the window server: they cannot start an AppKit drag, and scroll views treat
/// them differently, so the checks that matter for "does it work for me" use these.
///
/// Needs Accessibility permission for whatever launched the app (a run from Claude's shell inherits it). Every event
/// is aimed at a point of the test window and refused when another window is on top there: a real click lands on
/// whatever is on top, and this must never click in your other apps.
@MainActor
enum RealInput {
    static var allowed: Bool { CGPreflightPostEventAccess() }
    static var window: NSWindow?
    static var behaviour: NSWindow.CollectionBehavior = []             // the window's own, put back at the end
    /// Events not sent because another window was on top at their point, and whose window it was.
    static var refused = 0
    static var inTheWay: Set<String> = []

    /// A point in the window's content, top-left origin (SwiftUI's `.global` frames), on the screen (AppKit's coordinates).
    static func appKit(_ p: CGPoint) -> NSPoint? {
        guard let window, let content = window.contentView else { return nil }
        return window.convertPoint(toScreen: NSPoint(x: p.x, y: content.bounds.height - p.y))
    }

    /// The same point in Core Graphics' coordinates (top-left of the main screen).
    static func cg(_ p: CGPoint) -> CGPoint? {
        guard let s = appKit(p) else { return nil }
        return CGPoint(x: s.x, y: (NSScreen.screens.first?.frame.height ?? 0) - s.y)
    }

    /// The app that owns a window, and the window's layer (0 normal, 3 floating, above: panels and the system's).
    static func owner(of number: Int) -> String {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
        return "\(info?[kCGWindowOwnerName as String] as? String ?? "?") (layer \(info?[kCGWindowLayer as String] as? Int ?? -1))"
    }

    /// The test window is the one on top at this point.
    static func isOurs(_ p: CGPoint) -> Bool {
        guard let window, let s = appKit(p) else { return false }
        return NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    @discardableResult
    static func mouse(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) -> Bool {
        guard isOurs(p) else {
            refused += 1
            if let s = appKit(p) {
                inTheWay.insert(owner(of: NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0))
                                + "; ours: level \(window?.level.rawValue ?? -1), visible \(window?.isVisible == true), on this Space \(window?.isOnActiveSpace == true), app active \(NSApp.isActive)")
            }
            return false
        }
        guard let at = cg(p), let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { return false }
        event.setIntegerValueField(.mouseEventClickState, value: clicks)
        event.post(tap: .cghidEventTap)
        return true
    }

    /// One click, or a double-click (`count: 2`), as a trackpad sends them.
    static func click(_ p: CGPoint, count: Int = 1) async -> Bool {
        guard mouse(.mouseMoved, p) else { return false }
        try? await Task.sleep(for: .milliseconds(80))
        for n in 1...count {
            guard mouse(.leftMouseDown, p, clicks: Int64(n)) else { return false }
            try? await Task.sleep(for: .milliseconds(40))
            mouse(.leftMouseUp, p, clicks: Int64(n))
            try? await Task.sleep(for: .milliseconds(70))
        }
        return true
    }

    /// Press, hold, move in steps (60 a second), hold, let go.
    static func drag(from a: CGPoint, to b: CGPoint, steps: Int = 30, hold: Duration = .milliseconds(200)) async -> Bool {
        guard mouse(.mouseMoved, a) else { return false }
        try? await Task.sleep(for: .milliseconds(80))
        guard mouse(.leftMouseDown, a) else { return false }
        try? await Task.sleep(for: hold)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: hold)
        mouse(.leftMouseUp, b)
        return true
    }

    /// Makes the test app the active one with a click on its title bar, as a hand would (a program may not just take
    /// the front: macOS refuses while you use another app). Tries three times.
    static func activate() async -> Bool {
        guard let window, let content = window.contentView else { return false }
        for _ in 0..<3 where !(NSApp.isActive && window.isKeyWindow) {
            window.orderFrontRegardless()
            _ = await click(CGPoint(x: content.bounds.width / 2, y: 12))
            try? await Task.sleep(for: .milliseconds(400))
        }
        return NSApp.isActive && window.isKeyWindow
    }

    /// One key, pressed and let go. Only into our own window while it is the key window.
    static func key(_ code: CGKeyCode) async -> Bool {
        guard NSApp.isActive, window?.isKeyWindow == true else { return false }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Two fingers on a trackpad: began, `steps` moves of (dx, dy) points, ended; no coasting after.
    static func scroll(at p: CGPoint, dx: Int32, dy: Int32, steps: Int, every: Duration = .milliseconds(16)) async -> Bool {
        guard mouse(.mouseMoved, p), let at = cg(p) else { return false }
        try? await Task.sleep(for: .milliseconds(60))
        for i in 0...(steps + 1) {
            let phase: Int64 = i == 0 ? 1 : i == steps + 1 ? 4 : 2
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: phase == 2 ? dy : 0, wheel2: phase == 2 ? dx : 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.location = at
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: every)
        }
        return true
    }

    /// A pinch, `total` = how much it grows (+0.3: fingers apart). macOS has no public way to make one: this posts the
    /// gesture events trackpads produce (type 29, zoom), as reverse-engineered by others. It may not arrive at all;
    /// `magnifySeen` says whether AppKit turned it into a magnify event.
    static func pinch(at p: CGPoint, total: Double, steps: Int = 12) async -> Bool {
        guard mouse(.mouseMoved, p), let at = cg(p) else { return false }
        try? await Task.sleep(for: .milliseconds(60))
        for i in 0...(steps + 1) {
            let phase: Int64 = i == 0 ? 1 : i == steps + 1 ? 4 : 2       // began, changed, ended
            guard let event = CGEvent(source: nil), let gesture = CGEventType(rawValue: 29),
                  let kind = CGEventField(rawValue: 110), let value = CGEventField(rawValue: 113), let stage = CGEventField(rawValue: 132)
            else { return false }
            event.type = gesture
            event.setIntegerValueField(kind, value: 8)                      // IOHIDEventType zoom: a pinch
            event.setIntegerValueField(stage, value: phase)
            event.setDoubleValueField(value, value: phase == 2 ? total / Double(steps) : 0)
            event.location = at
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(16))
        }
        return true
    }
}

/// A value a closure that runs later can change (a captured `var` cannot be, from concurrent code).
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension SelfTest {
    /// With `NN_SELFTEST_HANDS="<search>"` (its own test server, muted): the checks that needed your hands, done with
    /// real input (`RealInput`): the pointer MOVES by itself for about a minute, so leave the trackpad alone.
    /// Click-to-seek, ← →, a double-click between the bar's controls, a pinch on the bar, the Up Next drag and
    /// double-click, Esc, a drag inside a playlist, a sideways swipe on a Home shelf, and a song that ends at its
    /// listed length. Every check reads the app's state afterwards. The test library is put back as it was.
    static func runHandsCheckIfAsked(player: Player, library: LibraryStore) {
        guard let query = ProcessInfo.processInfo.environment["NN_SELFTEST_HANDS"] else { return }
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer() else { report("hands: refusing: the server answering was not started by this test"); NSApp.terminate(nil); return }
            guard RealInput.allowed else { report("hands: SKIP all: this process may not post input events (Accessibility)"); NSApp.terminate(nil); return }
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("hands \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func skip(_ rule: String, _ why: String) { report("hands SKIP \(rule): \(why)") }
            @MainActor func finish() {
                if let counter { NSEvent.removeMonitor(counter) }
                RealInput.window?.collectionBehavior = RealInput.behaviour
                RealInput.window?.level = .normal
                returnDefaults()
                report("hands: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            // NN_SELFTEST_HANDS_ONLY="bar|upnext|playlist|sidebar|home|tail": only these parts
            let only = ProcessInfo.processInfo.environment["NN_SELFTEST_HANDS_ONLY"].map { Set($0.split(separator: "|").map(String.init)) }
            func wants(_ part: String) -> Bool { only?.contains(part) ?? true }
            // what actually arrived in the app, per part: evidence for a FAIL (the app ignored it, or it never came)
            let seen = Box<[String: Int]>([:])
            let counter = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .scrollWheel, .magnify, .keyDown]) { event in
                let name = switch event.type {
                case .leftMouseDown: "down×\(event.clickCount)"
                case .leftMouseDragged: "dragged"
                case .scrollWheel: event.scrollingDeltaX != 0 ? "scroll dx \(Int(event.scrollingDeltaX)) dy \(Int(event.scrollingDeltaY)) phase \(event.phase.rawValue)" : "scroll (no dx) dy \(Int(event.scrollingDeltaY)) phase \(event.phase.rawValue)"
                case .magnify: "magnify"
                default: "key"
                }
                seen.value[name, default: 0] += 1
                return event
            }
            @MainActor func arrived() -> String {
                defer { seen.value = [:]; RealInput.refused = 0; RealInput.inTheWay = [] }
                let got = seen.value.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                return (got.isEmpty ? "nothing" : got)
                    + (RealInput.refused > 0 ? ", \(RealInput.refused) not sent (on top: \(RealInput.inTheWay.sorted().joined(separator: ", ")))" : "")
            }
            /// Before each part: the app active again (anything you click elsewhere takes that away)
            @MainActor func ready(_ part: String) async -> Bool {
                guard wants(part) else { return false }
                if await RealInput.activate() { _ = arrived(); return true }
                skip(part, "the test window could not be made the active one (another app in use?)")
                return false
            }
            borrowDefaults(["nowPlayingPanel", "shuffle", "repeatMode"])
            UserDefaults.standard.set(false, forKey: "shuffle")
            if !player.isMuted { player.toggleMute() }

            // the window: in the middle of the screen, above every other, the active one
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.title != "Settings" }),
                  let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { report("hands: no window"); finish(); return }
            let size = CGSize(width: min(1180, screen.width - 40), height: min(820, screen.height - 20))
            window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
            window.level = .floating
            // on every Space, and over a full-screen app: the Space you look at changes under the test (7 Oct: Claude's
            // Space came back and the test window was left on another, so its events would have landed on Claude)
            RealInput.behaviour = window.collectionBehavior
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            RealInput.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            _ = await RealInput.activate()
            report("hands: app active \(NSApp.isActive), window key \(window.isKeyWindow), accessibility trusted \(AXIsProcessTrusted())")

            // the test library: 14 liked songs (Liked Songs reaches under the bar), 10 played (Home's shelf scrolls)
            guard let found = try? await API.search(query), found.songs.count >= 14 else { report("hands: a search with 14 songs needed"); finish(); return }
            let songs = found.songs.map(Track.init)
            var likedHere: [Track] = []
            for song in songs.prefix(14) where !library.isLiked(song) { await library.toggleLike(song); likedHere.append(song) }
            for song in songs.prefix(10) { try? await API.event(song.listings, type: "play", position: 0) }
            await library.refresh()

            // ── the bar ──
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.liked))
            player.play(Array(songs.prefix(8)), startAt: 0)
            for _ in 0..<40 where !(player.isPlaying && !player.isBuffering && player.duration > 30) { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1))
            if await ready("bar") {
            let textScale = CGFloat(UserDefaults.standard.object(forKey: "textScale") as? Double ?? Double(Look.textScale))
            if let line = frames["bar.progress"], player.duration > 30 {
                let label = (Font.TextStyle.caption2.macPointSize * textScale * 3.6).rounded(.up) + 8
                let x = line.minX + label + 0.25 * (line.width - 2 * label)
                _ = await RealInput.click(CGPoint(x: x, y: line.midY))
                try? await Task.sleep(for: .milliseconds(500))
                let expected = 0.25 * player.duration
                check("a click on the progress line seeks there (¼ of the way)", abs(player.livePosition - expected) < max(3, player.duration * 0.02),
                      String(format: "%.1f s, expected %.1f s", player.livePosition, expected))
            } else { skip("click-to-seek", "no progress line or no song (\(player.duration) s)") }

            let before = player.livePosition
            if await RealInput.key(124) {                                  // →
                try? await Task.sleep(for: .milliseconds(300))
                let after = player.livePosition
                check("→ goes 5 s on", abs(after - before - 5.3) < 1.2, String(format: "%.1f → %.1f", before, after))
                _ = await RealInput.key(123)                               // ←
                try? await Task.sleep(for: .milliseconds(300))
                check("← goes 5 s back", abs(player.livePosition - after + 4.7) < 1.2, String(format: "%.1f → %.1f", after, player.livePosition))
            } else { skip("← →", "the window is not the key window") }

            // a double-click on a row plays it (so double-clicks do arrive); the same between the bar's controls does nothing
            if let bar = frames["bar"], let centre = frames["bar.centre"] {
                let row = CGPoint(x: centre.midX, y: bar.minY - 40)              // a Liked Songs row just above the bar
                let current = player.current?.id
                _ = await RealInput.click(row, count: 2)
                try? await Task.sleep(for: .seconds(1))
                let rowWorks = player.current?.id != current
                check("control: a double-click on a song row above the bar plays it", rowWorks)
                try? await Task.sleep(for: .seconds(1.5))
                let gap = CGPoint(x: centre.minX + 6, y: bar.minY + 14)          // the top-left corner of the bar's centre: no control
                let playing = player.current?.id
                _ = await RealInput.click(gap, count: 2)
                try? await Task.sleep(for: .seconds(1))
                if rowWorks {
                    check("a double-click between the bar's controls does nothing (it fell through to the song under the bar)",
                          player.current?.id == playing && !player.showNowPlaying)
                } else { skip("a double-click between the bar's controls", "double-clicks did not arrive at the row either") }
                // a pinch out on the same empty spot opens Now Playing
                let magnifies = Box(0)
                let monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { magnifies.value += 1; return $0 }
                _ = await RealInput.pinch(at: gap, total: 0.4)
                try? await Task.sleep(for: .milliseconds(600))
                if let monitor { NSEvent.removeMonitor(monitor) }
                if magnifies.value == 0 { skip("a pinch on the bar opens Now Playing", "the made-up pinch never arrived as a magnify event (no public way to make one)") }
                else { check("a pinch out between the bar's controls opens Now Playing (\(magnifies.value) magnify events)", player.showNowPlaying) }
                player.showNowPlaying = false
                try? await Task.sleep(for: .seconds(0.6))
            } else { skip("the bar's empty spots", "no bar frames") }
            report("hands: the bar: arrived \(arrived())")
            }

            // ── Up Next ──
            if await ready("upnext") {
            UserDefaults.standard.set(NowPlayingPanel.upNext.rawValue, forKey: "nowPlayingPanel")
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.5))
            let entries = player.upNextEntries
            if entries.count >= 4, let row0 = frames["upNext.row:0"], let row2 = frames["upNext.row:2"] {
                let ok = await RealInput.drag(from: CGPoint(x: row0.midX, y: row0.midY), to: CGPoint(x: row0.midX, y: row2.midY))
                try? await Task.sleep(for: .seconds(0.8))
                let expected = [entries[1], entries[2], entries[0], entries[3]].map(\.id)
                let got = player.upNextEntries.prefix(4).map(\.id)
                check("Up Next: drag the first row down two places", ok && Array(got) == expected,
                      "\(player.upNextEntries.prefix(4).map(\.track.title))")
                report("hands: Up Next drag: arrived \(arrived())")
                try? await Task.sleep(for: .seconds(0.5))
                // where the first row is: the place row 0 had before the drag (the lifted row's own frame keeps the name
                // "row:0" after it lands two places down, so that frame is stale)
                if let first = Optional(row0) {
                    let wanted = player.upNextEntries.first?.track
                    _ = await RealInput.click(CGPoint(x: first.midX, y: first.midY), count: 2)
                    try? await Task.sleep(for: .seconds(1))
                    check("Up Next: a double-click plays the row", player.current?.id == wanted?.id,
                          "now \(player.current?.title ?? "-"), wanted \(wanted?.title ?? "-"); row 0 at \(first.integral); arrived \(arrived())")
                }
            } else { skip("Up Next drag", "\(entries.count) songs queued, row frames \(frames["upNext.row:0"] != nil)") }
            if await RealInput.key(53) {                                   // Esc
                try? await Task.sleep(for: .seconds(0.6))
                check("Esc closes Now Playing", !player.showNowPlaying)
            } else { skip("Esc", "the window is not the key window") }
            player.showNowPlaying = false
            }

            // ── a playlist ──
            if await ready("playlist") {
            let name = "Hands test \(Int.random(in: 1000...9999))"
            if await library.createPlaylist(named: name) == nil, let summary = library.playlists.first(where: { $0.name == name }) {
                for song in songs.prefix(4) { await library.add(song, to: summary) }
                NotificationCenter.default.post(name: .selfTestOpen, object: summary.id)
                try? await Task.sleep(for: .seconds(2))
                if let row0 = frames["playlist.row:0"], let row3 = frames["playlist.row:3"] {
                    // the 4th row to the top: let go just inside the first row's top edge
                    // held by the title (left, after the cover), where a hand takes a row: the centre can be a button
                    let grab = row3.minX + 90
                    let ok = await RealInput.drag(from: CGPoint(x: grab, y: row3.midY), to: CGPoint(x: grab, y: row0.minY + 2),
                                                  steps: 40, hold: .milliseconds(300))
                    try? await Task.sleep(for: .seconds(1.5))
                    let expected = [songs[3], songs[0], songs[1], songs[2]].map(\.title)
                    let screen = library.details[summary.id]?.tracks.map(\.title) ?? []
                    await library.loadPlaylist(summary.id)
                    let server = library.details[summary.id]?.tracks.map(\.title) ?? []
                    check("a playlist: drag the 4th song to the top (the screen)", ok && screen == expected, screen.joined(separator: " | ") + "; arrived \(arrived())")
                    check("… and the server agrees", server == expected, server.joined(separator: " | "))
                    // a double-click on the 2nd row plays it (the list's own double-click now)
                    try? await Task.sleep(for: .seconds(0.5))
                    if let row1 = frames["playlist.row:1"], let wanted = library.details[summary.id]?.tracks[1] {
                        _ = await RealInput.click(CGPoint(x: grab, y: row1.midY), count: 2)
                        try? await Task.sleep(for: .seconds(1))
                        check("a playlist: a double-click plays the row", player.current?.isSameSong(as: wanted) == true,
                              "now \(player.current?.title ?? "-"), wanted \(wanted.title)")
                        // a right-click opens the row's menu (Play, Play Next, …); Esc closes it
                        let menus = Box(0)
                        let watcher = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in menus.value += 1 }
                        if RealInput.isOurs(CGPoint(x: grab, y: row1.midY)), let at = RealInput.cg(CGPoint(x: grab, y: row1.midY)) {
                            for type in [CGEventType.rightMouseDown, .rightMouseUp] {
                                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .right)?.post(tap: .cghidEventTap)
                                try? await Task.sleep(for: .milliseconds(60))
                            }
                            try? await Task.sleep(for: .seconds(0.8))
                            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                            try? await Task.sleep(for: .seconds(0.5))
                        }
                        NotificationCenter.default.removeObserver(watcher)
                        check("a playlist: a right-click on a row opens its menu", menus.value > 0)
                    }
                } else { skip("playlist drag", "no row frames") }
                if let current = library.playlists.first(where: { $0.id == summary.id }) { await library.deletePlaylist(current) }
            } else { skip("playlist drag", "could not create the test playlist") }
            }

            // ── control: the sidebar's playlists, a List with no double-click gesture on its rows ──
            if library.playlists.count >= 3, await ready("sidebar") {
                let names = library.playlists.map(\.name)
                if let first = frames["sidebar.title:\(names[0])"], let third = frames["sidebar.title:\(names[2])"] {
                    _ = arrived()
                    let ok = await RealInput.drag(from: CGPoint(x: third.midX, y: third.midY), to: CGPoint(x: first.midX, y: first.minY - 2),
                                                  steps: 40, hold: .milliseconds(300))
                    try? await Task.sleep(for: .seconds(1.5))
                    let now = library.playlists.map(\.name)
                    check("control: the sidebar's 3rd playlist dragged to the top", ok && now.first == names[2],
                          now.prefix(3).joined(separator: " | ") + "; arrived \(arrived())")
                    if now.first == names[2] { await library.movePlaylists(from: IndexSet([0]), to: 3) }     // back to its place
                } else { skip("sidebar drag", "no sidebar frames") }
            }

            // ── diagnosis: a double-click in Up Next without a drag first; a vertical scroll on a list ──
            if only?.contains("debug") == true, await ready("debug") {
                UserDefaults.standard.set(NowPlayingPanel.upNext.rawValue, forKey: "nowPlayingPanel")
                player.play(Array(songs.prefix(8)), startAt: 0)
                try? await Task.sleep(for: .seconds(2))
                player.showNowPlaying = true
                try? await Task.sleep(for: .seconds(1.5))
                let titles = player.upNextEntries.prefix(4).map(\.track.title)
                for i in 0..<4 { report("hands: debug: row \(i) \(titles[i]) at \(frames["upNext.row:\(i)"]?.integral ?? .zero)") }
                if let row1 = frames["upNext.row:1"] {
                    _ = arrived()
                    _ = await RealInput.click(CGPoint(x: row1.midX, y: row1.midY), count: 2)
                    try? await Task.sleep(for: .seconds(1))
                    report("hands: debug: double-click on row 1 (\(titles[1])), no drag before: now \(player.current?.title ?? "-"); arrived \(arrived())")
                }
                try? await Task.sleep(for: .seconds(1))
                let after = player.upNextEntries.prefix(4).map(\.track.title)
                for i in 0..<4 { report("hands: debug: now row \(i) \(after[i]) at \(frames["upNext.row:\(i)"]?.integral ?? .zero)") }
                if let row0 = frames["upNext.row:0"], let row2 = frames["upNext.row:2"] {
                    _ = await RealInput.drag(from: CGPoint(x: row0.midX, y: row0.midY), to: CGPoint(x: row0.midX, y: row2.midY))
                    try? await Task.sleep(for: .seconds(1.2))
                    let moved = player.upNextEntries.prefix(4).map(\.track.title)
                    for i in 0..<4 { report("hands: debug: after the drag row \(i) \(moved[i]) at \(frames["upNext.row:\(i)"]?.integral ?? .zero)") }
                    if let first = frames["upNext.row:0"] {
                        _ = arrived()
                        _ = await RealInput.click(CGPoint(x: first.midX, y: first.midY), count: 2)
                        try? await Task.sleep(for: .seconds(1))
                        report("hands: debug: double-click on row 0 (\(moved[0])) after the drag: now \(player.current?.title ?? "-"); arrived \(arrived())")
                    }
                }
                player.showNowPlaying = false
                try? await Task.sleep(for: .seconds(0.8))
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.liked))
                try? await Task.sleep(for: .seconds(2))
                if let content = window.contentView {
                    let at = CGPoint(x: content.bounds.width * 0.6, y: content.bounds.height * 0.45)
                    let inWindow = NSPoint(x: at.x, y: content.bounds.height - at.y)
                    if let list = content.superview?.hitTest(inWindow)?.enclosingScrollView {
                        let before = list.contentView.bounds.origin.y
                        _ = arrived()
                        _ = await RealInput.scroll(at: at, dx: 0, dy: -12, steps: 20)
                        try? await Task.sleep(for: .milliseconds(600))
                        report("hands: debug: vertical swipe on Liked Songs (\(type(of: list)), document \(list.documentView.map { "\($0.frame.size)" } ?? "-")): moved \(list.contentView.bounds.origin.y - before) pt; arrived \(arrived())")
                    } else { report("hands: debug: no scroll view under the list's centre") }
                }
            }

            // ── Home ──
            if await ready("home") {
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            try? await Task.sleep(for: .seconds(2))
            for shelfName in ["home.recentShelf", "home.likedShelf"] {
            if let shelf = frames[shelfName], let content = window.contentView {
                report("hands: Home: \(shelfName)")
                let at = CGPoint(x: shelf.midX, y: shelf.midY)
                let inWindow = NSPoint(x: at.x, y: content.bounds.height - at.y)
                let scrolls = descendants(of: content).compactMap { $0 as? NSScrollView }
                    .filter { $0.convert($0.bounds, to: nil).contains(inWindow) }
                let page = scrolls.max { $0.frame.height < $1.frame.height }
                let row = scrolls.first { ($0.documentView?.frame.width ?? 0) > $0.frame.width + 1 && $0 !== page }
                for v in scrolls {
                    report("hands: Home: scroll view \(type(of: v)) frame \(v.frame.integral) document \(v.documentView.map { "\($0.frame.size)" } ?? "-") at \(v.contentView.bounds.origin) \(v === page ? "PAGE" : v === row ? "SHELF" : "")")
                }
                let hit = content.superview?.hitTest(inWindow)
                report("hands: Home: the shelf's centre hits \(hit.map { "\(type(of: $0))" } ?? "nothing"), in \(hit?.enclosingScrollView.map { "\(type(of: $0)) \($0.frame.integral)" } ?? "no scroll view")")
                _ = arrived()
                if let page, let row {
                    for (label, dy) in [("sideways", Int32(0)), ("sideways and a little down, as fingers move", Int32(-3))] {
                        report("hands: Home: before the swipe: the player's barFrame \(player.barFrame.integral), skips so far \(player.nextPresses + player.previousPresses), playing \(player.current?.title ?? "-")")
                        let docBefore = row.documentView?.convert(row.documentView?.bounds ?? .zero, to: nil).minX ?? 0
                        let pageBefore = page.contentView.bounds.origin.y, shelfBefore = row.contentView.bounds.origin.x
                        let pageMoved = Box<CGFloat>(0)
                        let sampler = Task { @MainActor in
                            while !Task.isCancelled {
                                pageMoved.value = max(pageMoved.value, abs(page.contentView.bounds.origin.y - pageBefore))
                                try? await Task.sleep(for: .milliseconds(8))
                            }
                        }
                        // towards the shelf's end; if it sat at that end already, the other way
                        _ = await RealInput.scroll(at: at, dx: -18, dy: dy, steps: 20)
                        try? await Task.sleep(for: .milliseconds(600))
                        if abs(row.contentView.bounds.origin.x - shelfBefore) < 1 {
                            _ = await RealInput.scroll(at: at, dx: 18, dy: dy, steps: 20)
                            try? await Task.sleep(for: .milliseconds(600))
                        }
                        sampler.cancel()
                        let shelfMoved = abs(row.contentView.bounds.origin.x - shelfBefore)
                        report("hands: Home: the shelf's content moved \(Int((row.documentView?.convert(row.documentView?.bounds ?? .zero, to: nil).minX ?? 0) - docBefore)) pt in the window; frames: first cover \(frames["home.cover:0"]?.integral ?? .zero)")
                        report("hands: Home: after: skips so far \(player.nextPresses + player.previousPresses), playing \(player.current?.title ?? "-")")
                        check("Home: a swipe \(label) on a shelf moves the shelf, not the page",
                              shelfMoved > 50 && pageMoved.value < 1, String(format: "shelf %.0f pt, page %.1f pt", shelfMoved, pageMoved.value) + "; arrived \(arrived())")
                    }
                } else { skip("Home shelf", "scroll views not found (\(scrolls.count) under the shelf)") }
            } else { skip("Home shelf", "no \(shelfName) on Home") }
            }
            }

            // ── a song that ends at its listed length ──
            if wants("tail"), let tail = ProcessInfo.processInfo.environment["NN_SELFTEST_HANDS_TAIL"],
               let result = try? await API.search(tail), let song = result.songs.first.map(Track.init),
               let youtube = song.listings.first(where: { $0.source == "ytmusic" }) {
                player.play([song.playing(youtube), songs[0]], startAt: 0)
                for _ in 0..<40 where !(player.isPlaying && !player.isBuffering) { try? await Task.sleep(for: .milliseconds(250)) }
                let listed = Double(youtube.duration)
                player.seek(to: listed - 3)
                try? await Task.sleep(for: .seconds(6))
                check("\"\(youtube.title)\" (YouTube, listed \(Int(listed)) s) moves on at its listed length",
                      player.current?.id == songs[0].id, "still on \(player.current?.title ?? "-") at \(Int(player.livePosition)) s")
            }

            for song in likedHere where library.isLiked(song) { await library.toggleLike(song) }
            finish()
        }
    }
}

/// Frame times, from the screen's own refresh (a display link on the window): a frame shown later than the screen's
/// next refresh is a hitch, what you feel as a stutter. Measures the app's main thread keeping up, which is what a
/// SwiftUI list needs while it scrolls.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    private(set) var refresh: Double = 1 / 60

    func start(on view: NSView) {
        intervals = []; last = 0
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        refresh = link.duration > 0 ? link.duration : refresh
        if last > 0 { intervals.append(link.timestamp - last) }
        last = link.timestamp
    }

    /// "n frames, h late (x%), worst y ms" at the screen's rate
    var summary: String {
        let late = intervals.filter { $0 > refresh * 1.5 }
        return String(format: "%d frames at %.0f Hz, %d late (%.1f%%), worst %.0f ms, late time %.0f ms",
                      intervals.count, 1 / refresh, late.count, intervals.isEmpty ? 0 : 100 * Double(late.count) / Double(intervals.count),
                      (intervals.max() ?? 0) * 1000, late.reduce(0) { $0 + $1 - refresh } * 1000)
    }
    var lateShare: Double { intervals.isEmpty ? 0 : Double(intervals.filter { $0 > refresh * 1.5 }.count) / Double(intervals.count) }
}

extension SelfTest {
    /// With `NN_SELFTEST_SCROLL="<search>|<search>|…"` (its own test server, muted, real input: the pointer moves):
    /// likes every song those searches find (Liked Songs gets long), plays one, opens Liked Songs, and flicks the list
    /// down and up with trackpad scrolls, NN_SELFTEST_SCROLL_ROUNDS times (default 4), counting late frames (`FrameClock`).
    /// The likes are taken back at the end. `NN_SELFTEST_SCROLL_IN=playlist` (a List) or `home` scrolls there instead.
    /// Pair it with Instruments' Animation Hitches for the frames the screen missed (the display link sees only the app).
    static func runScrollCheckIfAsked(player: Player, library: LibraryStore) {
        guard let queries = ProcessInfo.processInfo.environment["NN_SELFTEST_SCROLL"]?.split(separator: "|").map(String.init) else { return }
        let rounds = Int(ProcessInfo.processInfo.environment["NN_SELFTEST_SCROLL_ROUNDS"] ?? "") ?? 4
        Task {
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(), RealInput.allowed else { report("scroll: own test server and Accessibility needed"); NSApp.terminate(nil); return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.title != "Settings" }),
                  let screen = (window.screen ?? NSScreen.main)?.visibleFrame, let content = window.contentView else { NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            let size = CGSize(width: min(1180, screen.width - 40), height: min(820, screen.height - 20))
            window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
            window.level = .floating
            RealInput.behaviour = window.collectionBehavior
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            RealInput.window = window
            _ = await RealInput.activate()

            var songs: [Track] = []
            for q in queries {
                if let found = try? await API.search(q) { songs += found.songs.map(Track.init).filter { s in !songs.contains { $0.id == s.id } } }
                try? await Task.sleep(for: .seconds(1))                  // searches spaced out: no burst at YouTube
            }
            var likedHere: [UUID] = []                                   // song ids, to take the likes back
            for song in songs where !library.isLiked(song) {
                if let id = try? await API.like(song.listings) { likedHere.append(id) }
            }
            await library.refresh()
            report("scroll: Liked Songs has \(library.liked.count) songs (\(likedHere.count) liked by this test); swipe monitor on (off cost nothing measurable: 8 ms of 3.2 s, 8 Oct)")
            player.play(Array(library.liked.prefix(5)), startAt: 0)
            // NN_SELFTEST_SCROLL_IN=playlist: the same songs as a playlist (a List: an AppKit table) instead of Liked Songs
            var playlistHere: PlaylistSummary?
            if ProcessInfo.processInfo.environment["NN_SELFTEST_SCROLL_IN"] == "playlist" {
                let name = "Scroll test \(Int.random(in: 1000...9999))"
                if await library.createPlaylist(named: name) == nil, let summary = library.playlists.first(where: { $0.name == name }) {
                    for song in library.liked { _ = try? await API.add(song.listings, to: summary.id) }
                    await library.loadPlaylist(summary.id)
                    playlistHere = summary
                    NotificationCenter.default.post(name: .selfTestOpen, object: summary.id)
                    report("scroll: in a playlist (List) of \(library.details[summary.id]?.items.count ?? 0) songs")
                }
            } else if ProcessInfo.processInfo.environment["NN_SELFTEST_SCROLL_IN"] == "home" {
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
                report("scroll: on Home")
            } else {
                NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.liked))
            }
            try? await Task.sleep(for: .seconds(4))                       // the first covers arrive
            _ = await RealInput.activate()

            let at = CGPoint(x: content.bounds.width * 0.6, y: content.bounds.height * 0.45)
            let clock = FrameClock()
            var shares: [Double] = []
            let list = content.superview?.hitTest(NSPoint(x: at.x, y: content.bounds.height - at.y))?.enclosingScrollView
            report("scroll: rounds start")
            for round in 1...rounds {
                let top = list?.contentView.bounds.origin.y ?? 0
                let travel = Box<CGFloat>(0)
                let sampler = Task { @MainActor in
                    while !Task.isCancelled { travel.value = max(travel.value, (list?.contentView.bounds.origin.y ?? 0) - top); try? await Task.sleep(for: .milliseconds(8)) }
                }
                clock.start(on: content)
                // a flick down the list and back up: 40 moves of 30 pt each way, 60 a second, as fast fingers send them
                let down = await RealInput.scroll(at: at, dx: 0, dy: -30, steps: 40)
                let up = await RealInput.scroll(at: at, dx: 0, dy: 30, steps: 40)
                try? await Task.sleep(for: .milliseconds(300))
                clock.stop()
                sampler.cancel()
                shares.append(clock.lateShare)
                report("scroll: round \(round)\(down && up ? "" : " (events refused: a window on top)"): the list went \(Int(travel.value)) pt down and back; \(clock.summary)")
                try? await Task.sleep(for: .seconds(0.5))
            }
            let sorted = shares.sorted()
            report(String(format: "scroll: median late frames %.1f%% over %d rounds", 100 * sorted[sorted.count / 2], rounds))

            for id in likedHere { try? await API.unlike(id) }
            if let playlistHere, let current = library.playlists.first(where: { $0.id == playlistHere.id }) { await library.deletePlaylist(current) }
            window.collectionBehavior = RealInput.behaviour
            window.level = .normal
            NSApp.terminate(nil)
        }
    }
}
#endif
