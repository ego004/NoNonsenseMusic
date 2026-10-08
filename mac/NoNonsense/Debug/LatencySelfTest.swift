#if DEBUG
import AppKit
import AVFoundation

/// With `NN_SELFTEST_LATENCY=1`: where the time goes between pressing play and hearing a song (8 Oct: "everything feels
/// like it is delaying"). For real songs, from YouTube and JioSaavn: the link (cold, then remembered), Apple's player on
/// its own (ready, then the first audio), and the whole path through the app's player. Needs the internet.
/// Found 8 Oct: Apple's player took 0.65–2 s to start a YouTube link (JioSaavn: ~0.25 s) because it asks for the file
/// open-ended ("bytes=0-"), which YouTube throttles to about playback speed; bounded ranges come at full speed.
extension SelfTest {
    private static var startedLatency = false

    static func runLatencyCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LATENCY"] != nil, !startedLatency else { return }
        startedLatency = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !player.isMuted { player.toggleMute() }
            func ms(_ since: Date) -> String { String(format: "%4.0f ms", Date().timeIntervalSince(since) * 1000) }

            var copies: [Listing] = []
            for query in ["blinding lights the weeknd", "tum hi ho arijit singh", "kesariya arijit singh"] {
                guard let found = try? await API.search(query), let song = found.songs.first else { report("latency: no results for \(query)"); continue }
                for source in ["ytmusic", "jiosaavn"] {
                    if let copy = song.listings.first(where: { $0.source == source }) { copies.append(copy) }
                }
            }

            for copy in copies {
                let name = "\(copy.source == "ytmusic" ? "YouTube " : "JioSaavn") \(copy.title.prefix(18))"
                // 1. the link, as the app gets it: cold (YouTube: forgotten first; JioSaavn: the server's cache as it is)
                await YouTubeLookup.shared.forget(copy.id)
                var t = Date()
                guard let url = try? await API.audioURL(copy) else { report("latency \(name): NO LINK"); continue }
                let cold = ms(t)
                t = Date()
                _ = try? await API.audioURL(copy)
                let warm = ms(t)
                // 2. Apple's player alone, on that link: ready to play, then the first audio
                let probe = AVPlayer()
                probe.automaticallyWaitsToMinimizeStalling = false
                probe.isMuted = true
                t = Date()
                let item = AVPlayerItem(url: url)
                probe.replaceCurrentItem(with: item)
                probe.play()
                var ready = "   –   ", sound = "   –   "
                for _ in 0..<400 {
                    if ready.hasPrefix(" ") && item.status == .readyToPlay { ready = ms(t) }
                    if probe.currentTime().seconds > 0.05 { sound = ms(t); break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                probe.pause(); probe.replaceCurrentItem(with: nil)
                // 3. the whole path through the app's player, link remembered as it would be on a second play
                t = Date()
                player.play([Track(best: copy, listings: [copy])])
                var heard = "   –   "
                for _ in 0..<400 {
                    if player.livePosition > 0.05 { heard = ms(t); break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                player.togglePlayPause()
                report("latency \(name) | link cold \(cold), remembered \(warm) | AVPlayer ready \(ready), first audio \(sound) | app, play → sound \(heard)")
            }
            report("latency: done")
            NSApp.terminate(nil)
        }
    }
}
#endif
