#if DEBUG
import AppKit

/// With `NN_SELFTEST_CACHE=1` and `NN_CACHE_DIR=<an empty folder>` (TICKETS 0b, 8 Oct): real songs, one from YouTube and
/// one from JioSaavn. Played once, a song is kept whole; played again it starts from its file, sooner; the next song in
/// the queue is fetched ahead, so ⏭ starts from its file; past the limit the least recently played go. Needs the internet.
extension SelfTest {
    private static var startedCache = false

    static func runCacheCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_CACHE"] != nil, !startedCache else { return }
        startedCache = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("cache \(ok ? "PASS" : "FAIL") \(rule)\(got.isEmpty ? "" : " (\(got))")")
            }
            guard ProcessInfo.processInfo.environment["NN_CACHE_DIR"] != nil else {
                report("cache: needs NN_CACHE_DIR (your own cache is never touched)"); NSApp.terminate(nil); return
            }
            try? await Task.sleep(for: .seconds(4))
            if !player.isMuted { player.toggleMute() }
            let savedLimit = UserDefaults.standard.object(forKey: "audioCacheMB")       // yours: put back at the end
            UserDefaults.standard.removeObject(forKey: "audioCacheMB")                  // the default, 500 MB

            func copy(_ query: String, _ source: String) async -> Listing? {
                (try? await API.search(query))?.songs.first?.listings.first { $0.source == source }
            }
            guard let yt = await copy("blinding lights the weeknd", "ytmusic"), let js = await copy("tum hi ho arijit singh", "jiosaavn") else {
                report("cache: no songs found"); NSApp.terminate(nil); return
            }
            let ytTrack = Track(best: yt, listings: [yt]), jsTrack = Track(best: js, listings: [js])
            @MainActor func untilSound(_ key: String) async -> Double? {
                let t = Date()
                for _ in 0..<600 {
                    if player.current?.best.key == key, player.livePosition > 0.05 { return Date().timeIntervalSince(t) * 1000 }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return nil
            }
            @MainActor func until(_ seconds: Double, _ done: () async -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) { if await done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return await done()
            }
            func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "no sound" }

            // 1. a click on a song never played: the network, and the whole song kept
            player.play([ytTrack])
            let cold = await untilSound(yt.key)
            check("a YouTube song plays", cold != nil, ms(cold))
            check("…and is kept whole on this Mac", await until(20) { await AudioCache.shared.file(for: yt.key) != nil })
            player.togglePlayPause()

            // 2. again: from its file, no link asked (a YouTube lookup would add ~0.2 s)
            await YouTubeLookup.shared.forget(yt.id)
            player.play([ytTrack])
            let again = await untilSound(yt.key)
            check("played again, it starts from its file, sooner", (again ?? 9999) < 300 && (again ?? 9999) < (cold ?? 0),
                  "first \(ms(cold)), again \(ms(again))")
            player.togglePlayPause()

            // 3. the next song is fetched ahead: ⏭ starts from its file
            player.play([ytTrack, jsTrack])
            check("the next song (JioSaavn) is fetched ahead, whole", await until(20) { await AudioCache.shared.file(for: js.key) != nil })
            player.next()
            let skipped = await untilSound(js.key)
            check("…so ⏭ starts from its file", (skipped ?? 9999) < 300, ms(skipped))
            player.togglePlayPause()

            // 4. the limit: 1 MB holds neither song; the least recently played goes first, and Off keeps nothing
            let before = await AudioCache.shared.size()
            UserDefaults.standard.set(1, forKey: "audioCacheMB")
            await AudioCache.shared.evict()
            let after = await AudioCache.shared.size()
            check("past the limit, songs go", before > 2_000_000 && after == 0, "\(before / 1000) KB → \(after / 1000) KB")
            UserDefaults.standard.set(0, forKey: "audioCacheMB")
            check("Off: no file is offered", await AudioCache.shared.file(for: yt.key) == nil)

            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "audioCacheMB") } else { UserDefaults.standard.removeObject(forKey: "audioCacheMB") }
            await AudioCache.shared.clear()
            report("cache: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
