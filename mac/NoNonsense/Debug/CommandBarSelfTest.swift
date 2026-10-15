#if DEBUG
import AppKit

/// With `NN_SELFTEST_COMMANDBAR=1` (test server only, muted; no internet needed): the command bar, driven from inside as
/// the keyboard drives it. The matching rule; the field in the toolbar (at most 560 wide, about 32 tall) and the list 8 pt
/// under it; what the list offers with nothing typed, without and with a song; ↑ ↓ going round; Return running Lyrics
/// (Now Playing with the Lyrics panel) and Settings (its window); Esc; / and ⌘K taking the keyboard, what is typed
/// selected; a click on a row and outside (when the window can be key); "All results" opening Search already searched,
/// where the bar is hidden; L and M from the window's key monitor, but not while the bar has the keyboard. With
/// `NN_SELFTEST_SNAP=<folder>` and `NN_SELFTEST_VISIBLE=1`: pictures of the open list.
extension SelfTest {
    private static var startedCommandBar = false
    /// What the command bar's list shows, line by line (headings, rows, "Searching…"), and its hint: the list sets them.
    static var commandRows: [String] = []
    static var commandHint = ""

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
            /// Types into the bar's field as the search test types into Search's: the text, then the call SwiftUI hears.
            @MainActor func type(_ text: String) async {
                guard let typed = field(barPlaceholder) else { return }
                typed.stringValue = text
                (typed.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: typed))
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func settle(_ milliseconds: Int = 400) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            @MainActor func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
            /// Through the app, as a real key comes: the window's key monitor hears it first (L, M, /).
            @MainActor func toApp(_ event: NSEvent?) { if let event { NSApp.sendEvent(event) } }
            /// To whatever has the keyboard (the field's editor): through the app while the window is key, else straight
            /// to the window, which hands it to its first responder.
            @MainActor func toField(_ event: NSEvent?) {
                guard let event else { return }
                if window.isKeyWindow { NSApp.sendEvent(event) } else { window.sendEvent(event) }
            }
            let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
            @MainActor func up() { toField(key(126, "\u{F700}", arrow)) }
            @MainActor func down() { toField(key(125, "\u{F701}", arrow)) }
            @MainActor func enter() { toField(key(36, "\r")) }
            @MainActor func escape() { toField(key(53, "\u{1B}")) }
            /// ⌘K itself, through the app: only while the window is key (false otherwise).
            @MainActor func commandK() -> Bool {
                guard window.isKeyWindow, let event = key(40, "k", .command) else { return false }
                NSApp.sendEvent(event)
                return true
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

            // the field, in the toolbar on Home
            await settle(800)
            guard let barField = field(barPlaceholder), let place = bar.fieldFrame else {
                check("the command bar's field is in the toolbar", false); finish(); return
            }
            let titleBar = window.frame.height - window.contentLayoutRect.maxY
            check("the field is in the toolbar, at most 560 wide and about 32 tall", place.maxY <= titleBar + 1 && place.width <= 560.5 && abs(place.height - 32) < 1.5,
                  "field \(place), title bar \(titleBar)")

            // ⌘K's request: the keyboard and the list. Nothing playing, nothing typed: where to start
            bar.summon()
            await settle()
            check("⌘K's request gives the field the keyboard and opens the list", bar.open && hasKeyboard(barField))
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

            // Esc: what is typed goes, and so does the keyboard
            await type("abc")
            escape()
            await settle()
            check("Esc empties the field and leaves it (the list closes)", bar.query.isEmpty && !bar.open && !hasKeyboard(barField),
                  "“\(bar.query)”, open \(bar.open)")

            // / from the window's key monitor: the keyboard, and the / is not typed
            toApp(key(44, "/"))
            await settle()
            check("/ gives the field the keyboard", bar.open && hasKeyboard(barField) && bar.query.isEmpty, "“\(bar.query)”, open \(bar.open)")

            // letting go (a click outside) keeps what is typed; ⌘K then selects it all, and again while the field has the keyboard
            await type("abc")
            bar.leave()
            await settle()
            check("letting go keeps what is typed", !bar.open && bar.query == "abc", "“\(bar.query)”, open \(bar.open)")
            if !commandK() { report("commandbar SKIP ⌘K itself: the window cannot be key while another app is in use; its request instead"); bar.summon() }
            await settle()
            let editor = window.firstResponder as? NSTextView
            check("⌘K gives the field the keyboard with what is typed selected", bar.open && editor?.selectedRange() == NSRange(location: 0, length: 3),
                  "\(String(describing: editor?.selectedRange()))")
            editor?.setSelectedRange(NSRange(location: 3, length: 0))
            if !commandK() { bar.summon() }
            await settle()
            check("…and again while it has the keyboard", (window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 3))
            escape()
            await settle()

            // a song (made up: it cannot play, and stays the song)
            let listing = Listing(source: "jiosaavn", id: "selftest-commandbar-\(UInt32.random(in: 0 ... .max))", title: "Made-Up Song",
                                  artists: ["Kai"], album: "Made-Up Album", duration: 200, popularity: nil, image: nil)
            let song = Track(best: listing, listings: [listing])
            player.play([song])
            try? await Task.sleep(for: .seconds(2))
            bar.summon()
            await settle()
            let playLabel = player.isPlaying ? "Pause" : "Play", likeLabel = library.isLiked(song) ? "Remove from Liked Songs" : "Like"
            check("a song, nothing typed: SUGGESTED: Play or Pause, Next Song, Like, Lyrics, Up Next, then the jam",
                  commandRows == ["SUGGESTED", playLabel, "Next Song", likeLabel, "Lyrics", "Up Next", "Start or Join a Jam"], "\(commandRows)")
            windowShot("commandbar-suggested")

            // ↑ ↓ go round
            bar.chosen = 0
            let count = bar.entries().count
            up()
            await settle(200)
            check("↑ on the first row chooses the last", bar.chosen == count - 1, "\(bar.chosen) of \(count)")
            down()
            await settle(200)
            check("↓ on the last row chooses the first", bar.chosen == 0, "\(bar.chosen)")

            // a click on a row runs it, and a click outside lets go (clicks need the window key)
            if window.isKeyWindow, let row = frames["commandBar.row:Up Next"] {
                click(CGPoint(x: row.midX, y: row.midY))
                await settle(800)
                check("a click on Up Next opens Now Playing with Up Next, and the field lets go",
                      player.showNowPlaying && UserDefaults.standard.string(forKey: "nowPlayingPanel") == NowPlayingPanel.upNext.rawValue && !bar.open)
                player.showNowPlaying = false
                await settle(800)
                bar.summon()
                await settle()
                if let place = bar.fieldFrame {
                    click(CGPoint(x: min(place.maxX + 60, window.frame.width - 160), y: place.midY))   // the toolbar, right of the field
                    await settle()
                }
                check("a click outside the field and the list closes the list", !bar.open && !hasKeyboard(barField))
            } else {
                report("commandbar SKIP clicks: the window cannot be key while another app is in use")
            }

            // "lyr": Lyrics under ACTIONS, and Return opens Now Playing with the Lyrics panel
            bar.summon()
            await settle()
            await type("lyr")
            check("“lyr”: ACTIONS, Lyrics first, All results for “lyr” last",
                  commandRows.first == "ACTIONS" && commandRows.dropFirst().first == "Lyrics" && commandRows.last == "All results for “lyr”", "\(commandRows)")
            check("…and the hint for typing", commandHint == (bar.songs.isEmpty ? runHint : playHint), commandHint)
            windowShot("commandbar-lyr")
            enter()
            await settle(800)
            check("Return runs Lyrics: Now Playing opens with the Lyrics panel",
                  player.showNowPlaying && UserDefaults.standard.string(forKey: "nowPlayingPanel") == NowPlayingPanel.lyrics.rawValue)
            check("running a row empties the field and lets it go", bar.query.isEmpty && !bar.open, "“\(bar.query)”, open \(bar.open)")
            player.showNowPlaying = false
            await settle(800)

            // "sett" and Return: the Settings window
            bar.summon()
            await settle()
            await type("sett")
            check("“sett” finds Settings", commandRows.contains("Settings"), "\(commandRows)")
            let before = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            enter()
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

            // "go art" offers Go to Artist; "rtist" does not
            bar.summon()
            await settle()
            await type("go art")
            check("“go art” offers Go to Artist", commandRows.contains("Go to Artist"), "\(commandRows)")
            await type("rtist")
            check("“rtist” does not", !commandRows.contains("Go to Artist"), "\(commandRows)")

            // L and M typed while the bar has the keyboard are text; from the window's key monitor they like and mute
            let liked = library.isLiked(song), muted = player.isMuted
            await type("")
            toApp(key(37, "l"))
            toApp(key(46, "m"))
            await settle()
            check("with the bar's keyboard, L and M are text: nothing liked, nothing muted", library.isLiked(song) == liked && player.isMuted == muted)
            if window.isKeyWindow { check("…they are in the field", bar.query == "lm", "“\(bar.query)”") }
            escape()
            await settle()
            toApp(key(37, "l"))
            for _ in 0..<20 where library.isLiked(song) == liked { await settle(50) }
            check("L likes the song playing", library.isLiked(song) != liked)
            toApp(key(46, "m"))
            await settle(100)
            check("M mutes or unmutes", player.isMuted != muted)
            if player.isMuted != muted { toApp(key(46, "m")) }               // muted again
            if library.isLiked(song) != liked { toApp(key(37, "l")) }      // and the song as it was
            await settle()

            // All results: Search, already searched; the bar is not on the Search page, and ⌘K there is Search's field
            bar.summon()
            await settle()
            await type("abc")
            for _ in 0..<50 where bar.searching { await settle(100) }        // the songs found settle the rows first
            up()
            await settle(200)
            let entries = bar.entries()
            check("↑ from the first row reaches All results for “abc”",
                  entries.indices.contains(bar.chosen) && entries[bar.chosen].title == "All results for “abc”", "\(bar.chosen) of \(entries.count)")
            enter()
            await settle(1000)
            check("All results opens Search with the words in its own field", field(searchPlaceholder)?.stringValue == "abc",
                  field(searchPlaceholder)?.stringValue ?? "no Search field")
            check("on the Search page the bar is hidden", field(barPlaceholder) == nil && !bar.onScreen)
            _ = window.makeFirstResponder(nil)
            if commandK() {
                await settle()
                check("⌘K on Search gives Search's own field the keyboard", hasKeyboard(field(searchPlaceholder)))
            }
            finish()
        }
    }
}
#endif
