#if DEBUG
import AppKit
import SwiftUI

/// With `NN_SELFTEST_READABLE=1` (no internet: the covers are made up; with NN_SELFTEST_VISIBLE=1 and
/// NN_SELFTEST_SNAP=<folder>, window pictures): Now Playing's text reads on its backdrop whatever the cover (#20).
/// Made-up covers, very bright, very dark, half and half, a checkerboard, vivid and pale, in light and dark mode, at
/// colour strengths from 0 to 1: each backdrop is drawn as Now Playing draws it, still and at five more moments of its
/// drift, and every pixel, over the window's colour, is measured against every kind of text (4.5:1 for text, 3:1 for the
/// large lyrics and symbols) and the accent's text (the song's own accent and three chosen ones). The same backdrops
/// with the text as it was before #20 are measured for the record. Then Now Playing itself, with four of the covers,
/// light and dark, at the lowest and highest colour strength: what its backdrop tells the text is checked, and
/// pictured. Your settings are borrowed and put back.
extension SelfTest {
    private static var startedReadable = false

    static func runReadableCheckIfAsked(player: Player, lyrics: LyricsStore, theme: ThemeStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_READABLE"] != nil, !startedReadable else { return }
        startedReadable = true
        Task {
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("readable \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            func ratio(_ value: Double) -> String { String(format: "%.2f:1", value) }

            // ── the made-up covers, 3 × 3 blocks (one per colour the backdrop takes) or two halves ──
            let covers: [(name: String, blocks: [UInt32])] = [
                ("white", Array(repeating: 0xFFFFFF, count: 9)),
                ("yellow", Array(repeating: 0xFFE14D, count: 9)),
                ("neon green", Array(repeating: 0x00FF66, count: 9)),
                ("black", Array(repeating: 0x000000, count: 9)),
                ("navy", Array(repeating: 0x0A1236, count: 9)),
                ("grey", Array(repeating: 0x808080, count: 9)),
                ("half white, half black", [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000]),
                ("checkerboard", [0xFFFFFF, 0x000000, 0xFFFFFF, 0x000000, 0xFFFFFF, 0x000000, 0xFFFFFF, 0x000000, 0xFFFFFF]),
                ("vivid", [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF, 0xFF8000, 0x8000FF, 0x80FF00]),
                ("pastel", [0xF6D8E4, 0xD8EEF6, 0xF6F0D8, 0xE4D8F6, 0xFFFFFF, 0xD8F6E0, 0xF6E0D8, 0xD8E4F6, 0xF0F6D8]),
            ]
            @MainActor func image(_ blocks: [UInt32]) -> NSImage? {
                let side = 300
                guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                for (i, hex) in blocks.enumerated() {
                    context.setFillColor(CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                                                 blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
                    // row by row from the top (Core Graphics counts y from the bottom)
                    context.fill(CGRect(x: i % 3 * 100, y: side - (i / 3 + 1) * 100, width: 100, height: 100))
                }
                return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
            }
            var grids: [String: [Color]] = [:]
            var urls: [String: URL] = [:]
            for cover in covers {
                let url = URL(string: "https://selftest.invalid/readable/\(cover.name.replacingOccurrences(of: " ", with: "-")).png")!
                guard let made = image(cover.blocks) else { check("\(cover.name): the made-up cover is drawn", false); continue }
                ArtworkCache.shared.keepForSelfTest(made, for: url)
                urls[cover.name] = url
                grids[cover.name] = await ArtworkCache.shared.colorGrid(for: url)
                check("\(cover.name): its nine colours, from the made-up cover (no network)", grids[cover.name]?.count == 9)
            }

            /// Every pixel of a backdrop picture as it shows over the window's colour.
            @MainActor func pixels(_ picture: CGImage?, over window: RGB) -> [RGB] {
                guard let picture else { return [] }
                let (width, height) = (picture.width, picture.height)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }
                guard drawn else { return [] }
                return stride(from: 0, to: bytes.count, by: 4).map { i in
                    let alpha = Double(bytes[i + 3]) / 255           // premultiplied: the colour is already × alpha
                    return RGB(r: Double(bytes[i]) / 255 + (1 - alpha) * window.r, g: Double(bytes[i + 1]) / 255 + (1 - alpha) * window.g,
                               b: Double(bytes[i + 2]) / 255 + (1 - alpha) * window.b)
                }
            }

            // ── every cover, light and dark, every strength: still and moving, every pixel, every kind of text ──
            let strengths: [Double] = [0, 0.3, 0.7, Look.nowPlayingColour, 1]
            let moments: [Double] = [0, 4, 9, 15, 22, 31]                    // seconds into the drift (0: the still backdrop)
            let size = CGSize(width: 40, height: 25)                 // the mesh is smooth: 13 × 8 samples per patch
            let accents: [(name: String, colour: Color?)] = [("blue", Color(hex: "#0A84FF")), ("yellow", Color(hex: "#FFD60A")),
                                                             ("near black", Color(hex: "#1C1C1E"))]
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                let ground = NowPlayingInk.Ground(dark: dark)
                var environment = EnvironmentValues()
                environment.colorScheme = dark ? .dark : .light
                let (label, labelAlpha) = NowPlayingInk.Ground.resolved(.labelColor, dark: dark)
                let window = ground.window
                report(String(format: "readable: %@ mode: window %.3f %.3f %.3f, text %.0f%% of %.0f %.0f %.0f", mode, window.r, window.g, window.b,
                              labelAlpha * 100, label.r * 255, label.g * 255, label.b * 255))
                // the text as it was before #20: the system's secondary text, unlit lyrics at 38% of the label
                let before = [NowPlayingInk.Role(name: "text", colour: label, alpha: labelAlpha, target: NowPlayingInk.text),
                              NowPlayingInk.Role(name: "secondary text", colour: label,
                                                 alpha: NowPlayingInk.Ground.resolved(.secondaryLabelColor, dark: dark).alpha, target: NowPlayingInk.text),
                              NowPlayingInk.Role(name: "unlit lyrics", colour: label, alpha: labelAlpha * 0.38, target: NowPlayingInk.large)]
                for cover in covers {
                    guard let grid = grids[cover.name], let url = urls[cover.name] else { continue }
                    let song = await ArtworkCache.shared.accent(for: url, dark: dark)
                    for strength in strengths {
                        let at = "\(cover.name), \(mode), strength \(strength)"
                        let colours = Backdrop.colours(of: grid, dark: dark, strength: strength, readable: true)
                        var shown: [RGB] = []
                        for moment in moments {
                            shown += pixels(Backdrop.picture(of: colours, strength: strength, at: moment, size: size), over: window)
                        }
                        guard !shown.isEmpty else { check("\(at): the backdrop is drawn", false); continue }
                        let worst = ground.roles.map { role in (role, shown.map(role.contrast(on:)).min() ?? 0) }
                        report("readable: \(at): " + worst.map { "\($0.0.name) \(ratio($0.1))" }.joined(separator: ", "))
                        let low = worst.filter { $0.1 < $0.0.target }
                        check("\(at): every kind of text reads on every pixel, still and moving", low.isEmpty,
                              low.map { "\($0.0.name) \(ratio($0.1)), needs \(ratio($0.0.target))" }.joined(separator: "; "))
                        // the accent's text, made readable on the nine colours as they show
                        let behind = colours.map { $0.over(window, alpha: strength) }
                        let all: [(name: String, colour: Color?)] = [("the song's", song)] + accents
                        for accent in all {
                            let made = ground.readable(RGB((accent.colour ?? .accentColor).resolve(in: environment)), on: behind)
                            let asText = shown.map { made.contrast(with: $0) }.min() ?? 0
                            let unlit = shown.map { made.over($0, alpha: Double(LyricLinesView.unlit)).contrast(with: $0) }.min() ?? 0
                            check("\(at): the \(accent.name) accent reads, as text and as an unlit noted lyric",
                                  asText >= NowPlayingInk.text && unlit >= NowPlayingInk.large, "\(ratio(asText)), unlit \(ratio(unlit))")
                        }
                        // before #20, for the record (the default strength and the ends): not checked
                        if strength == 0 || strength == Look.nowPlayingColour || strength == 1 {
                            let old = pixels(Backdrop.picture(of: Backdrop.colours(of: grid, dark: dark, strength: strength, readable: false),
                                                              strength: strength, size: size), over: window)
                            report("readable: before #20, \(at): " + before.map { role in
                                "\(role.name) \(ratio(old.map(role.contrast(on:)).min() ?? 0))"
                            }.joined(separator: ", "))
                        }
                    }
                }
            }

            // ── Now Playing itself: what its backdrop tells the text, and pictures ──
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
                report("readable: no window"); finishReadable(failures); return
            }
            let saved = window.frame
            borrowDefaults(["appearance", "nowPlayingColour", "nowPlayingPanel", "autoplay", "geniusNotes", "animateBackdrop", "textScale",
                            "theme.background.mode", "theme.buttons.mode"])
            UserDefaults.standard.set(NowPlayingPanel.lyrics.rawValue, forKey: "nowPlayingPanel")
            UserDefaults.standard.set(false, forKey: "autoplay")
            UserDefaults.standard.set(true, forKey: "geniusNotes")
            UserDefaults.standard.set(false, forKey: "animateBackdrop")
            UserDefaults.standard.removeObject(forKey: "textScale")
            theme.setMode(.song, for: .background)
            theme.setMode(.song, for: .buttons)
            if !player.isMuted { player.toggleMute() }
            window.setFrame(NSRect(x: saved.minX, y: saved.maxY - 760, width: 1180, height: 760), display: true)
            // lyrics with a lit line (the first: it starts at 0), a noted one under it, and unlit ones
            let words = ["The first made-up line, lit", "Don’t stop the made-up music", "an unlit made-up line", "another unlit line",
                         "and one more line that is not sung yet"] + (5..<16).map { "made-up line \($0)" }
            let timed = Lyrics(lyricsSource: "lrclib", synced: true,
                               lines: words.enumerated().map { LyricLine(startMs: $0.offset * 5000, text: $0.element) })
            let notes = GeniusNotes(url: nil, notes: [GeniusNote(fragment: "DONT stop the made up music", text: "A made-up note.", verified: false)],
                                    about: nil)
            for name in ["white", "black", "half white, half black", "vivid"] {
                guard let url = urls[name], let grid = grids[name] else { continue }
                let listing = Listing(source: "jiosaavn", id: "selftest-readable-\(UInt32.random(in: 0 ... .max))", title: "Made-Up Song",
                                      artists: ["Kai", "The Made-Up Band"], album: "A Made-Up Album", duration: 200, popularity: nil, image: url.absoluteString)
                let song = Track(best: listing, listings: [listing])
                lyrics.give(timed, notes: notes, for: song)
                player.play([song])                                  // it tries, cannot (made up), and stays, paused
                for _ in 0..<150 where player.isPlaying || player.isBuffering { try? await Task.sleep(for: .milliseconds(100)) }
                for dark in [false, true] {
                    UserDefaults.standard.set(dark ? Appearance.dark.rawValue : Appearance.light.rawValue, forKey: "appearance")
                    for strength: Double in [0, 1] {
                        let at = "Now Playing, \(name), \(dark ? "dark" : "light"), strength \(strength)"
                        UserDefaults.standard.set(strength, forKey: "nowPlayingColour")
                        player.showNowPlaying = true
                        try? await Task.sleep(for: .seconds(1.5))
                        let ink = NowPlayingInk.shared
                        let ground = NowPlayingInk.Ground(dark: dark)
                        let expected = Backdrop.colours(of: grid, dark: dark, strength: strength, readable: true)
                            .map { $0.over(ground.window, alpha: strength) }
                        check("\(at): the backdrop tells the text what it draws", ink.dark == dark && ink.behind == expected,
                              "\(ink.dark ? "dark" : "light"), \(ink.behind.count) colours")
                        check("\(at): every kind of text reads on each of its colours", ink.behind.allSatisfy { ground.reads(on: $0) })
                        var environment = EnvironmentValues()
                        environment.colorScheme = dark ? .dark : .light
                        let tint = RGB(ink.readable(theme.color(.buttons), dark: dark).resolve(in: environment))
                        let tintWorst = ink.behind.map { tint.contrast(with: $0) }.min() ?? 0
                        check("\(at): the accent's text (the song's colour) reads on each of them", tintWorst >= NowPlayingInk.text,
                              ratio(tintWorst))
                        windowShot("readable-\(name.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "-"))-"
                                   + "\(dark ? "dark" : "light")-\(strength == 0 ? "lowest" : "highest")")
                    }
                }
            }
            player.showNowPlaying = false
            window.setFrame(saved, display: true)
            finishReadable(failures)
        }
    }

    private static func finishReadable(_ failures: Int) {
        returnDefaults()
        report("readable: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
        NSApp.terminate(nil)
    }
}
#endif
