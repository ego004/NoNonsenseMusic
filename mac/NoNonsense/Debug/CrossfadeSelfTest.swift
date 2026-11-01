#if DEBUG
import AppKit

/// With `NN_SELFTEST_CROSSFADE=1` (no internet: tones made here, played from the audio cache): Settings › Playback ›
/// Crossfade. The fades' shape offline (equal power: halfway, each is at √½, so together they are as loud as one), then
/// the player with a 3 s crossfade: the next song starts 3 s before the first ends, on a second player, while the
/// first fades out; that player goes once the fade is over; a pause mid-fade stops the song going out. Muted;
/// settings put back.
extension SelfTest {
    private static var startedCrossfade = false

    static func runCrossfadeCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_CROSSFADE"] != nil, !startedCrossfade else { return }
        startedCrossfade = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("crossfade \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 100) where !done() { try? await Task.sleep(for: .milliseconds(10)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(2))
            borrowDefaults(["crossfadeSeconds", "gapless", "audioCacheMB", "autoplay", "shuffle", "repeat", "levelOn",
                            "limiterOn", "eqOn", "crossfeed"])
            var keys: [String] = []
            @MainActor func finish() {
                UserDefaults.standard.set(0.0, forKey: "crossfadeSeconds")
                SoundChain.shared.settingChanged()
                for key in keys { Task { await AudioCache.shared.remove(key) } }
                returnDefaults()
                report("crossfade: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }

            // A. the fades, offline
            let flat = Array(repeating: 0.0, count: Equalizer.bands.count)
            let rising = SoundProcessor(gains: flat), falling = SoundProcessor(gains: flat)
            rising.fade(in: true, over: 2)
            falling.fade(in: false, over: 2)
            _ = rising.offline(frequency: 1000, seconds: 1)                  // 1 s of a 2 s fade: halfway
            _ = falling.offline(frequency: 1000, seconds: 1)
            let up = rising.fadeForTests, down = falling.fadeForTests
            check("halfway, both fades are at √½ (equal power: together as loud as one song)",
                  abs(up - 0.7071) < 0.02 && abs(down - 0.7071) < 0.02 && abs(up * up + down * down - 1) < 0.02,
                  String(format: "in %.3f, out %.3f", up, down))
            _ = rising.offline(frequency: 1000, seconds: 1.2)
            _ = falling.offline(frequency: 1000, seconds: 1.2)
            check("at the end, the song fading in is at full volume and the one going out is silent",
                  rising.fadeForTests == 1 && falling.fadeForTests == 0, "\(rising.fadeForTests), \(falling.fadeForTests)")

            // B. the player
            UserDefaults.standard.set(500, forKey: "audioCacheMB")
            UserDefaults.standard.set(false, forKey: "autoplay")
            UserDefaults.standard.set(false, forKey: "gapless")
            if player.isShuffled { player.toggleShuffle() }
            while player.repeatMode != .off { player.cycleRepeat() }
            if !player.isMuted { player.toggleMute() }
            UserDefaults.standard.set(3.0, forKey: "crossfadeSeconds")
            SoundChain.shared.settingChanged()
            var songs: [Listing] = []
            for (n, hz) in [440.0, 660, 880].enumerated() {
                guard let data = tone(hz: hz, seconds: 10) else { check("tones made with afconvert", false); finish(); return }
                let song = Listing(source: "jiosaavn", id: "selftest-crossfade-\(n)-\(UUID().uuidString)", title: "Crossfade \(n + 1)",
                                   artists: ["Self-Test"], album: nil, duration: 10, popularity: nil, image: nil)
                try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
                try? data.write(to: AudioCache.shared.path(for: song.key))
                songs.append(song)
                keys.append(song.key)
            }
            @MainActor func tracks(_ list: [Listing]) -> [Track] { list.map { Track(best: $0, listings: [$0], choosingVersion: false) } }

            player.play(tracks(songs))
            check("(the first tone plays)", await until(10) { player.isPlaying && player.livePosition > 0.5 })
            var lastSeen = 0.0
            while player.playingListing?.key == songs[0].key, player.livePosition < 11 {
                lastSeen = player.livePosition
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("the next song starts 3 s before the first ends (at 7 s of 10)", abs(lastSeen - 7) < 0.3,
                  String(format: "%.2f s", lastSeen))
            check("…while the first plays on, fading out, on a second player", player.fadingForTests)
            check("…and the next starts from its beginning", player.playingListing?.key == songs[1].key && player.livePosition < 1,
                  String(format: "%.2f s", player.livePosition))
            check("the second player goes once the fade is over", await until(4.5) { !player.fadingForTests })
            // polled: one sample could land between two bursts of the audio thread (a slow virtual machine, CI, 30 Oct)
            check("the song fading in ends at full volume",
                  await until(3) { SoundChain.shared.liveProcessors.contains { $0.fadeForTests == 1 && ($0.takeReading().frames > 0) } })
            check("the song playing is the second, with its own length", player.playingListing?.key == songs[1].key
                  && abs(player.duration - 10) < 0.6, String(format: "%.2f s", player.duration))

            // C. a pause mid-fade
            player.seek(to: 6)
            _ = await until(3) { player.livePosition > 6.2 }
            check("(the second fades into the third)", await until(3) { player.playingListing?.key == songs[2].key && player.fadingForTests })
            player.togglePlayPause()
            check("a pause mid-fade stops the song going out", !player.fadingForTests && !player.isPlaying)

            finish()
        }
    }
}
#endif
