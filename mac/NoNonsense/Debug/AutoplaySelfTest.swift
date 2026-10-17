#if DEBUG
import AppKit

/// With `NN_SELFTEST_AUTOPLAY=1` (needs the internet): one song played alone; with Autoplay on, Up Next fills with other
/// songs before it ends, also for a song picked while Autoplay was still asking for the one before; with Autoplay off,
/// it stays empty. Your own Autoplay setting is put back.
extension SelfTest {
    private static var startedAutoplay = false

    static func runAutoplayCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_AUTOPLAY"] != nil, !startedAutoplay else { return }
        startedAutoplay = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("autoplay \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            if !player.isMuted { player.toggleMute() }
            let saved = UserDefaults.standard.object(forKey: "autoplay")
            let songs = (try? await API.search("tum hi ho arijit singh"))?.songs.map(Track.init) ?? []
            guard songs.count >= 2 else { check("songs to play", false); NSApp.terminate(nil); return }

            UserDefaults.standard.set(false, forKey: "autoplay")
            player.play([songs[1]])
            try? await Task.sleep(for: .seconds(4))
            check("Autoplay off: Up Next stays empty", player.upNext.isEmpty, "\(player.upNext.count)")

            UserDefaults.standard.set(true, forKey: "autoplay")
            // the second song is picked while Autoplay still asks for the first: that answer is not for it, and until
            // 17 Oct the request in flight kept the second from being asked for (its Up Next stayed empty)
            player.play([songs[1]])
            player.play([songs[0]])
            check("Autoplay on, a song picked while it asked for another: Up Next fills with songs like it",
                  await until(15) { player.upNext.count >= 5 }, "\(player.upNext.count)")
            check("…none of them the song playing", !player.upNext.contains { $0.isSameSong(as: songs[0]) })
            check("…all marked Autoplay", player.upNextEntries.allSatisfy(\.autoplay))
            player.addToQueue(songs[1])
            UserDefaults.standard.set("upNext", forKey: "nowPlayingPanel")
            player.showNowPlaying = true
            player.addToQueue(songs[1]); player.addToQueue(songs[1])
            try? await Task.sleep(for: .seconds(2))
            let mine = player.upNextEntries.prefix { !$0.autoplay }.count
            let lastRow = frames["upNext.row:\(mine - 1)"], heading = frames["upNext.autoplay"]
            report("autoplay: \(mine) of mine; last row \(lastRow.map { "\($0.integral)" } ?? "-"), heading \(heading.map { "\($0.integral)" } ?? "-")")
            check("the Autoplay heading sits below your last song", (lastRow?.maxY ?? .infinity) <= (heading?.minY ?? 0) + 0.5)
            check("Add to Queue goes before Autoplay's songs", player.upNextEntries.first?.track.id == songs[1].id && !(player.upNextEntries.first?.autoplay ?? true))
            report("autoplay: next up \(player.upNext.prefix(3).map { "\($0.title) · \($0.artistLine)" })")

            UserDefaults.standard.set(saved, forKey: "autoplay")
            report("autoplay: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
