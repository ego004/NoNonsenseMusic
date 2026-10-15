#if DEBUG
import AppKit
import SwiftUI

/// With `NN_SELFTEST_PAGES=1` (own test server): the pages' headers and album rows as the Windows app has them (15 Oct).
/// Without the network: the album facts line; album rows drawn off screen (the number in place of the cover, the playing
/// song's mark and fill in the Playing song colour); a playlist page's header at three window widths (its 200 pt cover
/// on the 32 pt margin, inside the page column). With the internet: an album page at the widest and narrowest windows
/// (230 pt cover, the text 28 pt beside it on its bottom edge, a round pin), an artist page (180 pt picture) and a
/// pinned album's numbered rows; without it those say SKIP. Pictures with `NN_SELFTEST_SNAP` and `NN_SELFTEST_VISIBLE=1`:
/// pages-playlist, pages-liked, and with the internet pages-album, pages-pinned, pages-artist.
extension SelfTest {
    private static var startedPages = false

    static func runPagesCheckIfAsked(library: LibraryStore, player: Player, theme: ThemeStore, downloads: DownloadStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_PAGES"] != nil, !startedPages else { return }
        startedPages = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("pages \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func skip(_ what: String) { report("pages SKIP \(what): needs the internet") }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer(), let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
                report("pages: this app's own test server and its window needed"); NSApp.terminate(nil); return
            }
            if !player.isMuted { player.toggleMute() }                  // tests stay silent
            let saved = window.frame
            @MainActor func resize(to width: CGFloat) async {
                window.setFrame(NSRect(x: saved.minX, y: saved.minY, width: width, height: saved.height), display: true)
                try? await Task.sleep(for: .seconds(1))
            }
            /// A page's picture at this window's width: its side, and its place on the page margin (32 pt, plus half of
            /// what the page has beyond the page column).
            @MainActor func measure(_ name: String, picture: String, page: String, side: CGFloat) {
                let width = Int(window.frame.width)
                guard let p = frames[picture], let whole = frames[page] else {
                    check("\(name) at \(width) pt: its header reports where it is", false); return
                }
                let beyond = max(0, (whole.width - maxPageWidth) / 2)
                let margin = 32 + beyond
                // a scroller that stays (a mouse attached) narrows the rows by up to 16 pt: a centred column moves up to 8
                let slack: CGFloat = beyond > 0 ? 8.5 : 1
                check("\(name) at \(width) pt: a \(Int(side)) pt picture", abs(p.width - side) < 0.5 && abs(p.height - side) < 0.5, "\(p.size)")
                check("\(name) at \(width) pt: on the page margin, in the page column (\(Int(margin)) pt in a \(Int(whole.width)) pt page)",
                      abs(p.minX - whole.minX - margin) < slack, "\(p.minX - whole.minX)")
            }

            // the facts line under an album's artists
            let facts = AlbumView.facts(year: 2024, songs: 12, minutes: 37)
            check("an album's facts are in capitals, split by ·", facts == "2024 · 12 SONGS · 37 MIN", facts)
            let short = AlbumView.facts(year: nil, songs: 1, minutes: 3)
            check("…one song and no year: 1 SONG · 3 MIN", short == "1 SONG · 3 MIN", short)
            let unknown = AlbumView.facts(year: 2019, songs: 5, minutes: 0)
            check("…no length: left out", unknown == "2019 · 5 SONGS", unknown)

            // album rows, drawn off screen (window pictures cannot draw lists). A made-up song is the current one: it
            // cannot load, so it stays current, paused (Autoplay off, or the player would move on to a station's song).
            // The Playing song colour is pure red meanwhile
            @MainActor func madeUp(_ n: Int) -> Track {
                let copy = Listing(source: "jiosaavn", id: "selftest-pages-\(n)", title: "Pages test \(n)", artists: ["Self-test"],
                                   album: "Self-test Album", duration: 200, popularity: nil, image: nil)
                return Track(best: copy, listings: [copy])
            }
            @MainActor func drawn(_ track: Track, number: Int?) -> Drawing? {
                drawing(of: SongRow(track: track, queue: [track], index: 0, number: number).frame(width: 640)
                    .environment(player).environment(library).environment(theme).environment(downloads))
            }
            borrowDefaults(["theme.playing.mode", "theme.playing.hex", "autoplay"])
            UserDefaults.standard.set(false, forKey: "autoplay")
            let colour = (mode: theme.mode(.playing), hex: theme.hex(.playing))
            theme.setMode(.custom, for: .playing)
            theme.setHex("#FF0000", for: .playing)
            let other = madeUp(1), playing = madeUp(3)
            player.play([playing])
            _ = await until(30) { !player.isBuffering && !player.isPlaying }      // given up on: paused, its ▶ drawable
            if player.current?.id == playing.id, !player.isBuffering, !player.isPlaying,
               let one = drawn(other, number: 1), let eight = drawn(other, number: 8),
               let marked = drawn(playing, number: 3), let plain = drawn(playing, number: nil) {
                let ink = one.box.filter { $0.a > 0 }
                let strongest = ink.map { $0.a }.max() ?? 0
                check("an album row draws its own number in place of the cover", !ink.isEmpty && one.box.map { $0.a } != eight.box.map { $0.a },
                      "\(ink.count) inked pixels")
                check("…in a quiet grey (.42 of the text colour, not full ink)",
                      ink.allSatisfy { abs($0.r - $0.g) <= 8 && abs($0.g - $0.b) <= 8 } && (40...130).contains(strongest),
                      "strongest alpha \(strongest) of 255")
                check("…and no fill while another song plays", one.edge.a == 0, "\(one.edge)")
                let red = marked.box.filter { $0.a >= 200 && $0.r >= 200 && $0.g < 60 && $0.b < 60 }
                check("the playing album row shows the playing mark in the Playing song colour", !red.isEmpty, "\(red.count) red pixels")
                let fill = marked.edge
                check("…and its row is filled with that colour at .12", (20...42).contains(fill.a) && fill.r >= fill.a - 4 && fill.g < 6 && fill.b < 6, "\(fill)")
                check("a playing row with a cover (not an album's) is not filled", plain.edge.a == 0, "\(plain.edge)")
            } else {
                check("a made-up song is current and given up on, and rows draw off screen", false,
                      "current \(player.current?.title ?? "none"), buffering \(player.isBuffering), playing \(player.isPlaying)")
            }
            theme.setMode(colour.mode, for: .playing)
            theme.setHex(colour.hex, for: .playing)
            returnDefaults()
            player.stop()

            // a playlist page: its header needs no network; songs in it when the internet answers
            let reply = try? await API.search("arijit singh")
            let songs = (reply?.songs ?? []).prefix(6).map(Track.init)
            let name = "Pages test \(Int.random(in: 1000...9999))"
            _ = await library.createPlaylist(named: name)
            var rowWithCover: CGFloat = 0
            if let list = library.playlists.first(where: { $0.name == name }) {
                for song in songs.prefix(4) { await library.add(song, to: list) }
                frames["playlist.cover"] = nil
                NotificationCenter.default.post(name: .selfTestOpen, object: list.id)
                if await until(10, { frames["playlist.cover"] != nil }) {
                    for width in [1180.0, 900, 2000] {
                        await resize(to: width)
                        measure("the playlist page", picture: "playlist.cover", page: "playlist.page", side: 200)
                    }
                    await resize(to: 1180)
                    rowWithCover = songs.isEmpty ? 0 : frames["playlist.row:0"]?.height ?? 0
                    windowShot("pages-playlist")
                } else {
                    check("a playlist opens on its page", false)
                }
            } else {
                check("a playlist to look at", false)
            }

            // an album page, its pin, and the same album pinned: a playlist whose rows are numbered
            if let album = reply?.albums?.first?.best {
                frames["album.cover"] = nil
                Navigator.shared.open(.album(album))
                if await until(15, { frames["album.cover"] != nil }) {
                    // the narrowest window (900) still leaves the page wider than the Windows app's narrow layout (560)
                    for width in [1180.0, 900] {
                        await resize(to: width)
                        measure("the album page", picture: "album.cover", page: "album.page", side: 230)
                        if let cover = frames["album.cover"], let text = frames["album.text"] {
                            check("…its text 28 pt beside the cover, standing on its bottom edge",
                                  abs(text.minX - cover.maxX - 28) < 1 && abs(text.maxY - cover.maxY) < 1,
                                  "gap \(text.minX - cover.maxX), bottoms \(text.maxY) / \(cover.maxY)")
                        }
                        if let pin = frames["album.pin"] {
                            check("…Pin to Home a round button", abs(pin.width - pin.height) <= 1, "\(pin.size)")
                        }
                    }
                    await resize(to: 1180)
                    // its second song plays (muted): the picture shows the playing row
                    if let detail = try? await API.album(album), detail.songs.count > 1 {
                        player.play(detail.songs.map(Track.init), startAt: 1)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    windowShot("pages-album")

                    await library.pin(album)
                    if let pinned = library.pinned(album) {
                        frames["playlist.row:0"] = nil
                        NotificationCenter.default.post(name: .selfTestOpen, object: pinned.id)
                        if await until(10, { frames["playlist.row:0"] != nil }) {
                            try? await Task.sleep(for: .seconds(1))           // its own rows, not the replaced playlist's
                            let row = frames["playlist.row:0"]?.height ?? 0
                            check("a pinned album's rows are numbered: 40 pt number boxes, not 44 pt covers (rows \(Int(row)) pt, with covers \(Int(rowWithCover)) pt)",
                                  rowWithCover > 0 && row > 0 && row < rowWithCover - 2)
                            windowShot("pages-pinned")
                        } else {
                            check("a pinned album opens with its songs", false)
                        }
                        await library.unpin(pinned)
                    } else {
                        check("Pin to Home pins the album", false)
                    }
                } else {
                    check("an album opens on its page", false)
                }
                Navigator.shared.path = []
            } else {
                skip("the album page, its pin and a pinned album's numbered rows")
            }

            // an artist page
            if let artist = reply?.artists?.first?.best {
                frames["artist.picture"] = nil
                Navigator.shared.open(.artist(artist))
                if await until(15, { frames["artist.picture"] != nil }) {
                    try? await Task.sleep(for: .seconds(1))
                    measure("the artist page", picture: "artist.picture", page: "artist.page", side: 180)
                    windowShot("pages-artist")
                } else {
                    check("an artist opens on their page", false)
                }
                Navigator.shared.path = []
            } else {
                skip("the artist page")
            }

            // Liked Songs, with its new title, for the picture
            var likedHere: [Track] = []
            for song in songs.suffix(3) where !library.isLiked(song) { await library.toggleLike(song); likedHere.append(song) }
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.liked))
            try? await Task.sleep(for: .seconds(2))
            windowShot("pages-liked")

            for song in likedHere { await library.toggleLike(song) }
            if let list = library.playlists.first(where: { $0.name == name }) { await library.deletePlaylist(list) }
            player.stop()
            window.setFrame(saved, display: true)
            report("pages: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// `view` drawn off screen at one pixel per point.
    fileprivate static func drawing(of view: some View) -> Drawing? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let bytes = Array(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        return Drawing(bytes: bytes, width: image.width, height: image.height)
    }
}

/// A view drawn off screen (the pages check): premultiplied sRGB bytes, top row first, one pixel per point.
fileprivate struct Drawing {
    typealias Pixel = (r: Int, g: Int, b: Int, a: Int)
    let bytes: [UInt8]
    let width: Int
    let height: Int

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return (r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }

    /// A song row's number box: 34 points from the row's 8 pt padding, 40 tall, centred in the row.
    var box: [Pixel] {
        let top = max(0, (height - 40) / 2)
        return (top..<min(height, top + 40)).flatMap { y in (8..<min(width, 42)).map { x in pixel(x, y) } }
    }

    /// The row's own background, left of the number box.
    var edge: Pixel { pixel(3, height / 2) }
}
#endif
