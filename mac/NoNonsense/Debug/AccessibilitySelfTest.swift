#if DEBUG
import AppKit
import ApplicationServices

/// With `NN_SELFTEST_A11Y=1` (and NN_SELFTEST_VISIBLE=1 with NN_SELFTEST_SNAP=<folder> for the pictures): the window as
/// VoiceOver gets it (#32), read through the Accessibility API as VoiceOver reads it (needs the app to be allowed to use
/// it, as CI's runner allows). Five made-up songs (a minute of silence each, in the audio cache) play, muted; then on
/// Home, on an album's page (when the server finds one) and with Now Playing open: every button has a name, the time
/// line is a slider saying "m:ss of m:ss" (the time now) and the volume a percentage, the bar names the song, an album's
/// rows read their numbers, and nothing behind Now Playing is in the tree while it is open. Then the keys: with
/// Keyboard navigation on (`-AppleKeyboardUIMode 2`), Space presses the control Tab reached, not play and pause.
extension SelfTest {
    private static var startedA11y = false

    /// One element as VoiceOver reads it: its role, its name, its value and how the value is said.
    nonisolated struct AXItem: Sendable {
        let role: String, subrole: String, name: String, value: String, said: String
        var line: String {
            "\(role)\(subrole.isEmpty ? "" : "/\(subrole)") “\(name)”" + (value.isEmpty ? "" : " value “\(value)”") + (said.isEmpty ? "" : " said “\(said)”")
        }
    }

