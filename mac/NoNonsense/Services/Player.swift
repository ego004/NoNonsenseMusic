import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Playback: the queue, AVPlayer, media keys and Control Center (Now Playing), play/skip/finish
/// events for your taste data, Discord presence, and falling back to another copy when one fails.
@Observable
final class Player {
    /// What plays in what order: shuffle, repeat, "play next", a playlist's edits (Services/PlayQueue.swift).
    private(set) var order = PlayQueue()
    var queue: [Track] { order.tracks }
    var index: Int { order.index }
    var isShuffled: Bool { order.isShuffled }
    var repeatMode: PlayQueue.Repeat { order.repeatMode }
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var isBuffering = false
    private(set) var errorMessage: String?
    /// Counts every problem shown: the player bar shakes once per problem (RootView), not when the message clears.
    private(set) var problems = 0
    var showNowPlaying = false
    private(set) var nextPresses = 0                     // every skip, by any means: the buttons bounce on these
    private(set) var previousPresses = 0
    @ObservationIgnored var barFrame: CGRect = .zero     // the player bar, in window coordinates (top-left origin)
    @ObservationIgnored private var swipeMonitor: Any?
    @ObservationIgnored private var swipeTravel: CGFloat = 0
    @ObservationIgnored private var swipeDone = false

    var current: Track? { order.current }
    var duration: Double { Double(current?.duration ?? 0) }
    var upNext: [Track] { order.upNext }
    /// The playlist the queue came from ("Gym"), for Now Playing and Discord; nil for other queues.
    var playingFrom: String? {
        guard let source = order.source, source.hasPrefix("playlist:"),
              let id = UUID(uuidString: String(source.dropFirst("playlist:".count))) else { return nil }
        return library.playlists.first { $0.id == id }?.name ?? library.details[id]?.name
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let downloads: DownloadStore
    /// True while the playing copy is a downloaded file (no server, no internet needed).
    private(set) var playingFile = false
    @ObservationIgnored private let presence: Presence
    /// AVPlayer's own playing / waiting / paused state, observed when it changes (no timer: see `position`)
    @ObservationIgnored private var controlStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var fallbacksTried = 0
    @ObservationIgnored private var failuresInARow = 0     // with repeat on, a queue where nothing plays must stop somewhere
    /// Shuffle on or off for the next queue too, and repeat: both remembered between launches, as in Apple Music.
    @ObservationIgnored private var shufflePreferred = UserDefaults.standard.bool(forKey: "shuffle")
    private(set) var playingListing: Listing?                         // the copy AVPlayer is playing right now
    private(set) var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1   // 0...1, remembered
    private(set) var isMuted = false
    @ObservationIgnored private var freshRetried: Set<String> = []   // listing keys already retried with serve_fresh
    @ObservationIgnored private var messageTimer: Task<Void, Never>?
    @ObservationIgnored private var artwork: [String: MPMediaItemArtwork] = [:]

    init(library: LibraryStore, presence: Presence, downloads: DownloadStore) {
        self.library = library
        self.downloads = downloads
        self.presence = presence
        // start as soon as audio arrives, instead of first buffering several seconds (the CDN answers in ~0.26 s)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = volume
        order.repeatMode = UserDefaults.standard.string(forKey: "repeat").flatMap(PlayQueue.Repeat.init(rawValue:)) ?? .off
        // No periodic time observer: it set `position` twice a second and every view reading it redrew, the app's
        // biggest steady cost while playing (7 Oct). `position` now changes only on events; the progress line and
        // times are drawn by Core Animation (PlaybackTimeline), and code that needs the exact time reads livePosition.
        controlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            let status = avPlayer.timeControlStatus
            Task { @MainActor in self?.controlStatusChanged(status) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        }
        setUpRemoteCommands()
        // a playlist you edit while it plays: the queue follows (PlayQueue.sync ignores other playlists)
        library.playlistChanged = { [weak self] detail in
            self?.syncQueue(source: detail.queueSource, items: zip(detail.keys, detail.tracks).map { (key: $0, track: $1) })
        }
    }

    // MARK: - controls

    /// Plays `tracks` from song `i`. With shuffle on, song `i` plays first and the rest are shuffled.
    /// `keys` name the entries (a playlist's item ids) and `source` says where they came from ("playlist:<id>"),
    /// so later edits to that playlist reach this queue (`syncQueue`).
    func play(_ tracks: [Track], startAt i: Int = 0, keys: [String]? = nil, source: String? = nil) {
        guard tracks.indices.contains(i) else { return }
        reportSkipIfNeeded()
        order.load(tracks, startAt: i, keys: keys, source: source, shuffled: shufflePreferred)
        startCurrent()
    }

    /// The Play button on a list: in your order (shuffle off), from the first song.
    func playInOrder(_ tracks: [Track], keys: [String]? = nil, source: String? = nil) {
        setShufflePreference(false)
        play(tracks, startAt: 0, keys: keys, source: source)
    }

    /// The Shuffle button on a list: shuffle on, then a random song first and the rest spread out.
    func shufflePlay(_ tracks: [Track], keys: [String]? = nil, source: String? = nil) {
        guard !tracks.isEmpty else { return }
        setShufflePreference(true)
        play(tracks, startAt: Int.random(in: tracks.indices), keys: keys, source: source)
    }

    func playNext(_ track: Track) {
        guard current != nil else { play([track]); return }
        order.insertNext(track)
        announceNext()
    }

    func toggleShuffle() {
        setShufflePreference(!shufflePreferred)
        order.setShuffle(shufflePreferred)
        announceNext()
    }

    /// off → all → one → off
    func cycleRepeat() {
        order.repeatMode = order.repeatMode.next
        UserDefaults.standard.set(order.repeatMode.rawValue, forKey: "repeat")
        announceNext()
    }

    /// Up Next as Now Playing shows it: the songs after the current one, each with its own id (a song can be in twice).
    var upNextEntries: [PlayQueue.Entry] { order.upcoming }

    /// Up Next rearranged by hand; offsets count from the next song.
    func moveUpNext(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        order.moveUpcoming(fromOffsets: offsets, toOffset: destination)
        announceNext()
    }

    func removeFromUpNext(at offset: Int) {
        order.removeUpcoming(at: offset)
        announceNext()
    }

    func clearUpNext() {
        order.clearUpcoming()
        announceNext()
    }

    /// A playlist changed (a move, an add, a remove). If the queue came from it, the queue follows; else nothing.
    func syncQueue(source: String, items: [(key: String, track: Track)]) {
        // only the queue that is playing: `order.sync` is a mutating call, and Observation counts any mutation as a
        // change even when sync returns at once, so opening any playlist redrew the whole window (audit, 7 Oct)
        guard order.source == source else { return }
        order.sync(source: source, items: items)
        if order.source == source { announceNext() }
    }

    /// Tells the Prefetcher the next 5 songs in play order (round again with repeat on), as the copies that will play.
    private func announceNext() {
        var probe = order, next: [Listing] = []
        while next.count < 5, let n = probe.indexAfterNext(), n != order.index {
            next.append(probe.tracks[n].best)
            probe.move(to: n)
        }
        Prefetcher.shared.queueChanged(next)
    }

    private func setShufflePreference(_ on: Bool) {
        shufflePreferred = on
        UserDefaults.standard.set(on, forKey: "shuffle")
    }

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
        position = livePosition                                     // the clock's new starting point
        publish()
    }

