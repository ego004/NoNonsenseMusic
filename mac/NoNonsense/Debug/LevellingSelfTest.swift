#if DEBUG
import AppKit

/// With `NN_SELFTEST_LEVEL=1` (no internet: tones made here, played from the audio cache): Settings › Playback › Same
/// volume for every song, and the limiter. The gain rules; the processor's gain, its glide and the limiter, offline; the
/// meter on two AAC tones 23.5 dB apart; then the player: no tap while off, the playing song measured when switched on
/// and brought to −14 LUFS, a song stored in the cache measured before it plays and started at its level, and the tap
/// gone when switched off. Muted; the settings it changes are put back.
extension SelfTest {
    private static var startedLevelling = false

    static func runLevellingCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LEVEL"] != nil, !startedLevelling else { return }
        startedLevelling = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("level \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            func near(_ value: Double, _ target: Double, _ within: Double) -> Bool { abs(value - target) <= within }
            func db(_ value: Double?) -> String { value.map { String(format: "%+.2f dB", $0) } ?? "no audio" }
            let leveller = Leveller.shared, chain = SoundChain.shared
            try? await Task.sleep(for: .seconds(2))
            borrowDefaults(["levelOn", "limiterOn", "crossfeed", "vocalClarity", "loudnessCompensation", "headphoneCorrection", "soundProfiles", "soundOutputID", "soundOutputName",
                            "soundPerOutput", "eqGains", "eqPreset", "eqOn", "audioCacheMB", "autoplay", "levelTarget", "bypassEffects"])
            var keys: [String] = []
            @MainActor func finish() {
                leveller.setOn(false)
                leveller.setLimiting(false)
                for key in keys {
                    leveller.setForTests(nil, for: key)
                    Task { await AudioCache.shared.remove(key) }
                }
                returnDefaults()
                report("level: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            Equalizer.shared.setOn(false)
            leveller.setLimiting(false)

            // A. the gain rules
            typealias Reading = LoudnessMeter.Reading
            check("a loud song (−8 LUFS) is turned down 6 dB", near(Leveller.gain(Reading(lufs: -8, peak: -0.1)), -6, 1e-9))
            check("a quiet song with room (−20 LUFS, loudest sample −10 dBFS) is turned up 6 dB",
                  near(Leveller.gain(Reading(lufs: -20, peak: -10)), 6, 1e-9))
            check("a boost stops 1 dB under the loudest sample (−20 LUFS, −3 dBFS: +2 dB, not +6)",
                  near(Leveller.gain(Reading(lufs: -20, peak: -3)), 2, 1e-9))
            check("a boost is at most 12 dB", Leveller.gain(Reading(lufs: -50, peak: -40)) == 12)

            // B. the processor, offline
            let flat = Array(repeating: 0.0, count: Equalizer.bands.count)
            let cut = SoundProcessor(gains: flat, level: -6).offline(frequency: 1000)
            check("a −6 dB level takes 6 dB off", near(cut, -6, 0.05), db(cut))
            let gliding = SoundProcessor(gains: flat, level: -6)
            let glide = gliding.offline(frequency: 1000, seconds: 2) { gliding.update(level: 0) }
            check("a new level glides there, not at once", glide > -5.9 && glide < -0.2, db(glide))
            check("…and gets there", near(gliding.appliedForTests ?? -99, 0, 0.01), db(gliding.appliedForTests))
            var boosted = flat
            boosted[6] = 12
            let both = SoundProcessor(gains: boosted, level: -6).offline(frequency: 500)
            check("with the equalizer: its preamp and the level add up (+12 dB at 500 Hz, level −6 dB: −6 dB at 500 Hz)",
                  near(both, -6, 0.5), db(both))

            // B2. the limiter: a boost keeps its volume, no sample past −1 dBFS, quiet audio untouched
            check("with the limiter, a quiet song is brought all the way up (−20 LUFS, −3 dBFS: +6 dB)",
                  Leveller.gain(Reading(lufs: -20, peak: -3), limiting: true) == 6)
            let limited = SoundProcessor(gains: boosted, limiting: true)
            let limitedChange = limited.offline(frequency: 500)                  // a −12 dBFS tone, +12 dB: 0 dBFS
            check("with the limiter, +12 dB at 500 Hz keeps its volume up to the −1 dBFS ceiling (+11 dB, not 0)",
                  limitedChange > 10 && limitedChange <= 11.1, db(limitedChange))
            check("…and the limiter took the peak down", (limited.limiterDeepestForTests ?? 0) < -0.5, db(limited.limiterDeepestForTests))
            let clean = SoundProcessor(gains: flat, limiting: true)
            let cleanChange = clean.offline(frequency: 1000)
            check("the limiter leaves audio under its ceiling as it is", near(cleanChange, 0, 0.01) && clean.limiterDeepestForTests == 0,
                  "\(db(cleanChange)), deepest \(db(clean.limiterDeepestForTests))")

            // B3. crossfeed (bs2b's numbers): bass reaches the other ear 4.5 dB down, highs stay on their side
            @MainActor func crossfed(_ hz: Double, both: Bool) -> (other: Double, same: Double) {
                let rate = 44_100.0, frames = Int(rate)
                var left = (0..<frames).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
                var right = both ? left : [Float](repeating: 0, count: frames)
                let before = left
                let feed = Crossfeed(sampleRate: rate)
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in feed.process(l.baseAddress!, r.baseAddress!, frames: frames) }
                }
                func power(_ x: [Float]) -> Double {
                    var sum = 0.0
                    for v in x[(frames / 2)...] { sum += Double(v) * Double(v) }
                    return sum
                }
                return (10 * log10(power(right) / power(left)), 10 * log10(power(left) / power(before)))
            }
            let bass = crossfed(100, both: false), treble = crossfed(10_000, both: false), mono = crossfed(60, both: true)
            check("crossfeed: 100 Hz in one ear reaches the other 4.5 dB down", near(bass.other, -4.5, 0.6), db(bass.other))
            check("…10 kHz stays on its side (under −20 dB)", treble.other < -20, db(treble.other))
            check("…and bass in both ears stays as loud", near(mono.same, 0, 0.3), db(mono.same))

            // B2b. true peak: a quarter-rate tone whose samples all sit at 85% while the wave between them reaches 120%
            @MainActor func truePeak(_ x: [Float], from: Int, to: Int) -> Float {         // an independent measure: 16×, 64-tap Hann sinc
                var peak: Float = 0
                for k in from..<to {
                    for step in 0..<16 {
                        let d = Double(step) / 16
                        var acc = 0.0
                        for m in -31...32 {
                            let t = Double(m) - d
                            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
                            acc += Double(x[k + m]) * sinc * (0.5 + 0.5 * cos(Double.pi * t / 32.5))
                        }
                        peak = max(peak, Float(abs(acc)))
                    }
                }
                return peak
            }
            var hidden = (0..<88_200).map { Float(1.2 * sin(Double.pi * Double($0) / 2 + Double.pi / 4)) }
            let sampleOnly = hidden[44_100..<45_600].map(abs).max() ?? 0, hiddenBefore = truePeak(hidden, from: 44_100, to: 45_600)
            let tpLimiter = PeakLimiter(sampleRate: 44_100, channels: 1)
            hidden.withUnsafeMutableBufferPointer { buffer in
                var channels = [buffer.baseAddress!]
                channels.withUnsafeMutableBufferPointer { tpLimiter.process($0, frames: 88_200) }
            }
            let hiddenAfter = truePeak(hidden, from: 44_400, to: 45_900)
            check("true peak: the tone's samples peak under the ceiling but the wave between them is over it (a sample-only limiter would pass it)",
                  sampleOnly < PeakLimiter.ceiling && hiddenBefore > 1.1, "samples \(sampleOnly), wave \(hiddenBefore)")
            check("…the limiter brings the wave itself to the −1 dBFS ceiling (measured at 16× oversampling)",
                  hiddenAfter < PeakLimiter.ceiling * 1.02, "\(hiddenAfter) against \(PeakLimiter.ceiling)")

            // B3b. vocal clarity: a centred voice up by the boost, the side as it was, bass untouched
            @MainActor func clarified(_ hz: Double, right sign: Float) -> Double {
                let rate = 44_100.0, frames = Int(rate)
                var left = (0..<frames).map { Float(0.25 * sin(2 * .pi * hz * Double($0) / rate)) }
                var right = left.map { $0 * sign }
                let before = left
                let clarity = VocalClarity(gain: 6, sampleRate: rate)
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in clarity.process(l.baseAddress!, r.baseAddress!, frames: frames) }
                }
                var after = 0.0, was = 0.0
                for i in (frames / 2)..<frames { after += Double(left[i] * left[i]); was += Double(before[i] * before[i]) }
                return 10 * log10(after / was)
            }
            let voice = clarified(2500, right: 1), side = clarified(2500, right: -1), lows = clarified(100, right: 1)
            check("vocal clarity +6 dB: a centred voice at 2.5 kHz comes up 6 dB", near(voice, 6, 0.3), db(voice))
            check("…what differs between the ears (the side) stays as it was", near(side, 0, 0.3), db(side))
            check("…and centred bass is untouched", near(lows, 0, 0.3), db(lows))

            // B3c. loudness compensation: where the volume is 18 dB down, +6 dB at 105 Hz, +2.25 dB at 8 kHz, the middle as it was
            let eighteenDown = pow(0.5, 3 / SoundChain.volumeCurve)       // the place whose gain is a cube's half
            let shelves = SoundChain.loudnessShelves(place: eighteenDown)
            check("loudness: at full volume there is nothing to add", SoundChain.loudnessShelves(place: 1).isEmpty)
            check("…18 dB down, a 6 dB bass shelf and a 2.25 dB treble shelf", shelves.count == 2
                  && near(shelves[0].gain, 6.02, 0.05) && near(shelves[1].gain, 2.26, 0.05),
                  shelves.map { String(format: "%.2f", $0.gain) }.joined(separator: ", "))
            @MainActor func compensated(_ hz: Double) -> Double {
                let processor = SoundProcessor(gains: flat)
                processor.update(loudness: shelves)
                return processor.offline(frequency: hz, seconds: 1)
            }
            let low = compensated(60), middle = compensated(1000), high = compensated(14000)
            // the shelves' response worked out offline (28 Oct): 60 Hz +5.38 dB (a 105 Hz shelf), 1 kHz 0, 14 kHz +2.19
            check("…in the chain: 60 Hz up 5.4 dB, 1 kHz as it was, 14 kHz up 2.2 dB, and no preamp taking it back",
                  near(low, 5.38, 0.4) && near(middle, 0, 0.3) && near(high, 2.19, 0.4), "\(db(low)), \(db(middle)), \(db(high))")

            // B3c2. the volume slider (29 Oct): half way sounds half as loud (−10 dB), a quarter a quarter (−20), not the cube's −18 and −36
            func slider(_ place: Float) -> Double { 20 * log10(Double(Player.gain(place))) }
            check("the slider: half way is −10 dB, a quarter −20 dB, a tenth −33 dB",
                  near(slider(0.5), -10.03, 0.05) && near(slider(0.25), -20.06, 0.05) && near(slider(0.1), -33.4, 0.1),
                  "\(db(slider(0.5))), \(db(slider(0.25))), \(db(slider(0.1)))")
            check("…nothing at the bottom, full at the top", Player.gain(0) == 0 && Player.gain(1) == 1)

            // B3d. bass harmonics: a low note gains its 3rd harmonic and keeps itself; what is above 110 Hz is left alone
            @MainActor func goertzel(_ x: [Float], _ hz: Double, rate: Double) -> Double {
                let c = 2 * cos(2 * Double.pi * hz / rate)
                var a = 0.0, b = 0.0
                for v in x { let t = Double(v) + c * a - b; b = a; a = t }
                return (a * a + b * b - c * a * b).squareRoot() * 2 / Double(x.count)
            }
            @MainActor func shaped(_ hz: Double, amplitude: Float) -> (Double, Double, Float) {
                let rate = 44_100.0, frames = 88_200
                guard let stage = BassHarmonics(sampleRate: rate, channels: 1) else { return (0, 0, 0) }
                var x = (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
                x.withUnsafeMutableBufferPointer { stage.process($0.baseAddress!, channel: 0, frames: frames, amount: 1) }
                let tail = Array(x[(frames / 2)...])
                return (goertzel(tail, hz, rate: rate), goertzel(tail, 3 * hz, rate: rate), tail.map(abs).max() ?? 0)
            }
            let (note, third, _) = shaped(60, amplitude: 0.3)
            check("bass harmonics: a 60 Hz note gains its 3rd harmonic (180 Hz, at least −26 dB under it)", third / note > 0.05,
                  String(format: "%.1f dB", 20 * log10(third / max(note, 1e-9))))
            check("…and the note itself is not made quieter (within 1 dB)", abs(20 * log10(note / 0.3)) < 1, db(20 * log10(note / 0.3)))
            let (kilohertz, _, _) = shaped(1000, amplitude: 0.3)
            check("…a 1 kHz tone is left as it was (within 0.1 dB)", abs(20 * log10(kilohertz / 0.3)) < 0.1, db(20 * log10(kilohertz / 0.3)))
            check("…and a loud low note stays within full scale", shaped(60, amplitude: 0.95).2 <= 1)

            // B5. the bitrate shown for the playing file: a header that agrees with the listing, one that doubles it, neither
            check("bitrate: header and listing agree: the reading stands", Player.trustedKbps(129, header: 256, listed: 256) == 129)
            check("…the header says double (some YouTube files): doubled", Player.trustedKbps(65, header: 256.5, listed: 128) == 130)
            check("…neither: not shown (the listing's label stays)", Player.trustedKbps(65, header: 300, listed: 128) == nil
                  && Player.trustedKbps(65, header: 128, listed: 0) == nil)

            // B4. headphone correction: AutoEq's AirPods Pro file (crinacle's measurement), as fetched
            let airpods = """
                Preamp: -6.0 dB
                Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
                Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
                Filter 3: ON PK Fc 8903 Hz Gain 6.0 dB Q 1.66
                Filter 4: ON PK Fc 183 Hz Gain 2.0 dB Q 0.77
                Filter 5: ON PK Fc 4613 Hz Gain 3.4 dB Q 2.46
                Filter 6: ON HSC Fc 10000 Hz Gain -0.5 dB Q 0.70
                Filter 7: ON PK Fc 1517 Hz Gain -1.0 dB Q 2.33
                Filter 8: ON PK Fc 929 Hz Gain 1.2 dB Q 2.75
                Filter 9: ON PK Fc 44 Hz Gain -0.5 dB Q 2.16
                Filter 10: ON PK Fc 618 Hz Gain -0.5 dB Q 2.86
                """
            let filters = CorrectionFilter.parse(airpods)
            check("a ParametricEQ.txt gives its 10 filters, shelves and peaks", filters.count == 10
                  && filters.first?.kind == .lowShelf && filters[5].kind == .highShelf, "\(filters.count)")
            let curvePeak = SoundProcessor.peak(coefficients: filters.flatMap { $0.coefficients(sampleRate: 44_100) }, sampleRate: 44_100)
            check("its curve peaks where AutoEq says (preamp −6.0 dB: the shelves and peaks are AutoEq's own)",
                  near(curvePeak, 6, 0.1), db(curvePeak))
            let corrected = SoundProcessor(gains: flat, correction: filters)
            let at8k = corrected.offline(frequency: 8903), at514 = corrected.offline(frequency: 514)
            check("in the chain: 8.9 kHz (+6 dB filter) comes out louder than 514 Hz (−4.4 dB filter), under the preamp",
                  at8k > at514 + 6 && at8k <= 0.1, "\(db(at8k)), \(db(at514))")

            // B5. target level, the limiter's default, and the A/B bypass (29 Oct)
            UserDefaults.standard.set(-18.0, forKey: "levelTarget")
            check("target −18 LUFS: material at −14 LUFS is turned down 4 dB", near(Leveller.gain(Reading(lufs: -14, peak: -20)), -4, 1e-9))
            UserDefaults.standard.set(-11.0, forKey: "levelTarget")
            check("target −11 LUFS: material at −14 LUFS is turned up 3 dB (limiter on)",
                  near(Leveller.gain(Reading(lufs: -14, peak: -20), limiting: true), 3, 1e-9))
            UserDefaults.standard.set(-15.0, forKey: "levelTarget")
            check("a target that is not one of the three is −14", near(Leveller.gain(Reading(lufs: -14, peak: -20)), 0, 1e-9))
            UserDefaults.standard.removeObject(forKey: "levelTarget")
            UserDefaults.standard.removeObject(forKey: "limiterOn")
            check("the limiter is on until it is switched off", Leveller.storedLimiting)
            UserDefaults.standard.set(false, forKey: "limiterOn")
            check("…and stays off when it is", !Leveller.storedLimiting)
            leveller.setOn(false)
            leveller.setLimiting(true)
            Equalizer.shared.setOn(true)
            Equalizer.shared.choose(.bassBoost)
            let coloured = chain.makeProcessor(key: "selftest", bypassing: false).offline(frequency: 50)
            let plain = chain.makeProcessor(key: "selftest", bypassing: true).offline(frequency: 50)
            check("bypass takes the equalizer's +6 dB at 50 Hz away and leaves the level as it was",
                  near(plain, 0, 0.3) && coloured > plain + 4, "\(db(coloured)) with, \(db(plain)) bypassed")
            Equalizer.shared.setOn(false)
            leveller.setLimiting(false)

            // C. the meter, on 1 kHz tones through AAC
            let loudPeak = 30000.0, quietPeak = 2000.0
            guard let loud = tone(hz: 1000, seconds: 30, peak: loudPeak), let quiet = tone(hz: 1000, seconds: 30, peak: quietPeak) else {
                check("tones made with afconvert", false)
                finish()
                return
            }
            func listing(_ name: String) -> Listing {
                Listing(source: "jiosaavn", id: "selftest-level-\(name)-\(UUID().uuidString)", title: "Level \(name)",
                        artists: ["Self-Test"], album: nil, duration: 30, popularity: nil, image: nil)
            }
            let loudSong = listing("loud"), quietSong = listing("quiet")
            keys = [loudSong.key, quietSong.key]
            try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
            try? loud.write(to: AudioCache.shared.path(for: loudSong.key))
            let quietFile = FileManager.default.temporaryDirectory.appending(path: "nn-level-quiet.m4a")
            try? quiet.write(to: quietFile)
            defer { try? FileManager.default.removeItem(at: quietFile) }
            let loudRead = try? LoudnessMeter.measure(file: AudioCache.shared.path(for: loudSong.key))
            let quietRead = try? LoudnessMeter.measure(file: quietFile)
            let loudLevel = 20 * log10(loudPeak / 32768), quietLevel = 20 * log10(quietPeak / 32768)
            check(String(format: "the meter reads each tone at its level through AAC (%.1f and %.1f LUFS)", loudLevel, quietLevel),
                  near(loudRead?.lufs ?? 0, loudLevel, 0.3) && near(quietRead?.lufs ?? 0, quietLevel, 0.3),
                  String(format: "%.2f, %.2f", loudRead?.lufs ?? .nan, quietRead?.lufs ?? .nan))
            let started = Date()
            _ = try? LoudnessMeter.measure(file: quietFile)
            report(String(format: "level: measuring a 30 s song took %.0f ms (a 4-minute song: about 8×)", Date().timeIntervalSince(started) * 1000))

            // D. the player
            UserDefaults.standard.set(500, forKey: "audioCacheMB")
            UserDefaults.standard.set(false, forKey: "autoplay")
            if !player.isMuted { player.toggleMute() }
            leveller.setOn(false)
            @MainActor func heard() async -> Double? {
                _ = chain.liveProcessors.map { $0.takeReading() }               // from now
                try? await Task.sleep(for: .seconds(1.5))
                return chain.liveProcessors.compactMap { $0.takeReading().change }.first
            }
            player.play([Track(best: loudSong, listings: [loudSong], choosingVersion: false)])
            check("(the loud tone plays)", await until(10) { player.isPlaying && player.livePosition > 1 })
            check("off: the song has no tap at all", !player.itemHasTapForTests)
            let real = Double(loud.count) * 8 / 30 / 1000                       // the tone's size over its 30 s
            check("the playing file's codec and bitrate are read (AAC, within 10% of size over length)",
                  await until(5) { player.playingQuality != nil } && (player.playingQuality.flatMap {
                      $0.hasPrefix("AAC ") ? Double($0.split(separator: " ")[1]) : nil } ?? 0) / real > 0.9
                      && (Double(player.playingQuality?.split(separator: " ")[1] ?? "0") ?? 0) / real < 1.1,
                  "\(player.playingQuality ?? "nothing") against \(Int(real)) kbps")

            leveller.setOn(true)
            check("switched on mid-song, the song playing from a file is measured within 2 s",
                  await until(2) { leveller.isMeasured(loudSong.key) })
            check("…and its audio goes through the tap", await until(3) { player.itemHasTapForTests })
            try? await Task.sleep(for: .seconds(1.5))                           // the glide to its level
            let loudChange = await heard()
            let loudOut = (loudRead?.lufs ?? 0) + (loudChange ?? 0)
            check(String(format: "the loud tone plays at −14 LUFS (%+.1f dB)", -14 - (loudRead?.lufs ?? 0)),
                  loudChange != nil && near(loudOut, -14, 0.5), db(loudChange))

            let stored = await AudioCache.shared.store(quiet, for: quietSong.key)
            check("a song stored in the cache (as the next song is) is measured before it plays",
                  stored ? await until(3) { leveller.isMeasured(quietSong.key) } : false)
            player.play([Track(best: quietSong, listings: [quietSong], choosingVersion: false)])
            check("(the quiet tone plays)", await until(10) { player.isPlaying && player.livePosition > 0.3 && player.itemHasTapForTests })
            let quietChange = await heard()
            let quietOut = (quietRead?.lufs ?? 0) + (quietChange ?? 0)
            check(String(format: "the quiet tone plays at −14 LUFS from its start (%+.1f dB): the two, 23.5 dB apart, come out level", -14 - (quietRead?.lufs ?? 0)),
                  quietChange != nil && near(quietOut, -14, 0.5), db(quietChange))
            check("the readings are kept on disk", FileManager.default.fileExists(atPath: Leveller.file.path))

            leveller.setOn(false)
            check("switched off, the song's tap is taken away", await until(3) { !player.itemHasTapForTests })

            // D2. sound for each output, on two made-up outputs (CI has no headphones to plug in)
            let profiles = SoundProfiles.shared, eq = Equalizer.shared
            profiles.followsSystem = false
            profiles.setOn(true)
            let speakers = SoundProfiles.Output(id: "selftest-speakers", name: "Self-Test Speakers")
            let buds = SoundProfiles.Output(id: "selftest-buds-\(UUID().uuidString)", name: "Self-Test Buds")
            profiles.switched(to: speakers)
            eq.setOn(true)
            eq.choose(.bassBoost)
            HeadphoneCorrection.shared.useForTests(nil, [])
            profiles.switched(to: buds)
            check("an output met for the first time starts from the settings as they are",
                  eq.on && eq.preset == .bassBoost, "\(eq.on), \(eq.preset.rawValue)")
            eq.choose(.vocal)
            HeadphoneCorrection.shared.useForTests(.init(name: "Self-Test Buds", path: "selftest/Buds"), CorrectionFilter.parse(
                "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00"))
            profiles.switched(to: speakers)
            check("back on the speakers: their equalizer, and no correction", eq.preset == .bassBoost && eq.gains == Equalizer.Preset.bassBoost.gains
                  && HeadphoneCorrection.shared.model == nil, "\(eq.preset.rawValue), \(HeadphoneCorrection.shared.model?.name ?? "none")")
            profiles.switched(to: buds)
            check("on the buds again: their equalizer and their correction", eq.preset == .vocal
                  && HeadphoneCorrection.shared.model?.name == "Self-Test Buds" && HeadphoneCorrection.shared.filters.count == 1,
                  "\(eq.preset.rawValue), \(HeadphoneCorrection.shared.model?.name ?? "none")")
            profiles.setOn(false)
            eq.choose(.flat)
            profiles.switched(to: speakers)
            check("off: one setting for every output (the speakers keep what the buds had)", eq.preset == .flat, eq.preset.rawValue)
            HeadphoneCorrection.shared.useForTests(nil, [])
            eq.setOn(false)

            // E. headphone correction, live from GitHub: the list, then one model's filters, and the tap for it
            let correction = HeadphoneCorrection.shared
            await correction.loadModels()
            check("AutoEq's list of headphones loads (over 5,000 models)", correction.models.count > 5000,
                  "\(correction.models.count)\(correction.problem.map { ", \($0)" } ?? "")")
            if let model = correction.models.first(where: { $0.name == "Apple AirPods Pro" }) ?? correction.models.first {
                await correction.choose(model)
                check("choosing \(model.name) fetches its filters", correction.model == model && correction.filters.count >= 5,
                      "\(correction.filters.count) filters\(correction.problem.map { ", \($0)" } ?? "")")
                check("…and the playing song gets a tap for it", await until(3) { player.itemHasTapForTests })
                await correction.choose(nil)
                check("turned off, the tap goes", await until(3) { !player.itemHasTapForTests })
            }
            if player.isPlaying { player.togglePlayPause() }
            finish()
        }
    }
}
#endif