    /// The main window's elements, asked of this app through the Accessibility API, as VoiceOver asks. SwiftUI builds
    /// its part of the tree for that API: walking the views' own accessibility from inside the app found the toolbar
    /// and the sidebar, but not one button of the page (CI, 15 Oct). From another thread: the answers come from this
    /// app's main thread, which must be free to give them.
    nonisolated static func accessibilityTree() -> [AXItem] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 5)
        func get(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func text(_ value: CFTypeRef?) -> String {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
        guard let windows = get(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: { text(get($0, kAXSubroleAttribute)) == kAXStandardWindowSubrole }) ?? windows.first
        else { return [] }
        var items: [AXItem] = []
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard depth < 60, items.count < 5000 else { return }
            let name = [text(get(element, kAXDescriptionAttribute)), text(get(element, kAXTitleAttribute))].first { !$0.isEmpty } ?? ""
            items.append(AXItem(role: text(get(element, kAXRoleAttribute)), subrole: text(get(element, kAXSubroleAttribute)), name: name,
                                value: text(get(element, kAXValueAttribute)), said: text(get(element, "AXValueDescription"))))
            for child in get(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        visit(window, 0)
        return items
    }

    /// The element that has the keyboard, as VoiceOver hears of it.
    nonisolated static func focusedElement() -> String {
        let app = AXUIElementCreateApplication(getpid())
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "none" }
        let element = focused as! AXUIElement
        var role: CFTypeRef?, name: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &name)
        if (name as? String ?? "").isEmpty { AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &name) }
        return "\(role as? String ?? "?") “\(name as? String ?? "")”"
    }

    static func runAccessibilityCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_A11Y"] != nil, !startedA11y else { return }
        startedA11y = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("a11y \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func skip(_ rule: String, _ why: String) { report("a11y SKIP \(rule): \(why)") }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            @MainActor func tree(_ place: String) async -> [AXItem] {
                let items = await Task.detached { accessibilityTree() }.value
                let roles = Dictionary(grouping: items, by: \.role).mapValues(\.count).sorted { $0.key < $1.key }
                report("a11y: \(place): \(items.count) elements: \(roles.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
                return items
            }

            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard AXIsProcessTrusted() else {
                report("a11y: this app may not use the Accessibility API here (System Settings › Privacy & Security › Accessibility)")
                finishAccessibility(failures + 1)
                return
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
                report("a11y: no window"); finishAccessibility(failures + 1); return
            }
            borrowDefaults(["autoplay", "audioCacheMB", "shuffle"])
            UserDefaults.standard.set(false, forKey: "autoplay")
            UserDefaults.standard.removeObject(forKey: "audioCacheMB")
            if !player.isMuted { player.toggleMute() }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))

            // five made-up songs: a minute of silence each, in the audio cache, so the player really plays them
            let songs = (1...5).map { n in
                Track(best: Listing(source: "jiosaavn", id: "selftest-a11y-\(n)", title: "Made-Up Song \(n)", artists: ["Self-test"],
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
                report("a11y: could not write the made-up songs' audio: \(error.localizedDescription)")
            }
            player.playInOrder(songs)
            let sounding = await until(8) { player.isPlaying && !player.isBuffering && player.livePosition > 0.2 }
            try? await Task.sleep(for: .seconds(2))

            let buttons: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
            // the system's own parts: a scroll bar's arrows, the window's traffic lights (named by their role)
            let systems: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage", "AXCloseButton",
                                        "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
            @MainActor func checkButtons(_ place: String, _ items: [AXItem]) {
                let ours = items.filter { buttons.contains($0.role) && !systems.contains($0.subrole) }
                let nameless = ours.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                check("\(place): every button has a name (\(ours.count) buttons)", !ours.isEmpty && nameless.isEmpty,
                      nameless.map(\.line).joined(separator: "; "))
            }
            @MainActor func checkValues(_ place: String, _ items: [AXItem]) {
                let time = items.first { $0.name == "Progress" }
                check("\(place): the time line is a slider, “Progress”, said “m:ss of m:ss”",
                      time?.role == "AXSlider" && time?.said.range(of: #"^\d+:\d\d of \d+:\d\d$"#, options: .regularExpression) != nil,
                      time?.line ?? "no “Progress”")
                let volume = items.first { $0.name == "Volume" }
                check("\(place): the volume is said as a percentage", volume?.said.range(of: #"^\d+%$"#, options: .regularExpression) != nil,
                      volume?.line ?? "no “Volume”")
            }

            // A. Home, a song playing
            let home = await tree("Home")
            for item in home { report("a11y home: \(item.line)") }
            checkButtons("Home", home)
            checkValues("Home", home)
            let song = home.first { $0.name.hasPrefix("Now playing:") }
            check("the player bar's song is one button named “Now playing: title, artists”",
                  song?.role == "AXButton" && song?.name == "Now playing: \(songs[0].title), \(songs[0].artistLine)", song?.line ?? "none")
            if sounding {
                let before = player.livePosition
                let said = await tree("Home again").first { $0.name == "Progress" }?.said ?? ""
                let after = player.livePosition
                let seconds = said.split(separator: " ").first.map { part -> Double in
                    let bits = part.split(separator: ":").compactMap { Double($0) }
                    return bits.count == 2 ? bits[0] * 60 + bits[1] : -100
                } ?? -100
                check("the time line says the time now, not when it was last drawn", seconds >= before.rounded(.down) - 1 && seconds <= after + 1,
                      String(format: "said “%@”, the song between %.1f and %.1f s", said, before, after))
            } else {
                skip("the time line's time", "the silent song did not start on this Mac")
            }
            check("Home's section titles are headings", home.contains { $0.role == "AXHeading" && $0.name == "Your Library" },
                  home.filter { $0.role == "AXHeading" }.map(\.line).joined(separator: "; "))
            let seeAll = home.filter { $0.name.hasPrefix("See All") }.map(\.name)
            check("each “See All” says what it opens", !seeAll.isEmpty && Set(seeAll).count == seeAll.count && !seeAll.contains("See All"),
                  seeAll.joined(separator: ", "))
            windowShot("a11y-home")

            // B. an album's page: its rows read their numbers (needs a server that finds one: the internet)
            if await onOwnTestServer(), let album = (try? await API.searchAlbums("abbey road"))?.first {
                Navigator.shared.open(.album(album.best))
                _ = await until(15) { frames["album.page"] != nil }
                try? await Task.sleep(for: .seconds(1.5))
                let page = await tree("an album")
                let rows = page.filter { $0.name.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
                for row in rows.prefix(3) { report("a11y album row: \(row.line)") }
                check("an album's rows are buttons read with their numbers (“1. Title, Artists, 3:45”)",
                      rows.first.map { $0.role == "AXButton" && $0.name.hasPrefix("1. ")
                          && $0.name.range(of: #", \d+:\d\d$"#, options: .regularExpression) != nil } == true,
                      rows.first?.line ?? "no numbered row")
                checkButtons("an album", page)
                check("the album's title is a heading", page.contains { $0.role == "AXHeading" && $0.name == album.best.title },
                      page.filter { $0.role == "AXHeading" }.map(\.line).joined(separator: "; "))
                windowShot("a11y-album")
                Navigator.shared.path = []
                try? await Task.sleep(for: .seconds(1))
            } else {
                skip("an album's rows", "no album found (no internet, or not this test's server)")
            }

            // C. Now Playing open: what is behind it is out of the tree
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.5))
            let covered = await tree("Now Playing")
            for item in covered { report("a11y now playing: \(item.line)") }
            checkButtons("Now Playing", covered)
            checkValues("Now Playing", covered)
            check("Now Playing has its Close button and its two pills",
                  ["Close", "Lyrics", "Up Next"].allSatisfy { name in covered.contains { $0.role == "AXButton" && $0.name == name } })
            check("Up Next's songs are named with their artists", covered.contains { $0.name == "\(songs[1].title), \(songs[1].artistLine)" })
            let behind = covered.filter { ["Home", "Library", "Your Library", "Jump Back In", "Friends"].contains($0.name) || $0.name.hasPrefix("Now playing:") }
            check("with Now Playing open, the sidebar, Home and the bar are out of the tree", behind.isEmpty, behind.map(\.line).joined(separator: "; "))
            windowShot("a11y-now-playing")
            player.showNowPlaying = false
            try? await Task.sleep(for: .seconds(1))

            // D. the keys: Space presses the control Tab reached (Keyboard navigation on); with nothing reached, it plays
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            func key(_ code: UInt16, _ characters: String) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
            report("a11y: keyboard navigation \(NSApp.isFullKeyboardAccessEnabled), window key \(window.isKeyWindow), "
                   + "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            if let space = key(49, " ") {
                window.makeFirstResponder(nil)
                let playing = player.isPlaying
                check("nothing has the keyboard: Space plays and pauses", player.heard(space))
                if player.isPlaying != playing { player.togglePlayPause() }        // as it was
                if NSApp.isFullKeyboardAccessEnabled {
                    var reached = "none"
                    for step in 1...8 {
                        if let tab = key(48, "\t") { window.sendEvent(tab) }
                        try? await Task.sleep(for: .milliseconds(300))
                        reached = await Task.detached { focusedElement() }.value
                        report("a11y: Tab \(step): first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), "
                               + "VoiceOver's focus \(reached)")
                        if reached.hasPrefix("AXButton") { break }
                    }
                    if reached.hasPrefix("AXButton") {
                        check("a button has the keyboard: Space is the button's, not play and pause", !player.heard(space), reached)
                    } else {
                        skip("Space on a button", "Tab reached no button (\(reached))")
                    }
                } else {
                    skip("Space on a button", "Keyboard navigation is off (-AppleKeyboardUIMode 2 turns it on)")
                }
            }

            player.stop()
            for song in songs { await AudioCache.shared.remove(song.best.key) }
            finishAccessibility(failures)
        }
    }

    private static func finishAccessibility(_ failures: Int) {
        returnDefaults()
        report("a11y: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
        NSApp.terminate(nil)
    }
}
#endif
