#if DEBUG
import AppKit

/// With `NN_SELFTEST_YOUTUBE=1`: a YouTube song looked up by this Mac (YouTubeLookup, 8 Oct), not by the server, and
/// played to well past its first megabyte (the Android client was cut off there). Needs the internet and YouTube.
extension SelfTest {
    private static var startedYouTube = false

    static func runYouTubeCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_YOUTUBE"] != nil, !startedYouTube else { return }
        startedYouTube = true
        Task { @MainActor in
            var failed = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failed += 1 }
                report("youtube \(ok ? "PASS" : "FAIL") \(rule)\(got.isEmpty ? "" : " (\(got))")")
            }
            try? await Task.sleep(for: .seconds(4))                                    // signed in, the window up
            if !player.isMuted { player.toggleMute() }
            // a music track (no plain video): the kind the Android client could not play past 1 MB
            let song = Listing(source: "ytmusic", id: "J7p4bzqLvCw", title: "Blinding Lights", artists: ["The Weeknd"],
                               album: nil, duration: 200, popularity: nil, image: nil)

            let started = Date()
            let url = try? await YouTubeLookup.shared.audioURL(videoID: song.id, fresh: true)
            let took = Date().timeIntervalSince(started)
            check("this Mac looked the link up itself", url != nil, String(format: "%.2f s", took))
            check("…from YouTube, not from the server", url.map { $0.host() != API.baseURL.host() && $0.scheme == "https" } ?? false)
            let again = Date()
            _ = try? await YouTubeLookup.shared.audioURL(videoID: song.id)
            check("asked again, the remembered link comes back at once", Date().timeIntervalSince(again) < 0.05)

            // the whole song is served: a piece from its last part (past the first MB, where Android's links stopped)
            if let url {
                var request = URLRequest(url: url)
                request.setValue("bytes=3000000-3000999", forHTTPHeaderField: "Range")
                let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                check("a piece 3 MB into the song is served", status == 206, "HTTP \(status)")
            }

            player.play([Track(best: song, listings: [song])])
            for _ in 0..<40 where player.livePosition < 3 { try? await Task.sleep(for: .milliseconds(250)) }
            check("it plays in the app", player.livePosition >= 3,
                  String(format: "at %.1f s", player.livePosition) + " | playing \(player.isPlaying), buffering \(player.isBuffering), now \(player.current?.title ?? "nothing"), message \(player.errorMessage ?? "none")")
            player.togglePlayPause()
            report("youtube: \(failed == 0 ? "all checks pass" : "\(failed) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
