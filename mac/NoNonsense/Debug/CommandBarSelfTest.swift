#if DEBUG
import AppKit
import SwiftUI

/// With `NN_SELFTEST_COMMANDBAR=1` (test server only, muted; no internet needed): the command bar. The matching rule;
/// the field in the toolbar, as wide as the toolbar can spare, with Jam and the bell still on it (not in its » menu) at
/// 900 pt with the widest sidebar, a page open and a jam on; the list 8 pt under the field; what the list offers with
/// nothing typed, without and with a song; ↑ ↓ going round; Return running Lyrics (Now Playing with the Lyrics panel),
/// Settings (its window) and "All results" (Search, already searched, where the bar is hidden); ⇧Return putting a song
/// in Up Next; Esc; ⌘K's request and / taking the keyboard, what is typed selected; and L and M as the key monitor
/// decides them, but not while the bar has the keyboard.
///
/// It drives CommandBarState and the key monitor's decision (`Player.heard`) itself: on CI the window cannot be key,
/// and events a test makes pass neither the app's key monitors nor, there, the field. What needs a key window (real
/// keys through the field, clicks, ⌘K itself) runs only when the window is key, and says SKIP otherwise. With
/// `NN_SELFTEST_SNAP=<folder>` and `NN_SELFTEST_VISIBLE=1`: pictures of the open list.
extension SelfTest {
    private static var startedCommandBar = false
    /// What the command bar's list shows, line by line (headings, rows, "Searching…"), and its hint: the list sets them.
    static var commandRows: [String] = []
    static var commandHint = ""
    /// Toolbar items' AppKit views by name (`selfTestToolbarItem`), to tell an item on the toolbar from one in its » menu.
    static var toolbarViews: [String: () -> NSView?] = [:]

