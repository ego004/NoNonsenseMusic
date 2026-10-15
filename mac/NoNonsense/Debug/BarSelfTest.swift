#if DEBUG
import AppKit
import SwiftUI

/// With `NN_SELFTEST_BAR2=1`: the player bar, Now Playing and the lyrics' face as redesigned (15 Oct, as in the Windows
/// app), on made-up songs that cannot play (no search, no internet: the test server only says they cannot). The bar from
/// 720 to 960 pt wide: nothing overflows, its buttons keep their order, the volume goes only after Lyrics, all five fit
/// at 940, and there is no "…" among them. Now Playing alone, with Lyrics and with Up Next: the song (and the panel)
/// centred in the window within 1 pt, the panel exactly as tall as the song, "NOW PLAYING" centred on the window, the
/// pills switching the panel and hiding it. The timed lyrics in Figtree ExtraBold 24, each line as tall as CoreText
/// measures it, a noted line in the accent. The cover at 86% while paused, springing to full size to play. With
/// NN_SELFTEST_VISIBLE=1 and NN_SELFTEST_SNAP=<folder>: pictures of the bar at 1180 and 900 pt and of Now Playing with
/// each panel. Your settings are borrowed and put back.
extension SelfTest {
    private static var startedBar2 = false

    static func runBar2CheckIfAsked(player: Player, lyrics: LyricsStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_BAR2"] != nil, !startedBar2 else { return }
        startedBar2 = true
        Task {
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("bar2 \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let root = window.contentView?.superview else {
                report("bar2: no window"); NSApp.terminate(nil); return
            }
            let saved = window.frame
            @MainActor func finish() {
                player.showNowPlaying = false
                window.setFrame(saved, display: true)
                returnDefaults()
                report("bar2: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            borrowDefaults(["nowPlayingPanel", "autoplay", "geniusNotes", "textScale"])
            UserDefaults.standard.set(NowPlayingPanel.none.rawValue, forKey: "nowPlayingPanel")
            UserDefaults.standard.set(false, forKey: "autoplay")                   // Up Next stays as made here
            UserDefaults.standard.set(true, forKey: "geniusNotes")
            UserDefaults.standard.removeObject(forKey: "textScale")               // the lyrics at 24 pt
            if !player.isMuted { player.toggleMute() }

            // made-up songs, and lyrics for the first: timed, one line long enough to wrap, one with a Genius note
            @MainActor func song(_ n: Int, _ title: String) -> Track {
                let listing = Listing(source: "jiosaavn", id: "selftest-bar2-\(n)-\(UInt32.random(in: 0 ... .max))", title: title,
                                      artists: ["Kai", "The Made-Up Band"], album: "A Made-Up Album", duration: 200, popularity: nil, image: nil)
                return Track(best: listing, listings: [listing])
            }
            let songs = [song(0, "Made-Up Song for the Player Bar"), song(1, "Second Made-Up Song"), song(2, "Third Made-Up Song")]
            let words = ["First made-up line of this song", "nothing to say about this one", "Don’t stop the made-up music",
                         "a long made-up line that goes on and on until it has to wrap onto a second row, and then a third"]
                + (4..<20).map { "made-up line \($0)" }
            let timed = Lyrics(lyricsSource: "lrclib", synced: true,
                               lines: words.enumerated().map { LyricLine(startMs: 30000 + $0.offset * 4000, text: $0.element) })
            let notes = GeniusNotes(url: nil, notes: [GeniusNote(fragment: "DONT stop the made up music", text: "A made-up note.", verified: false)],
                                    about: nil)
            lyrics.give(timed, notes: notes, for: songs[0])
            for other in songs.dropFirst() { lyrics.give(Lyrics(lyricsSource: nil, synced: false, lines: []), notes: nil, for: other) }

            // it tries, cannot, and stays the song, paused; then the others queue behind it
            player.play([songs[0]])
            for _ in 0..<150 where player.isPlaying || player.isBuffering { try? await Task.sleep(for: .milliseconds(100)) }
            for other in songs.dropFirst() { player.addToQueue(other) }
            report("bar2: song \(player.current?.title ?? "-"), \(player.isPlaying ? "playing" : "paused"), up next \(player.upNextEntries.count)")

            // ── the bar, 720 to 960 pt wide (it stops at 940): the window is the bar plus the sidebar and margins ──
            @MainActor func setWidth(_ width: CGFloat) async {
                window.setFrame(NSRect(x: saved.minX, y: saved.minY, width: width, height: saved.height), display: true)
                try? await Task.sleep(for: .seconds(0.6))
            }
            await setWidth(1000)
            guard let first = frames["bar"] else { check("the bar shows", false); finish(); return }
            var around = window.frame.width - first.width
            let shownOrder = ["bar.like", "bar.open.lyrics", "bar.open.upNext", "bar.volume", "bar.open.none"]
            let needOrder = ["bar.like", "bar.volume", "bar.open.upNext", "bar.open.lyrics", "bar.open.none"]
            let names = ["bar.like": "Like", "bar.open.lyrics": "Lyrics", "bar.open.upNext": "Up Next", "bar.volume": "Volume",
                         "bar.open.none": "Now Playing"]
            for target in stride(from: CGFloat(720), through: 960, by: 20) {
                // a control reports where it is when it appears or moves (and every one moves with the window): the ones
                // that report again are the ones there
                for name in shownOrder + ["bar.row"] { frames[name] = nil }
                await setWidth(target + around)
                if let bar = frames["bar"], bar.width < 939.5, abs(bar.width - target) > 1 {     // the sidebar moved: once more
                    around = window.frame.width - bar.width
                    for name in shownOrder + ["bar.row"] { frames[name] = nil }
                    await setWidth(target + around)
                }
                guard let bar = frames["bar"], let row = frames["bar.row"], let songPart = frames["bar.song"],
                      let centre = frames["bar.centre"] else {
                    check("bar \(Int(target)) pt: its parts report where they are", false); continue
                }
                let shown = shownOrder.filter { frames[$0].map { row.insetBy(dx: -1, dy: -1).contains($0) } ?? false }
                let label = String(format: "bar %.0f pt", bar.width)
                report("bar2: \(label): \(shown.compactMap { names[$0] }.joined(separator: ", "))")
                check("\(label): nothing overflows (the song, the controls and the buttons apart; the buttons inside the bar)",
                      songPart.maxX <= centre.minX + 0.5 && row.minX >= centre.maxX - 0.5 && row.maxX <= bar.maxX - 8,
                      String(format: "song ends %.0f, centre %.0f…%.0f, buttons %.0f…%.0f, bar ends %.0f",
                             songPart.maxX, centre.minX, centre.maxX, row.minX, row.maxX, bar.maxX))
                check("\(label): the volume goes only after Lyrics", shown.contains("bar.volume") || !shown.contains("bar.open.lyrics"))
                check("\(label): the ones kept are the most needed (Like, the volume, Up Next, Lyrics, Now Playing)",
                      Set(shown) == Set(needOrder.prefix(shown.count)))
                let lefts = shown.compactMap { frames[$0]?.minX }
                check("\(label): in the order Like, Lyrics, Up Next, the volume, Now Playing", lefts == lefts.sorted())
                // the row holds these and nothing else: no "…" (the song's menu is its right-click now)
                let filled = shown.compactMap { frames[$0]?.width }.reduce(0, +) + 14 * CGFloat(max(0, shown.count - 1))
                check("\(label): the row holds only these (no \"…\")", abs(filled - row.width) <= 1,
                      String(format: "%.1f pt of controls in a %.1f pt row", filled, row.width))
                if bar.width >= 939.5 { check("\(label): all five are there", shown.count == 5, "\(shown.count)") }
            }
            check("the bar stops growing at 940 pt", (frames["bar"]?.width ?? 0) <= 940.5, "\(frames["bar"]?.width ?? 0)")
            await setWidth(1180)
            windowShot("bar-1180")
            await setWidth(900)
            windowShot("bar-900")

            // ── Now Playing ──
            await setWidth(1180)
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(1.2))
            check("a pill switches its panel on, another on, and off when pressed again (the rule)",
                  NowPlayingPanel.none.toggling(.lyrics) == .lyrics && NowPlayingPanel.lyrics.toggling(.upNext) == .upNext
                  && NowPlayingPanel.upNext.toggling(.upNext) == NowPlayingPanel.none)

            /// Measures Now Playing with the panel it shows now: the group centred, the panel as tall as the song.
            @MainActor func measure(_ expected: NowPlayingPanel) {
                let chosen = UserDefaults.standard.string(forKey: "nowPlayingPanel") ?? ""
                let name = expected == .none ? "alone" : expected == .lyrics ? "with Lyrics" : "with Up Next"
                check("\(name): the panel chosen is \(expected.rawValue)", chosen == expected.rawValue, chosen)
                guard let area = frames["nowPlaying.area"], let column = frames["nowPlaying.column"],
                      let title = frames["nowPlaying.title"], let content = window.contentView else {
                    check("\(name): Now Playing's parts report where they are", false); return
                }
                // the side panel holds both Up Next and the lyrics' lines (an AppKit view): there while it shows. Its
                // frame stays recorded after it goes, so that is read only while it shows
                let showing = descendants(of: root).contains { $0 is LyricLinesView }
                check("\(name): a panel shows exactly when one is chosen", showing == (expected != .none))
                let panel = expected == .none ? nil : frames["nowPlaying.panel"]
                let right = panel?.maxX ?? column.maxX
                check("\(name): the song\(panel == nil ? "" : " and the panel") centred across the window (within 1 pt)",
                      abs((column.minX + right) / 2 - area.midX) <= 1, String(format: "off by %.1f", (column.minX + right) / 2 - area.midX))
                check("\(name): … and down it (within 1 pt)", abs(column.midY - area.midY) <= 1,
                      String(format: "off by %.1f", column.midY - area.midY))
                if let panel {
                    check("\(name): the panel is exactly as tall as the song (top and bottom within 1 pt)",
                          abs(panel.minY - column.minY) <= 1 && abs(panel.maxY - column.maxY) <= 1,
                          String(format: "panel %.0f…%.0f, song %.0f…%.0f", panel.minY, panel.maxY, column.minY, column.maxY))
                    check("\(name): the panel is 380 pt wide, 56 pt from the song",
                          abs(panel.width - 380) <= 0.5 && abs(panel.minX - column.maxX - 56) <= 0.5,
                          String(format: "%.1f wide, %.1f from the song", panel.width, panel.minX - column.maxX))
                }
                check("\(name): NOW PLAYING is centred on the window (within 1 pt)", abs(title.midX - content.bounds.midX) <= 1,
                      String(format: "off by %.1f", title.midX - content.bounds.midX))
                report(String(format: "bar2: %@: the song %.0f × %.0f pt in a %.0f × %.0f pt area", name,
                              column.width, column.height, area.width, area.height))
            }

            /// Presses a pill: a click when one can reach it (the window key), else what the pill does.
            @MainActor func press(_ which: NowPlayingPanel) async {
                let before = UserDefaults.standard.string(forKey: "nowPlayingPanel") ?? ""
                if let pill = frames["nowPlaying.pill.\(which.rawValue)"], let content = window.contentView, window.isKeyWindow {
                    let p = NSPoint(x: pill.midX, y: content.frame.height - pill.midY)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .seconds(0.3))
                }
                if UserDefaults.standard.string(forKey: "nowPlayingPanel") == before {
                    report("bar2: no click reached the \(which.rawValue) pill (the window is not key): doing what it does")
                    let now = NowPlayingPanel(rawValue: before) ?? .upNext
                    UserDefaults.standard.set(now.toggling(which).rawValue, forKey: "nowPlayingPanel")
                }
                try? await Task.sleep(for: .seconds(1))                  // the panel's 0.42 s, and room to settle
            }

            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            measure(.none)
            windowShot("nowplaying-none")
            await press(.lyrics)
            measure(.lyrics)
            windowShot("nowplaying-lyrics")

            // the timed lines (Lyrics shows): Figtree ExtraBold at 24 pt, tracked -0.6, each layer as tall as CoreText
            // measures its text, the noted line in the accent
            check("Figtree ExtraBold is registered for the app", NSFont(name: LyricsFont.name, size: 24) != nil)
            if let view = descendants(of: root).compactMap({ $0 as? LyricLinesView }).first, let top = view.layer {
                func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
                let texts = layers(top).compactMap { $0 as? CATextLayer }
                let strings = texts.map { $0.string as? NSAttributedString }
                let drawn = zip(texts, strings).compactMap { layer, text in text.map { (layer, $0) } }
                let fonts = drawn.compactMap { $0.1.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }
                let face = fonts.first.map { "\($0.fontName) \($0.pointSize)" } ?? "-"
                report("bar2: \(texts.count) lyric lines, \(drawn.count) drawn so far; first font \(face)")
                check("the timed lines are drawn in Figtree ExtraBold 24", !drawn.isEmpty && fonts.count == drawn.count
                      && fonts.allSatisfy { $0.fontName == LyricsFont.name && $0.pointSize == 24 })
                check("… tracked -0.6", drawn.allSatisfy { ($0.1.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue == -0.6 })
                let measured = drawn.map { layer, text in
                    let room = CGSize(width: layer.bounds.width, height: .greatestFiniteMagnitude)
                    return ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text), CFRange(), nil,
                                                                             room, nil).height) + 2
                }
                check("each line's layer is as tall as CoreText measures its text in that face",
                      zip(drawn, measured).allSatisfy { abs($0.0.bounds.height - $1) < 0.5 })
                if strings.count > 4, let noted = strings[2], let plain = strings[4], let wrapped = strings[3] {
                    let row = texts[4].bounds.height
                    check("a one-row line is the face's own 1.2 × 24 high (+2)", abs(row - (24 * 1.2 + 2)) <= 1.2, String(format: "%.1f pt", row))
                    check("the long line wraps, and its layer holds every row", texts[3].bounds.height >= 2 * 24 * 1.2 && !wrapped.string.isEmpty,
                          String(format: "%.1f pt", texts[3].bounds.height))
                    let colour = { (text: NSAttributedString) in text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
                    let underlined = noted.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil
                    check("the line with a Genius note is in another colour (the accent), not underlined",
                          colour(noted) != nil && colour(noted) != colour(plain) && !underlined)
                    check("… and unlit it fades less (0.6 against 0.38)", abs(texts[2].opacity - 0.6) < 0.01 && abs(texts[4].opacity - 0.38) < 0.01,
                          String(format: "%.2f and %.2f", texts[2].opacity, texts[4].opacity))
                } else {
                    check("the first five lines are drawn", false, "\(drawn.count) drawn")
                }
            } else {
                check("Lyrics shows its timed lines", false)
            }

            await press(.upNext)
            measure(.upNext)
            windowShot("nowplaying-upNext")
            await press(.upNext)
            measure(.none)

            // ── the cover: 86% while paused, full size while the song plays or loads, sprung between ──
            if let cover = descendants(of: root).compactMap({ $0 as? LiveArtworkView }).first(where: { $0.bounds.width > 100 }) {
                let paused = cover.restState
                check("paused: the cover rests at 86%, with the closer shadow", abs(paused.scale - 0.86) < 0.001 && paused.shadowRadius == 9,
                      String(format: "%.3f, shadow %.0f", paused.scale, paused.shadowRadius))
                player.togglePlayPause()                                // tries again: it loads (playing) until it gives up
                var seen = false, full = false
                for _ in 0..<50 where !full {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard player.isPlaying || player.isBuffering else { continue }
                    seen = true
                    let state = cover.restState
                    full = abs(state.scale - 1) < 0.001 && state.shadowRadius == 16 && state.springing
                }
                if seen {
                    check("playing (or loading): the cover springs to full size, with the deeper shadow", full)
                } else {
                    report("bar2 SKIP the spring to full size: the made-up song gave up before it could be seen loading")
                }
                for _ in 0..<150 where player.isPlaying || player.isBuffering { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1.5))
                let settled = cover.restState
                check("paused again: back at 86%, and the spring is over (nothing keeps moving)",
                      abs(settled.scale - 0.86) < 0.001 && !settled.springing, String(format: "%.3f", settled.scale))
            } else {
                check("Now Playing's cover is there", false)
            }
            finish()
        }
    }
}
#endif