    func next() {
        guard current != nil else { return }
        nextPresses += 1
        reportSkipIfNeeded()
        go(to: order.indexAfterNext())
    }

    func previous() {
        previousPresses += 1
        if livePosition > 3 { seek(to: 0); return }     // like every player: first press restarts the song
        reportSkipIfNeeded()
        guard let i = order.indexAfterPrevious() else { seek(to: 0); return }   // the first song, repeat off: restart it
        go(to: i)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        reportSkipIfNeeded()
        go(to: i)
    }

    /// 0...1. The app's own volume, under the Mac's; remembered between launches.
    func setVolume(_ level: Float) {
        volume = min(1, max(0, level))
        player.volume = volume
        if isMuted { isMuted = false; player.isMuted = false }
        // saved once the slider settles, not on every pointer move of a drag
        volumeSave?.cancel()
        volumeSave = Task { [volume] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { UserDefaults.standard.set(volume, forKey: "volume") }
        }
    }
    @ObservationIgnored private var volumeSave: Task<Void, Never>?

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Where the song is right now, read from the audio player itself: `position` changes only on events (play,
    /// pause, seek, a stall), so it is the time of the last event. Not observed: read it when you need it.
    var livePosition: Double {
        let now = player.currentTime().seconds
        return now.isFinite ? now : position
    }

    func seek(to seconds: Double) {
        position = seconds
        seeks += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        publish()
    }
    /// Counts every seek. `position` alone can miss one: ⏮ in the middle of a song seeks to 0, and `position` may
    /// still be 0 from the song's start (it changes only on events), so nothing would change. Lyrics follow this.
    private(set) var seeks = 0

    /// Space plays/pauses anywhere in the window, except while typing in a text field.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPlainSpace = event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard isPlainSpace else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.current != nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
                self.togglePlayPause()
                return true
            }
            return handled ? nil : event
        }
    }

    /// Two-finger swipe across the player bar: left = next song, right = previous. One skip per swipe;
    /// the coasting after you lift your fingers is ignored. Vertical swipes still scroll whatever is underneath.
    func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // decide on the main actor, return a plain Bool (an NSEvent cannot cross isolation), consume outside
            let consumed = MainActor.assumeIsolated { () -> Bool in
                // an event with no window attached carries a screen location: find the window under it
                guard let self, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                      let window = event.window ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(event.locationInWindow) }),
                      let content = window.contentView else { return false }
                let inWindow = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
                let point = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
                guard self.barFrame.contains(point) else { return false }
                if event.phase == .began { self.swipeTravel = 0; self.swipeDone = false }
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
                // the fingers' direction, whatever the "natural scrolling" setting
                self.swipeTravel += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                if !self.swipeDone, abs(self.swipeTravel) > 60 {
                    self.swipeDone = true
                    self.swipeTravel < 0 ? self.next() : self.previous()
                }
                return true                                  // a sideways swipe over the bar is ours
            }
            return consumed ? nil : event
        }
    }

    // MARK: - loading

    /// Starts song `i` of the queue; nil is the end of the queue (repeat off): stop on the last song.
    private func go(to i: Int?) {
        guard let i else {
            player.pause(); isPlaying = false; seek(to: 0)
            return
        }
        order.move(to: i)
        startCurrent()
    }

    private func startCurrent() {
        guard let track = current else { return }
        fallbacksTried = 0
        freshRetried = []
        load(downloads.file(for: track)?.listing ?? track.best)      // a downloaded copy plays from the file
        report("play", track, at: 0)
        announceNext()
    }

    private func load(_ listing: Listing, fresh: Bool = false) {
        position = 0
        isBuffering = true                                        // the spinner, until audio arrives
        playingListing = listing
        let file = fresh ? nil : downloads.localURL(for: listing)
        playingFile = file != nil
        // a downloaded copy plays from its file; any other, through the server (which redirects to the audio file)
        let item = AVPlayerItem(url: file ?? API.playURL(listing, fresh: fresh))
        // no time-stretching: the default algorithm processed every sample to allow speed changes we never make
        // (MEMixerChannel::TimePitch, a steady share of the audio thread, profiled 7 Oct). Varispeed at 1x is a pass-through
        item.audioTimePitchAlgorithm = .varispeed
        // @Sendable: KVO calls this on whatever thread changed the status, not necessarily the main one
        statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.statusChanged(status) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        publish()
    }

    /// A copy would not play (MUS-1, rule 7). The server is asked for a fresh URL of the failed copy: that fixes
    /// its cache for next time, and its answer says WHY the copy failed, which the message then tells you.
    private func statusChanged(_ status: AVPlayerItem.Status) {
        if status == .readyToPlay { failuresInARow = 0 }         // this song loads: the run of failures is over
        guard status == .failed, let track = current, let failed = playingListing else { return }
        let others = track.listings.filter { $0.key != track.best.key }

        // another copy exists: switch to it at once, then say why the first one failed
        if fallbacksTried < others.count {
            let next = others[fallbacksTried]
            fallbacksTried += 1
            load(next)
            Task {
                let answer = await API.refresh(failed)
                guard current?.id == track.id else { return }                 // you have moved on: say nothing
                // "another JioSaavn copy" when both are on one source: "the JioSaavn copy" read as a contradiction (6 Oct)
                let which = next.source == failed.source ? "another \(next.sourceName) copy" : "the \(next.sourceName) copy"
                show("\(Self.reason(answer, failed)) Playing \(which).", seconds: 6)
            }
            return
        }

        // the only copy: ask for a fresh URL first; play it if one comes back, otherwise say why not
        if track.listings.count == 1, !freshRetried.contains(failed.key) {
            freshRetried.insert(failed.key)
            isBuffering = true
            Task {
                let answer = await API.refresh(failed)
                guard current?.id == track.id, playingListing?.key == failed.key else { return }
                if answer?.status == 307 { load(failed) } else { giveUp(track, because: Self.reason(answer, failed)) }
            }
            return
        }

        Task { await API.refresh(failed) }                                       // still fix the cache for next time
        giveUp(track, because: nil)
    }

    private func giveUp(_ track: Track, because reason: String?) {
        isBuffering = false
        failuresInARow += 1
        // three songs in a row would not play: something is wrong for all of them (no internet, the server gone, a
        // source blocking us). Stop and say so, instead of trying the whole queue: with no internet it cycled (7 Oct)
        if failuresInARow >= 3 || !Connectivity.shared.online {
            let why = !Connectivity.shared.online ? "No internet." : (reason ?? "")
            player.pause(); isPlaying = false
            failuresInARow = 0
            show("Stopped: \(why.isEmpty ? "3 songs in a row couldn't play." : why) Press play to try again.", seconds: 10)
            if reason == "The server didn't answer." { Connectivity.shared.serverDidNotAnswer() }
            publish()
            return
        }
        show("Couldn't play “\(track.title)”." + (reason.map { " " + $0 } ?? ""), seconds: 6)
        // repeat on and nothing in the queue plays: one full round of failures, then stop instead of looping forever
        go(to: failuresInARow >= queue.count ? nil : order.indexAfterNext())
    }

    /// Why a copy failed, from the server's answer to the fresh request, as a sentence.
    private static func reason(_ answer: (status: Int, detail: String?)?, _ listing: Listing) -> String {
        switch answer?.status {
        case 502?: "\(listing.sourceName) is unavailable right now."
        case 404?: "That \(listing.sourceName) copy is gone."          // one copy (listing), not the whole source
        case 307?: "The \(listing.sourceName) link had expired."
        case nil: "The server didn't answer."
        default: "The \(listing.sourceName) copy didn't load."
        }
    }

    /// A message above the player bar for a few seconds (a newer one replaces it).
    private func show(_ message: String, seconds: Double = 4) {
        errorMessage = message
        problems += 1
        messageTimer?.cancel()
        messageTimer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { errorMessage = nil }
        }
    }

    /// Playing, waiting for data, or paused, as AVPlayer reports it (on change only). It re-anchors `position`, so
    /// the timeline restarts from the right place after a stall; and it ends "buffering" (the spinners), which the
    /// old twice-a-second tick only cleared while playing: paused before audio arrived, a spinner kept spinning.
    private func controlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            // not the failure count: AVPlayer says "playing" as soon as play() is called, before a broken song fails,
            // so resetting it here meant 3 failures in a row never added up (7 Oct). A song that loads resets it
            isBuffering = false
        case .waitingToPlayAtSpecifiedRate:
            if isPlaying { isBuffering = true }
        case .paused:
            isBuffering = false
        @unknown default:
            break
        }
        position = livePosition
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard item === player.currentItem, let track = current else { return }
        report("finish", track, at: track.duration)
        let after = order.indexAfterEnd()
        if after == order.index {                       // repeat one: the same song again, without reloading it
            seek(to: 0)
            player.play()
            isPlaying = true
            report("play", track, at: 0)
            publish()
        } else {
            go(to: after)
        }
    }

    // MARK: - taste data (events)

    private func reportSkipIfNeeded() {
        let now = livePosition
        guard let track = current, now > 0 || isPlaying else { return }
        // finishing is reported by itemEnded; leaving any earlier is a skip, and WHEN matters
        if now < Double(track.duration) - 3 { report("skip", track, at: Int(now)) }
    }

    private func report(_ type: String, _ track: Track, at second: Int) {
        let listings = track.listings
        Task {
            try? await API.event(listings, type: type, position: second)
            if type == "play" { await library.refreshRecent() }     // keeps "Recently Played" current; nothing else changed
        }
    }

    // MARK: - Now Playing (Control Center, media keys) + Discord

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            presence.update(nil, isPlaying: false, position: 0)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: livePosition,   // the system counts on from here by itself
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.best.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let art = artwork[track.id] { info[MPMediaItemPropertyArtwork] = art } else { loadArtwork(track) }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        presence.update(track, isPlaying: isPlaying, position: livePosition, playlist: playingFrom)
    }

    private func loadArtwork(_ track: Track) {
        guard let url = track.image else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            // @Sendable: macOS asks for the image from its own background queue (this crashed on 5 Oct
            // when the closure was inferred main-thread-only)
            artwork[track.id] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            if current?.id == track.id { publish() }
        }
    }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        // @Sendable: media-key handlers are not guaranteed to run on the main thread; each hops there with Task
        commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        commands.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }; return .success
        }
        commands.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }; return .success
        }
        commands.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        commands.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }
}