    static func runCommandBarCheckIfAsked(player: Player, library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_COMMANDBAR"] != nil, !startedCommandBar else { return }
        startedCommandBar = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("commandbar \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func finish() {
                returnDefaults()
                report("commandbar: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }

            // the matching rule on its own, with the Windows app's examples
            for typed in ["go", "art", "go art", "artist go", "GO TO"] {
                check("“\(typed)” finds Go to Artist", Command.matches(typed, label: "Go to Artist"))
            }
            for typed in ["rtist", "go x", "album"] {
                check("“\(typed)” does not find Go to Artist", !Command.matches(typed, label: "Go to Artist"))
            }
            check("“ball” finds a playlist named Ballin", Command.matches("ball", label: "Ballin"))

            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard await onOwnTestServer(),
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let frame = window.contentView?.superview else {
                report("commandbar: refusing: not on its own test server, or no window"); NSApp.terminate(nil); return
            }
            borrowDefaults(["nowPlayingPanel", "autoplay"])
            UserDefaults.standard.set(false, forKey: "autoplay")          // the made-up song stays the song: no station after it
            if !player.isMuted { player.toggleMute() }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            let bar = CommandBarState.shared
            let barPlaceholder = "Search, or type a command", searchPlaceholder = "Songs, artists, albums"

            /// A text field in the window, the toolbar's included: the bar's, or Search's own.
            @MainActor func field(_ placeholder: String) -> NSTextField? {
                descendants(of: frame).compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
            }
            /// Whether the window's field editor is editing this text field.
            @MainActor func hasKeyboard(_ text: NSTextField?) -> Bool {
                guard let text, let editor = window.firstResponder as? NSTextView else { return false }
                return (editor.delegate as? NSTextField) === text
            }
            @MainActor func barHasKeyboard() -> Bool { hasKeyboard(field(barPlaceholder)) }
            /// Types into the bar's field as the search test types into Search's: the text, then the call SwiftUI hears.
            @MainActor func type(_ text: String) async {
                guard let typed = field(barPlaceholder) else { return }
                typed.stringValue = text
                (typed.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: typed))
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func settle(_ milliseconds: Int = 400) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 20) where !done() { try? await Task.sleep(for: .milliseconds(50)) }
                return done()
            }
            /// A key down as the keyboard makes it, for this window.
            @MainActor func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
            /// What the key monitor does with this key (true: it is the window's, and done).
            @MainActor func monitor(_ event: NSEvent?) -> Bool {
                guard let event else { return false }
                return player.heard(event)
            }
            /// Whether a toolbar item's view is on the toolbar, in the window: not in its » menu.
            @MainActor func onToolbar(_ view: NSView?) -> Bool {
                guard let view, let shown = view.window, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
                let place = view.convert(view.bounds, to: nil)
                return place.width > 1 && place.minX >= -1 && place.maxX <= shown.frame.width + 1
            }
            /// ⌘K's request, and the list once the field has the keyboard. Where the window cannot be key (CI) the field
            /// may not get the keyboard: the list is then opened as the field opens it when it does, so the rest is
            /// still checked. True when the field took the keyboard itself.
            @MainActor func openList() async -> Bool {
                bar.summon()
                let took = await until(1.5) { bar.open && barHasKeyboard() }
                if !bar.open {
                    bar.focusChanged(true)
                    await settle(250)
                }
                return took
            }
            /// A click at a point in SwiftUI's window points, through the event queue (the window must be key).
            @MainActor func click(_ point: CGPoint) {
                let p = NSPoint(x: point.x, y: window.contentView!.frame.height - point.y)
                for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: kind, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
            let runHint = "↑ ↓ choose · Return run · Esc close", playHint = "↑ ↓ choose · Return play · ⇧Return add to Up Next · Esc close"

            // ── the field in the toolbar, and room for Jam and the bell beside it ──
            await settle(800)
            guard field(barPlaceholder) != nil, let place = bar.fieldFrame else {
                check("the command bar's field is in the toolbar", false); finish(); return
            }
            let titleBar = window.frame.height - window.contentLayoutRect.maxY
            check("the field is in the toolbar, about 32 tall, as wide as the toolbar spares it (180…560)",
                  place.maxY <= titleBar + 1 && abs(place.height - 32) < 1.5 && abs(place.width - bar.fieldWidth) < 1.5 && place.width <= 560.5,
                  "field \(place), asks \(bar.fieldWidth), title bar \(titleBar)")
            let savedFrame = window.frame
            let split = descendants(of: frame).compactMap { $0 as? NSSplitView }.first
            let savedSidebar = split?.arrangedSubviews.first?.frame.width
            @MainActor func layOut(width: CGFloat, sidebar: CGFloat) async {
                window.setFrame(NSRect(x: savedFrame.minX, y: savedFrame.minY, width: width, height: savedFrame.height), display: true)
                split?.setPosition(sidebar, ofDividerAt: 0)
                await settle(1000)
            }
            @MainActor func roomCheck(_ moment: String) {
                let jam = onToolbar(toolbarViews["toolbar.jam"]?()), bell = onToolbar(toolbarViews["toolbar.bell"]?())
                let fieldShown = onToolbar(bar.fieldView), width = bar.fieldFrame?.width ?? 0
                check("\(moment): the field, Jam and the bell are all on the toolbar, none in its » menu",
                      jam && bell && fieldShown && width >= 179 && width <= 561,
                      "field \(fieldShown) \(Int(width)) pt, Jam \(jam), bell \(bell), window \(Int(window.frame.width)), column \(Int(bar.columnWidth))")
            }
            await layOut(width: 900, sidebar: 280)
            roomCheck("900 pt wide, sidebar 280")
            await layOut(width: 1024, sidebar: 228)
            roomCheck("1024 pt wide, sidebar 228")
            Navigator.shared.open(.artistNamed("Kai"))                       // Back shows
            let jamProblem = await JamSession.shared.start(named: nil)        // LIVE shows (this account alone, on the test server)
            await layOut(width: 900, sidebar: 280)
            if let jamProblem { report("commandbar SKIP LIVE in the toolbar: no jam started (\(jamProblem))") }
            roomCheck(jamProblem == nil ? "900 pt, sidebar 280, a page open (Back) and in a jam (LIVE)" : "900 pt, sidebar 280, a page open (Back)")
            if jamProblem == nil { await JamSession.shared.leave() }
            Navigator.shared.path = []
            window.setFrame(savedFrame, display: true)
            if let savedSidebar { split?.setPosition(savedSidebar, ofDividerAt: 0) }
            await settle(1000)

            // ── ⌘K's request: the keyboard and the list. Nothing playing, nothing typed: where to start ──
            let took = await openList()
            if took || window.isKeyWindow {
                check("⌘K's request gives the field the keyboard and opens the list", took)
            } else {
                report("commandbar SKIP ⌘K's request taking the keyboard: this window cannot be key, so the list was opened as the field opens it")
            }
            check("nothing playing, nothing typed: SUGGESTED: Start or Join a Jam, New Playlist…, Library, Liked Songs",
                  player.current == nil && commandRows == ["SUGGESTED", "Start or Join a Jam", "New Playlist…", "Library", "Liked Songs"], "\(commandRows)")
            check("…and the hint says the window's keys", commandHint == "Space play or pause · ← → seek · ⌘ ← → skip · L like · M mute", commandHint)
            if let list = frames["commandBar.list"], let place = bar.fieldFrame {
                check("the list hangs 8 pt under the field, from its left edge, max(field, 440) wide",
                      abs(list.minX - place.minX) < 1 && abs(list.minY - place.maxY - 8) < 1 && abs(list.width - max(place.width, 440)) < 1,
                      "list \(list), field \(place)")
            } else {
                check("the list is drawn", false)
            }

            // ── Esc: what is typed goes, and so does the keyboard ──
            await type("abc")
            bar.handle(.escape)
            let letGo = await until(1) { !barHasKeyboard() }
            check("Esc empties the field and leaves it (the list closes)", bar.query.isEmpty && !bar.open && letGo,
                  "“\(bar.query)”, open \(bar.open), keyboard \(!letGo)")

            // ── / as the key monitor decides it, nothing typing: the bar's ──
            _ = window.makeFirstResponder(nil)
            let asked = bar.focusRequests
            check("/ is the bar's while nothing is typed: the field is asked to take the keyboard", monitor(key(44, "/")) && bar.focusRequests == asked + 1)
            await settle()

            // ── letting go (a click outside) keeps what is typed; ⌘K's request then selects it all ──
            await type("abc")
            bar.leave()
            await settle()
            check("letting go keeps what is typed and closes the list", !bar.open && bar.query == "abc", "“\(bar.query)”, open \(bar.open)")
            if await openList() {
                let editor = window.firstResponder as? NSTextView
                check("⌘K's request selects what is typed", editor?.selectedRange() == NSRange(location: 0, length: 3),
                      "\(String(describing: editor?.selectedRange()))")
                editor?.setSelectedRange(NSRange(location: 3, length: 0))
                bar.summon()
                await settle()
                check("…and again while the field has the keyboard", (window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 3))
            } else {
                report("commandbar SKIP the selection: the field did not get the keyboard in this window")
            }
            bar.handle(.escape)
            await settle()

            // ── a song (made up: it cannot play, and stays the song) ──
            let listing = Listing(source: "jiosaavn", id: "selftest-commandbar-\(UInt32.random(in: 0 ... .max))", title: "Made-Up Song",
                                  artists: ["Kai"], album: "Made-Up Album", duration: 200, popularity: nil, image: nil)
            let song = Track(best: listing, listings: [listing])
            player.play([song])
            try? await Task.sleep(for: .seconds(2))
            _ = await openList()
            let playLabel = player.isPlaying ? "Pause" : "Play", likeLabel = library.isLiked(song) ? "Remove from Liked Songs" : "Like"
            check("a song, nothing typed: SUGGESTED: Play or Pause, Next Song, Like, Lyrics, Up Next, then the jam",
                  commandRows == ["SUGGESTED", playLabel, "Next Song", likeLabel, "Lyrics", "Up Next", "Start or Join a Jam"], "\(commandRows)")
            windowShot("commandbar-suggested")

            // ── ↑ ↓ go round ──
            bar.chosen = 0
            let count = bar.entries().count
            bar.handle(.upArrow)
            check("↑ on the first row chooses the last", bar.chosen == count - 1, "\(bar.chosen) of \(count)")
            bar.handle(.downArrow)
            check("↓ on the last row chooses the first", bar.chosen == 0, "\(bar.chosen)")
            if window.isKeyWindow, barHasKeyboard(), let down = key(125, "\u{F701}", [.numericPad, .function]) {
                NSApp.sendEvent(down)
                await settle(200)
                check("↓ typed into the field reaches the list", bar.chosen == 1, "\(bar.chosen)")
                bar.chosen = 0
            } else {
                report("commandbar SKIP keys through the field: this window cannot be key")
            }

            // ── a click on a row runs it, and a click outside lets go (clicks need the window key) ──
            if window.isKeyWindow, let row = frames["commandBar.row:Up Next"] {
                click(CGPoint(x: row.midX, y: row.midY))
                await settle(800)
                check("a click on Up Next opens Now Playing with Up Next, and the field lets go",
                      player.showNowPlaying && UserDefaults.standard.string(forKey: "nowPlayingPanel") == NowPlayingPanel.upNext.rawValue && !bar.open)
                player.showNowPlaying = false
                await settle(800)
                _ = await openList()
                if let place = bar.fieldFrame {
                    click(CGPoint(x: min(place.maxX + 40, window.frame.width - 200), y: place.midY))   // the toolbar, right of the field
                    await settle()
                }
                check("a click outside the field and the list closes the list", !bar.open && !barHasKeyboard())
            } else {
                report("commandbar SKIP clicks: this window cannot be key")
            }

            // ── "lyr": Lyrics under ACTIONS, and Return opens Now Playing with the Lyrics panel ──
            if !bar.open { _ = await openList() }
            await type("lyr")
            check("“lyr”: ACTIONS, Lyrics first, All results for “lyr” last",
                  commandRows.first == "ACTIONS" && commandRows.dropFirst().first == "Lyrics" && commandRows.last == "All results for “lyr”", "\(commandRows)")
            check("…and the hint for typing", commandHint == (bar.songs.isEmpty ? runHint : playHint), commandHint)
            windowShot("commandbar-lyr")
            bar.handle(.return)
            await settle(800)
            check("Return runs Lyrics: Now Playing opens with the Lyrics panel",
                  player.showNowPlaying && UserDefaults.standard.string(forKey: "nowPlayingPanel") == NowPlayingPanel.lyrics.rawValue)
            check("running a row empties the field and lets it go", bar.query.isEmpty && !bar.open && !barHasKeyboard(), "“\(bar.query)”, open \(bar.open)")
            player.showNowPlaying = false
            await settle(800)

            // ── "sett" and Return: the Settings window ──
            _ = await openList()
            await type("sett")
            check("“sett” finds Settings", commandRows.contains("Settings"), "\(commandRows)")
            let before = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            bar.handle(.return)
            var settings: NSWindow?
            for _ in 0..<30 where settings == nil {
                await settle(100)
                settings = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !before.contains(ObjectIdentifier($0)) }
            }
            check("Return on Settings opens the Settings window", settings != nil)
            settings?.close()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await settle(600)

            // ── "go art" offers Go to Artist; "rtist" does not ──
            _ = await openList()
            await type("go art")
            check("“go art” offers Go to Artist", commandRows.contains("Go to Artist"), "\(commandRows)")
            await type("rtist")
            check("“rtist” does not", !commandRows.contains("Go to Artist"), "\(commandRows)")

            // ── L and M: the field's while it has the keyboard; the window's otherwise, where they like and mute ──
            let liked = library.isLiked(song), muted = player.isMuted
            await type("")
            if barHasKeyboard() {
                check("with the bar's keyboard, L and M are the field's: nothing liked, nothing muted",
                      !monitor(key(37, "l")) && !monitor(key(46, "m")) && library.isLiked(song) == liked && player.isMuted == muted)
            } else {
                report("commandbar SKIP L and M while typing: the field did not get the keyboard in this window")
            }
            bar.handle(.escape)
            await settle()
            _ = window.makeFirstResponder(nil)                             // nothing typing
            check("L is the window's while nothing is typed", monitor(key(37, "l")))
            check("…and likes the song playing", await until(1) { library.isLiked(song) != liked })
            check("M is the window's, and mutes or unmutes", monitor(key(46, "m")) && player.isMuted != muted)
            check("⌘L is not the monitor's (the Controls menu's Like)", !monitor(key(37, "l", .command)))
            if player.isMuted != muted { _ = monitor(key(46, "m")) }        // muted again
            if library.isLiked(song) != liked { _ = monitor(key(37, "l")) }  // and the song as it was
            await settle()

            // ── songs found: ⇧Return puts the chosen one in Up Next ──
            _ = await openList()
            await type("abc")
            _ = await until(8) { !bar.searching }
            if let index = bar.entries().firstIndex(where: { $0.song != nil }), let found = bar.entries()[index].song {
                bar.chosen = index
                bar.handle(.return, shift: true)
                await settle()
                check("⇧Return puts the chosen song in Up Next (and the bar closes)", player.upNext.contains { $0.id == found.id } && !bar.open)
            } else {
                report("commandbar SKIP ⇧Return: the server found no songs for “abc” (no internet?)")
            }

            // ── All results: Search, already searched; the bar is not on the Search page ──
            _ = await openList()
            await type("abc")
            _ = await until(8) { !bar.searching }
            bar.chosen = 0
            bar.handle(.upArrow)
            let rows = bar.entries()
            check("↑ from the first row reaches All results for “abc”",
                  rows.indices.contains(bar.chosen) && rows[bar.chosen].title == "All results for “abc”", "\(bar.chosen) of \(rows.count)")
            bar.handle(.return)
            await settle(1000)
            check("All results opens Search with the words in its own field", field(searchPlaceholder)?.stringValue == "abc",
                  field(searchPlaceholder)?.stringValue ?? "no Search field")
            check("on the Search page the bar is hidden", field(barPlaceholder) == nil && !bar.onScreen)
            if window.isKeyWindow, let commandK = key(40, "k", .command) {
                _ = window.makeFirstResponder(nil)
                NSApp.sendEvent(commandK)
                await settle()
                check("⌘K on Search gives Search's own field the keyboard", hasKeyboard(field(searchPlaceholder)))
            } else {
                report("commandbar SKIP ⌘K itself: this window cannot be key")
            }
            finish()
        }
    }
}

extension View {
    /// Debug builds: keeps this toolbar item's AppKit view (SelfTest.toolbarViews[name]), so a self-test can tell whether
    /// the item is on the toolbar or in its » menu. A SwiftUI frame cannot: the toolbar hosts its items apart.
    func selfTestToolbarItem(_ name: String) -> some View {
        background(ToolbarProbe(name: name))
    }
}

private struct ToolbarProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        SelfTest.toolbarViews[name] = { [weak view] in view }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
