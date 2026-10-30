#if DEBUG
import AppKit

/// With `NN_SELFTEST_GAPLESS=1` (no internet: tones made here, played from the audio cache): Settings › Playback › No
/// gaps between songs. Two 6 s tones played one after the other, gapless off and then on. The gap is read from the
/// player's own clock: where the first song's audio ends (the last time seen plus what was left of it) and where the
/// second's begins (the time seen minus how far in it is). Then: the next song is queued only while it should be, the
/// change reports the new song as playing, and ⏭ still works with a song queued. Muted; settings put back.
extension SelfTest {
    private static var startedGapless = false

    static func runGaplessCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_GAPLESS"] != nil, !startedGapless else { return }
        startedGapless = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("gapless \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 100) where !done() { try? await Task.sleep(for: .milliseconds(10)) }
                return done()
            }
            func memoryMB() -> Double {
                var info = rusage_info_v2()
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
                }
                return Double(info.ri_phys_footprint) / 1e6
            }
            try? await Task.sleep(for: .seconds(2))
            borrowDefaults(["gapless", "audioCacheMB", "autoplay", "shuffle", "repeat", "levelOn", "limiterOn", "eqOn"])
            var keys: [String] = []
            @MainActor func finish() {
                UserDefaults.standard.set(false, forKey: "gapless")
                for key in keys { Task { await AudioCache.shared.remove(key) } }
                returnDefaults()
                report("gapless: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            UserDefaults.standard.set(500, forKey: "audioCacheMB")
            UserDefaults.standard.set(false, forKey: "autoplay")
            if player.isShuffled { player.toggleShuffle() }
            while player.repeatMode != .off { player.cycleRepeat() }
            if !player.isMuted { player.toggleMute() }

            var songs: [Listing] = []
            for (n, hz) in [440.0, 660, 880].enumerated() {
                guard let data = tone(hz: hz, seconds: 6) else { check("tones made with afconvert", false); finish(); return }
                let song = Listing(source: "jiosaavn", id: "selftest-gapless-\(n)-\(UUID().uuidString)", title: "Gapless \(n + 1)",
                                   artists: ["Self-Test"], album: nil, duration: 6, popularity: nil, image: nil)
                try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
                try? data.write(to: AudioCache.shared.path(for: song.key))
                songs.append(song)
                keys.append(song.key)
            }
            @MainActor func tracks(_ list: [Listing]) -> [Track] { list.map { Track(best: $0, listings: [$0], choosingVersion: false) } }

            /// Plays `first` then `second` and returns the silence between them, in seconds (negative: overlap).
            @MainActor func gap(_ first: Listing, _ second: Listing) async -> Double? {
                player.play(tracks([first, second]))
                var timeline: [String] = []        // what the player did in the first seconds, for a failure's message
                let began = Date()
                guard await until(10, {
                    if timeline.count < 16, Date().timeIntervalSince(began) > Double(timeline.count) * 0.25 {
                        timeline.append(String(format: "%.2f s: ", Date().timeIntervalSince(began)) + player.playerStateForTests)
                    }
                    return player.isPlaying && player.livePosition > 0.2 && player.playingListing?.key == first.key
                }) else {
                    report("gapless: the first song never played: \(player.playerStateForTests); timeline: " + timeline.joined(separator: " | "))
                    return nil
                }
                // the last look at the first song, every 5 ms, until the second takes over
                var end: Date?
                while player.playingListing?.key == first.key {
                    let left = player.duration - player.livePosition
                    if left >= 0, player.livePosition > 0 { end = Date().addingTimeInterval(left) }
                    try? await Task.sleep(for: .milliseconds(5))
                    if Date().timeIntervalSince(end ?? .distantFuture) > 5 {
                        report("gapless: the first song ended 5 s ago and the second has not taken over: \(player.playerStateForTests)")
                        return nil
                    }
                }
                // the second song's own clock: in its first second (until the queue player swaps items, the first's reads ~6 s)
                guard await until(5, { player.playingListing?.key == second.key && player.livePosition > 0.05 && player.livePosition < 1 })
                else {
                    report("gapless: the second song never showed a clock in its first second: \(player.playerStateForTests)")
                    return nil
                }
                let start = Date().addingTimeInterval(-player.livePosition)
                if let end {
                    // where the changeover's time went: each tap's times against the first song's end and the second's clock
                    let origin = began.timeIntervalSinceReferenceDate
                    func at(_ t: Double) -> String { t == 0 ? "never" : String(format: "%+.0f ms", (t - origin) * 1000) }
                    let taps = SoundChain.shared.timingsForTests.map { "\($0.key.suffix(12).prefix(4)): prepared \(at($0.prepared)), first \(at($0.first)), last \(at($0.last))" }
                    report(String(format: "gapless: timing from play(): first song's end %+.0f ms, second song's clock 0 at %+.0f ms; ", end.timeIntervalSinceReferenceDate * 1000 - origin * 1000, start.timeIntervalSinceReferenceDate * 1000 - origin * 1000) + taps.joined(separator: "; "))
                }
                return end.map { start.timeIntervalSince($0) }
            }
            func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0 * 1000) } ?? "no change seen" }

            // A. off: as before
            UserDefaults.standard.set(false, forKey: "gapless")
            player.gaplessChanged()
            let before = await gap(songs[0], songs[1])
            check("off: nothing is queued", player.queuedKeyForTests == nil)
            report("gapless: off, the gap between songs is \(ms(before))")

            // B. on
            UserDefaults.standard.set(true, forKey: "gapless")
            player.gaplessChanged()
            player.play(tracks([songs[0], songs[1], songs[2]]))
            let memoryBefore = memoryMB()
            check("on: the next song is queued behind the playing one once it is in the cache",
                  await until(5) { player.queuedKeyForTests == songs[1].key })
            report(String(format: "gapless: queuing the next song took %.1f MB of memory", memoryMB() - memoryBefore))
            player.clearUpNext()
            check("Up Next cleared: nothing is queued any more", await until(2) { player.queuedKeyForTests == nil })
            let after = await gap(songs[0], songs[1])
            report("gapless: on, the gap between songs is \(ms(after))")
            check("on: no gap (under 20 ms of the player's clock)", after.map { abs($0) < 0.02 } ?? false,
                  "\(ms(after)); \(player.playerStateForTests)")
            check("…where off had one, so the test can see a gap", (before ?? 0) > (after ?? 0) + 0.03, "\(ms(before)) off")
            check("the second song is the one playing, as after any change", player.playingListing?.key == songs[1].key
                  && player.current?.best.key == songs[1].key && player.isPlaying, player.playerStateForTests)
            check("its own length is read, not the first's (6 s)", abs(player.duration - 6) < 0.5, String(format: "%.2f s", player.duration))

            // D. an effect on (levelling): the songs have a tap, and a short early start stands in for gapless (29 Oct)
            Leveller.shared.setOn(true)
            player.gaplessChanged()
            player.play(tracks([songs[0], songs[1], songs[2]]))
            _ = await until(5) { player.queuedKeyForTests == songs[1].key }
            player.clearUpNext()
            let handover = await gap(songs[0], songs[1])
            report("gapless: with an effect on, the gap between songs is \(ms(handover))")
            check("with an effect on: no gap (the songs overlap by at most 0.12 s)", handover.map { $0 < 0.02 && $0 > -0.12 } ?? false,
                  "\(ms(handover)); \(player.playerStateForTests)")
            check("…and the second song is the one playing", player.playingListing?.key == songs[1].key && player.isPlaying, player.playerStateForTests)
            Leveller.shared.setOn(false)
            player.gaplessChanged()

            // E. ⏮ onto a song that will not load goes on back, not forward again (29 Oct)
            let missing = Listing(source: "jiosaavn", id: "selftest-missing-\(UUID().uuidString)", title: "Will Not Load", artists: ["Self-Test"],
                                  album: nil, duration: 6, popularity: nil, image: nil)
            player.play(tracks([songs[0], missing, songs[1]]), startAt: 2)
            _ = await until(5) { player.playingListing?.key == songs[1].key && player.isPlaying && player.livePosition > 0.2 }
            player.previous()
            check("⏮ onto a song that will not load goes on back to the one before it",
                  await until(30) { player.playingListing?.key == songs[0].key && player.isPlaying }, player.playerStateForTests)

            // C. ⏭ with a song queued
            player.play(tracks([songs[0], songs[1], songs[2]]))
            _ = await until(5) { player.queuedKeyForTests == songs[1].key }
            player.next()
            check("⏭ with a song queued plays the next song", await until(5) { player.playingListing?.key == songs[1].key && player.livePosition > 0.2 },
                  player.playerStateForTests)
            check("…and queues the one after it", await until(5) { player.queuedKeyForTests == songs[2].key }, player.playerStateForTests)

            if player.isPlaying { player.togglePlayPause() }
            finish()
        }
    }
}
#endif
