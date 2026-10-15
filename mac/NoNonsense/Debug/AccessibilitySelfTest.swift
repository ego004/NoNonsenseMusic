#if DEBUG
import AppKit
import ApplicationServices

/// With `NN_SELFTEST_A11Y=1` (and NN_SELFTEST_VISIBLE=1 with NN_SELFTEST_SNAP=<folder> for the pictures): what VoiceOver
/// is given, read from the window's own accessibility tree (#32). Five made-up songs (a minute of silence each, in the
/// audio cache) load and play, muted; then the tree is walked on Home and with Now Playing open: every button has a
/// name, the time line and the volume say their values, the player bar names the song, and nothing behind Now Playing
/// is in the tree while it is open.
extension SelfTest {
    private static var startedA11y = false

    /// One element of the tree as VoiceOver reads it: its role, its name (label, else title), its value and how the
    /// value is said, and what kind of object gave it.
    struct AXItem {
        let role: String, label: String, value: String, said: String, kind: String
        var name: String { label }
        var line: String { "\(role) “\(label)” \(value.isEmpty ? "" : "value “\(value)” ")\(said.isEmpty ? "" : "said “\(said)” ")[\(kind)]" }
    }

    /// The window's accessibility tree, walked down from the window through every element's children (ignored
    /// views included: their children are what VoiceOver sees). Only elements are kept.
    static func accessibilityItems(of window: NSWindow) -> (items: [AXItem], foreign: [String: Int]) {
        var items: [AXItem] = [], foreign: [String: Int] = [:]
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, _ depth: Int) {
            let object = element as AnyObject
            guard depth < 80, items.count < 5000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            guard let node = element as? NSAccessibilityProtocol else {
                foreign[String(describing: type(of: object)), default: 0] += 1
                return
            }
            if node.isAccessibilityElement() {
                let label = [node.accessibilityLabel(), node.accessibilityTitle()].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                items.append(AXItem(role: node.accessibilityRole()?.rawValue ?? "", label: label,
                                    value: node.accessibilityValue().map { "\($0)" } ?? "", said: node.accessibilityValueDescription() ?? "",
                                    kind: String(describing: type(of: object))))
            }
            for child in node.accessibilityChildren() ?? [] { visit(child, depth + 1) }
        }
        visit(window, 0)
        return (items, foreign)
    }

    /// The same question asked through the Accessibility API, as VoiceOver asks it (from another thread: the answer
    /// comes from this app's main thread). Says whether this process may ask at all.
    nonisolated static func accessibilityAPIReading() -> String {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        var windows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        return "trusted \(AXIsProcessTrusted()), windows: AXError \(error.rawValue), \((windows as? [AnyObject])?.count ?? -1) windows"
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
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }

            for _ in 0..<60 where !(await API.health()) { try? await Task.sleep(for: .milliseconds(500)) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let root = window.contentView?.superview else { report("a11y: no window"); finishAccessibility(failures); return }
            borrowDefaults(["autoplay", "audioCacheMB", "shuffle"])
            UserDefaults.standard.set(false, forKey: "autoplay")
            UserDefaults.standard.removeObject(forKey: "audioCacheMB")
            if !player.isMuted { player.toggleMute() }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))

            // five made-up songs: a minute of silence each, in the audio cache, so the player really plays
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
            _ = await until(6) { player.isPlaying && !player.isBuffering && player.livePosition > 0.2 }
            try? await Task.sleep(for: .seconds(2))

            // how the tree is reached: from inside (the window's own elements), and through the Accessibility API
            report("a11y: full keyboard access \(NSApp.isFullKeyboardAccessEnabled), VoiceOver \(NSWorkspace.shared.isVoiceOverEnabled)")
            let api = await Task.detached { accessibilityAPIReading() }.value
            report("a11y: the Accessibility API: \(api)")
            var walk = accessibilityItems(of: window)
            for attempt in 1...5 where walk.items.count < 20 {
                report("a11y: walk \(attempt): \(walk.items.count) elements; not elements: \(walk.foreign)")
                try? await Task.sleep(for: .seconds(1))
                walk = accessibilityItems(of: window)
            }
            let hosts = descendants(of: root).filter { String(describing: type(of: $0)).contains("Hosting") }
            report("a11y: \(walk.items.count) elements; hosting views \(hosts.map { "\(type(of: $0)): \($0.accessibilityChildren()?.count ?? -1) children" })")
            let roles = Dictionary(grouping: walk.items, by: \.role).mapValues(\.count).sorted { $0.key < $1.key }
            report("a11y: roles \(roles.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            for item in walk.items.prefix(400) { report("a11y tree: \(item.line)") }

            let buttons: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
            @MainActor func checkTree(_ place: String, _ items: [AXItem]) {
                let nameless = items.filter { buttons.contains($0.role) && $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                check("\(place): every button has a name (\(items.filter { buttons.contains($0.role) }.count) buttons)",
                      !items.isEmpty && nameless.isEmpty, nameless.map(\.line).joined(separator: "; "))
                let time = items.first { $0.label == "Progress" }
                let said = [time?.said, time?.value].compactMap { $0 }.first { $0.range(of: #"^\d+:\d\d of \d+:\d\d$"#, options: .regularExpression) != nil }
                check("\(place): the time line is “Progress”, valued “m:ss of m:ss”", said != nil, time?.line ?? "no “Progress”")
                let volume = items.first { $0.label == "Volume" }
                let percent = [volume?.said, volume?.value].compactMap { $0 }.first { $0.hasSuffix("%") }
                check("\(place): the volume says a percentage", percent != nil, volume?.line ?? "no “Volume”")
            }
            checkTree("Home", walk.items)
            let song = walk.items.first { $0.label.hasPrefix("Now playing") }
            check("the player bar names the song playing", song?.label.contains(songs[0].title) == true, song?.line ?? "no “Now playing…”")
            check("the timeline's value is now, not when it was last drawn",
                  walk.items.first { $0.label == "Progress" }.map { $0.said.hasPrefix(formatTime(player.livePosition)) || $0.value.hasPrefix(formatTime(player.livePosition)) } == true)
            windowShot("a11y-home")

            // Now Playing open: what is behind it is out of the tree
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.5))
            let covered = accessibilityItems(of: window).items
            for item in covered.prefix(200) { report("a11y now playing: \(item.line)") }
            checkTree("Now Playing", covered)
            let behind = covered.filter { ["Home", "Library", "Your Library", "Jump Back In"].contains($0.label) || $0.label.hasPrefix("Now playing") }
            check("with Now Playing open, Home, the sidebar and the bar are out of the tree", !covered.isEmpty && behind.isEmpty,
                  behind.map(\.line).joined(separator: "; "))
            windowShot("a11y-now-playing")
            player.showNowPlaying = false
            try? await Task.sleep(for: .seconds(0.5))

            // the keys: Space on nothing focused plays or pauses (the key monitor's decision)
            report("a11y: first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            for step in 1...6 {
                window.selectNextKeyView(nil)
                report("a11y: Tab \(step): first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
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
