#if DEBUG
import AppKit
import Translation

/// With `NN_SELFTEST_TRANSLATE=1` (needs the internet): a Spanish song's lyrics offer Translate; on, the panel shows
/// each line's translation, made on this Mac. Reports whether the language pack was already installed: without it,
/// macOS asks to download it, which a test cannot answer.
extension SelfTest {
    private static var startedTranslate = false

    static func runTranslateCheckIfAsked(player: Player, lyrics: LyricsStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_TRANSLATE"] != nil, !startedTranslate else { return }
        startedTranslate = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("translate \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            if !player.isMuted { player.toggleMute() }
            let target = LyricsTranslations.target(UserDefaults.standard.string(forKey: "translateInto") ?? "")   // Settings › Lyrics › Translate into
            let pack = await LanguageAvailability().status(from: Locale.Language(identifier: "es"), to: target)
            report("translate: Spanish → \(target.languageCode?.identifier ?? "?") pack: \(pack == .installed ? "installed" : pack == .supported ? "supported, not downloaded" : "unsupported")")
            let saved = UserDefaults.standard.object(forKey: "lyricsTranslated")
            UserDefaults.standard.set(false, forKey: "lyricsTranslated")
            UserDefaults.standard.set("lyrics", forKey: "nowPlayingPanel")
            let query = ProcessInfo.processInfo.environment["NN_TRANSLATE_QUERY"] ?? "despacito luis fonsi"
            guard let song = (try? await API.search(query))?.songs.first.map(Track.init) else {
                check("a Spanish song", false); NSApp.terminate(nil); return
            }
            player.play([song])
            player.showNowPlaying = true
            if ProcessInfo.processInfo.environment["NN_LYRICS_LAYOUT"] != nil {
                try? await Task.sleep(for: .seconds(8))
                func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
                let all = NSApp.windows.compactMap(\.contentView).flatMap(views)
                if let lines = all.first(where: { $0 is LyricLinesView }), let layer = lines.layer {
                    report("lyrics layout: view \(lines.bounds.size), in window \(lines.convert(lines.bounds, to: nil).integral), panel \(frames["lyrics.panel"]?.integral ?? .zero)")
                    let scale: CGFloat = 2
                    let size = lines.bounds.size
                    if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: scale, y: scale)
                        layer.render(in: ctx)
                        if let image = ctx.makeImage() {
                            let url = URL(filePath: (ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"] ?? NSTemporaryDirectory()) + "/lyrics-layers.png")
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                            report("lyrics layout: wrote \(url.path)")
                        }
                    }
                }
                NSApp.terminate(nil); return
            }
            check("Spanish lyrics offer Translate", await until(20) { frames["lyrics.translate"] != nil })
            if case .found(let found)? = lyrics.state(for: song) {
                check("a line carrying the uploader's translation shows the original only", !found.lines.contains { $0.text.contains("^") })
                let language = LyricsTranslations.language(of: found.lines.map(\.text))
                if query.contains("despacito") { check("…and the lyrics read as Spanish", language?.languageCode?.identifier == "es",
                      language?.minimalIdentifier ?? "none") }
            }
            UserDefaults.standard.set(true, forKey: "lyricsTranslated")
            if pack == .installed {
                check("…and show each line's translation", await until(20) {
                    frames["lyrics.translation"] != nil
                }, LyricsTranslations.shared.failed.isEmpty ? "still translating" : "failed")
                let first = LyricsTranslations.shared.lines[.init(song: song.id, target: target)]?.first { !$0.isEmpty } ?? "-"
                report("translate: first translated line: \(first)")
            }
            UserDefaults.standard.set(saved, forKey: "lyricsTranslated")
            report("translate: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}

/// With `NN_SELFTEST_TRANSLATEINTO=1` (and NN_SELFTEST_VISIBLE=1 with NN_SELFTEST_SNAP=<folder> for pictures): Settings ›
/// Lyrics › Translate into (#19), with made-up songs. Without the internet: the setting's language, the languages offered
/// (each one Apple's framework translates), Google's codes, the uploader's translation used only in the chosen language,
/// the Settings menu, and Now Playing's translation following the setting, kept per song and language. With it, and
/// with Apple's framework not translating Punjabi: a Punjabi song goes to Google in the chosen language, credited, and is
/// translated again when the language changes; the first language back shows without asking.
extension SelfTest {
    private static var startedTranslateInto = false

    static func runTranslateIntoCheckIfAsked(player: Player, lyrics: LyricsStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_TRANSLATEINTO"] != nil, !startedTranslateInto else { return }
        startedTranslateInto = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("translateinto \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func skip(_ rule: String, _ why: String) { report("translateinto SKIP \(rule): \(why)") }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            /// Whether `lines` hold a letter in `range` (a script's block of Unicode).
            func written(_ lines: [String]?, in range: ClosedRange<UInt32>) -> Bool {
                lines?.joined().unicodeScalars.contains { range.contains($0.value) } ?? false
            }
            func sung(_ texts: [String], translations: [String]? = nil) -> [LyricLine] {
                texts.enumerated().map { LyricLine(startMs: $0.offset * 4000 + 1000, text: $0.element, translation: translations?[$0.offset]) }
            }
            let store = LyricsTranslations.shared
            let english = Locale.Language(identifier: "en"), hindi = Locale.Language(identifier: "hi")
            let spanish = Locale.Language(identifier: "es"), punjabi = Locale.Language(identifier: "pa")
            // made-up lyrics: Spanish, an English and a Hindi translation of them, and Punjabi
            let es = ["Camino solo bajo las luces de la ciudad esta noche", "y cada calle recuerda las canciones que cantábamos",
                      "toma mi mano hasta que llegue la mañana", "éramos jóvenes y el verano nunca terminaba"]
            let en = ["I walk alone under the city lights tonight", "and every street remembers the songs we used to sing",
                      "hold my hand until the morning comes", "we were young and the summer never ended"]
            let hi = ["आज रात शहर की रोशनी में मैं अकेला चलता हूँ", "हर गली उन गानों को याद करती है जो हम गाते थे",
                      "सुबह होने तक मेरा हाथ थामे रखो", "हम जवान थे और गर्मियाँ कभी खत्म नहीं होती थीं"]
            let pa = ["ਅੱਜ ਰਾਤ ਸ਼ਹਿਰ ਦੀਆਂ ਰੌਸ਼ਨੀਆਂ ਵਿੱਚ ਮੈਂ ਇਕੱਲਾ ਤੁਰਦਾ ਹਾਂ", "ਹਰ ਗਲੀ ਉਹਨਾਂ ਗੀਤਾਂ ਨੂੰ ਯਾਦ ਕਰਦੀ ਹੈ ਜੋ ਅਸੀਂ ਗਾਉਂਦੇ ਸੀ",
                      "ਸਵੇਰ ਹੋਣ ਤੱਕ ਮੇਰਾ ਹੱਥ ਫੜੀ ਰੱਖੋ", "ਅਸੀਂ ਜਵਾਨ ਸੀ ਤੇ ਗਰਮੀਆਂ ਕਦੇ ਖ਼ਤਮ ਨਹੀਂ ਹੁੰਦੀਆਂ ਸਨ"]
            try? await Task.sleep(for: .seconds(3))

            // A. the rules
            check("System language (\"\", the default) is the Mac's own; a language chosen is that one; one no longer offered is the Mac's own",
                  LyricsTranslations.target("") == Locale.current.language && LyricsTranslations.target("hi") == hindi
                      && LyricsTranslations.target("tlh") == Locale.current.language)
            let names = LyricsTranslations.choices.map(\.name), ids = LyricsTranslations.choices.map(\.id)
            check("the languages offered: in the order of their own names, each once", names == names.sorted() && Set(ids).count == ids.count,
                  names.joined(separator: ", "))
            let notGoogle = ids.filter { OnlineTranslation.code(for: Locale.Language(identifier: $0)) != $0 }
            check("each one's code is the one Google takes (the Windows app offers the same codes)", notGoogle.isEmpty, notGoogle.joined(separator: ", "))
            let codes = ["zh": "zh-CN", "zh-Hans": "zh-CN", "zh-CN": "zh-CN", "zh-Hant": "zh-TW", "zh-TW": "zh-TW", "zh-HK": "zh-TW",
                         "en-GB": "en", "pt-BR": "pt", "hi-IN": "hi"]
            let wrongCodes = codes.filter { OnlineTranslation.code(for: Locale.Language(identifier: $0.key)) != $0.value }
            check("Google's code: traditional Chinese zh-TW, simplified zh-CN, any other language alone", wrongCodes.isEmpty,
                  wrongCodes.map { "\($0.key) → \(OnlineTranslation.code(for: Locale.Language(identifier: $0.key)) ?? "nil")" }.joined(separator: ", "))
            var statuses: [String] = [], unsupported: [String] = []
            for (id, name) in LyricsTranslations.choices {
                let status = await LanguageAvailability().status(from: id == "en" ? spanish : english, to: Locale.Language(identifier: id))
                statuses.append("\(id) \(status == .installed ? "installed" : status == .supported ? "supported" : "unsupported")")
                if status == .unsupported { unsupported.append("\(name) (\(id))") }
            }
            report("translateinto: from English (Spanish for English) on this Mac: \(statuses.joined(separator: ", "))")
            check("each language offered is one Apple's framework translates", unsupported.isEmpty, unsupported.joined(separator: ", "))
            let apple = await LanguageAvailability().supportedLanguages
            report("translateinto: Apple's framework translates \(apple.count): \(apple.map(\.minimalIdentifier).sorted().joined(separator: " "))")
            check("the uploader's translation is used only in the chosen language: English into English, not into Hindi",
                  LyricsTranslations.provided(sung(es, translations: en), in: english) == en
                      && LyricsTranslations.provided(sung(es, translations: en), in: hindi) == nil)
            check("…Hindi into Hindi, not into English", LyricsTranslations.provided(sung(es, translations: hi), in: hindi) == hi
                      && LyricsTranslations.provided(sung(es, translations: hi), in: english) == nil)

            // B. Settings › Lyrics › Translate into: System language first, then the languages; the choice shows
            borrowDefaults(["translateInto", "lyricsTranslated", "nowPlayingPanel"])
            UserDefaults.standard.set("hi", forKey: "translateInto")
            if let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
                try? await Task.sleep(for: .seconds(1.5))
                if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) }) {
                    if let tab = settings.toolbar?.items.first(where: { $0.label == "Lyrics" }), let action = tab.action {
                        NSApp.sendAction(action, to: tab.target, from: tab)
                        try? await Task.sleep(for: .seconds(1.2))
                    }
                    let popUps = (settings.contentView?.superview).map { descendants(of: $0) }?.compactMap { $0 as? NSPopUpButton } ?? []
                    if let chooser = popUps.first(where: { $0.itemTitles.contains("System language") }) {
                        let titles = chooser.itemArray.filter { !$0.isSeparatorItem }.map(\.title)
                        check("Settings › Lyrics › Translate into: System language first, then the languages by their own names",
                              titles == ["System language"] + names, titles.joined(separator: ", "))
                        check("…showing the language chosen", chooser.titleOfSelectedItem == "हिन्दी", chooser.titleOfSelectedItem ?? "nothing")
                    } else {
                        check("Settings › Lyrics has the Translate into menu", false, "\(popUps.count) pop-up buttons: \(popUps.map(\.itemTitles))")
                    }
                    windowShot("translateinto-settings", of: settings)
                    settings.close()
                } else {
                    check("Settings opens", false)
                }
            }

            // C. Now Playing's translation follows the setting, kept per song and language
            UserDefaults.standard.set(NowPlayingPanel.lyrics.rawValue, forKey: "nowPlayingPanel")
            UserDefaults.standard.set(true, forKey: "lyricsTranslated")
            UserDefaults.standard.set("en", forKey: "translateInto")
            if !player.isMuted { player.toggleMute() }
            func madeUp(_ name: String, _ found: [LyricLine]) -> Track {
                let listing = Listing(source: "jiosaavn", id: "selftest-translateinto-\(name)-\(UInt32.random(in: 0 ... .max))",
                                      title: "Made-Up \(name) Song", artists: ["Kai"], album: nil, duration: 200, popularity: nil, image: nil)
                let track = Track(best: listing, listings: [listing])
                lyrics.give(Lyrics(lyricsSource: "lrclib", synced: true, lines: found), notes: nil, for: track)
                return track
            }
            func timedShown() -> Bool {
                NSApp.windows.compactMap { $0.contentView?.superview }.flatMap { descendants(of: $0) }.contains { $0 is LyricLinesView }
            }
            let first = madeUp("Spanish", sung(es, translations: en))
            let firstIn = { (target: Locale.Language) in LyricsTranslations.Key(song: first.id, target: target) }
            player.play([first])                                       // a made-up song: it cannot play, and stays the song
            player.showNowPlaying = true
            check("Spanish lyrics with the uploader's English, into English: that English, credited “Translation from the lyrics”",
                  await until(10) { lyricsShown == "translation" && store.lines[firstIn(english)] == en }
                      && store.credits[firstIn(english)] == "Translation from the lyrics",
                  "shown “\(lyricsShown)”, credit \(store.credits[firstIn(english)] ?? "none")")
            windowShot("translateinto-provided-english")
            let timedWhileTranslated = timedShown()
            lyricsShown = ""
            UserDefaults.standard.set("es", forKey: "translateInto")
            try? await Task.sleep(for: .seconds(1.5))
            check("…into Spanish, their own language: the lyrics themselves, nothing translated", !timedWhileTranslated && timedShown() && lyricsShown == "",
                  "timed lyrics \(timedWhileTranslated) → \(timedShown()), shown “\(lyricsShown)”")
            // a Hindi translation of this song kept from before (as if made earlier): shown for Hindi, without asking
            store.store(hi, for: firstIn(hindi), credit: "Translated on this Mac")
            UserDefaults.standard.set("hi", forKey: "translateInto")
            check("…into Hindi: the Hindi kept for this song, not the English", await until(3) { lyricsShown == "translation" }
                      && store.lines[firstIn(hindi)] == hi && store.lines[firstIn(english)] == en, "shown “\(lyricsShown)”")
            windowShot("translateinto-kept-hindi")

            // D. a song Apple's framework cannot translate: Google, into the language chosen
            let pairs = [await LanguageAvailability().status(from: punjabi, to: english),
                         await LanguageAvailability().status(from: punjabi, to: hindi)]
            if pairs.contains(where: { $0 != .unsupported }) {
                skip("Google for a song this Mac cannot translate", "Apple's framework translates Punjabi here")
            } else {
                UserDefaults.standard.set("en", forKey: "translateInto")
                let second = madeUp("Punjabi", sung(pa))
                let inEnglish = LyricsTranslations.Key(song: second.id, target: english)
                let inHindi = LyricsTranslations.Key(song: second.id, target: hindi)
                player.play([second])
                _ = await until(20) { store.lines[inEnglish] != nil || store.failed.contains(inEnglish) }
                let read = store.foreignLanguage(of: second.id, lines: sung(pa), to: english)
                check("Punjabi lyrics read as Punjabi", read?.languageCode == punjabi.languageCode, read?.minimalIdentifier ?? "unclear")
                if let answered = store.lines[inEnglish] {
                    report("translateinto: Google, into English: “\(answered.first ?? "")”")
                    check("…into English: Google's English, credited “Translated by Google”",
                          written(answered, in: 0x61...0x7A) && !written(answered, in: 0x0A00...0x0A7F) && store.credits[inEnglish] == "Translated by Google",
                          store.credits[inEnglish] ?? "no credit")
                    windowShot("translateinto-google-english")
                    UserDefaults.standard.set("hi", forKey: "translateInto")
                    _ = await until(20) { store.lines[inHindi] != nil || store.failed.contains(inHindi) }
                    report("translateinto: Google, into Hindi: “\(store.lines[inHindi]?.first ?? (store.failed.contains(inHindi) ? "failed" : "nothing"))”")
                    check("…Hindi chosen: translated again, into Devanagari, credited",
                          written(store.lines[inHindi], in: 0x0900...0x097F) && store.credits[inHindi] == "Translated by Google")
                    check("…the English kept", store.lines[inEnglish] == answered)
                    windowShot("translateinto-google-hindi")
                    lyricsShown = ""
                    UserDefaults.standard.set("en", forKey: "translateInto")
                    try? await Task.sleep(for: .milliseconds(600))
                    check("…English chosen again: shown at once from what was kept, not asked again",
                          lyricsShown == "translation" && store.lines[inEnglish] == answered, "shown “\(lyricsShown)”")
                } else {
                    skip("Google's translation", "Google did not answer this Mac")
                    UserDefaults.standard.set("hi", forKey: "translateInto")
                    check("…Hindi chosen: asked again, for Hindi", await until(20) { store.lines[inHindi] != nil || store.failed.contains(inHindi) })
                }
            }

            player.showNowPlaying = false
            returnDefaults()
            report("translateinto: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
