import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Playback: the queue, AVPlayer, media keys and Control Center (Now Playing), play/skip/finish
/// events for your taste data, Discord presence, and falling back to another copy when one fails.
@Observable
final class Player {
    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var isBuffering = false
    private(set) var errorMessage: String?
    var showNowPlaying = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var duration: Double { Double(current?.duration ?? 0) }
    var upNext: [Track] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let presence: Presence
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var fallbacksTried = 0
    @ObservationIgnored private var artwork: [String: MPMediaItemArtwork] = [:]

    init(library: LibraryStore, presence: Presence) {
        self.library = library
        self.presence = presence
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        }
        setUpRemoteCommands()
    }

    // MARK: - controls

    func play(_ tracks: [Track], startAt i: Int = 0) {
        guard tracks.indices.contains(i) else { return }
        reportSkipIfNeeded()
        queue = tracks
        index = i
        startCurrent()
    }

    func playNext(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.insert(track, at: index + 1)
    }

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
        publish()
    }

    func next() {
        guard current != nil else { return }
        reportSkipIfNeeded()
        advance(by: 1)
    }

    func previous() {
        if position > 3 { seek(to: 0); return }     // like every player: first press restarts the song
        reportSkipIfNeeded()
        advance(by: -1)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        reportSkipIfNeeded()
        index = i
        startCurrent()
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        publish()
    }

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

    // MARK: - loading

    private func advance(by step: Int) {
        let target = index + step
        guard queue.indices.contains(target) else {
            player.pause(); isPlaying = false; seek(to: 0)   // end of the queue: stop on the last song
            return
        }
        index = target
        startCurrent()
    }

    private func startCurrent() {
        guard let track = current else { return }
        fallbacksTried = 0
        load(track.best)
        report("play", track, at: 0)
    }

    private func load(_ listing: Listing) {
        position = 0
        isBuffering = true
        errorMessage = nil
        let item = AVPlayerItem(url: API.playURL(listing))      // the server redirects to the audio file
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.statusChanged(status) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        publish()
    }

    private func statusChanged(_ status: AVPlayerItem.Status) {
        guard status == .failed, let track = current else { return }
        // the best copy would not play: try the song's other copies before giving up (MUS-3's fallbacks)
        let others = track.listings.filter { $0.key != track.best.key }
        if fallbacksTried < others.count {
            let listing = others[fallbacksTried]
            fallbacksTried += 1
            load(listing)
        } else {
            errorMessage = "Couldn't play “\(track.title)”."
            isBuffering = false
            advance(by: 1)
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = seconds
        if player.timeControlStatus == .playing { isBuffering = false }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard item === player.currentItem, let track = current else { return }
        report("finish", track, at: track.duration)
        advance(by: 1)
    }

    // MARK: - taste data (MUS-4 events)

    private func reportSkipIfNeeded() {
        guard let track = current, position > 0 || isPlaying else { return }
        // finishing is reported by itemEnded; leaving any earlier is a skip, and WHEN matters
        if position < Double(track.duration) - 3 { report("skip", track, at: Int(position)) }
    }

    private func report(_ type: String, _ track: Track, at second: Int) {
        let listings = track.listings
        Task {
            try? await API.event(listings, type: type, position: second)
            if type == "play" { await library.refresh() }      // keeps "Recently Played" current
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
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.best.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let art = artwork[track.id] { info[MPMediaItemPropertyArtwork] = art } else { loadArtwork(track) }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        presence.update(track, isPlaying: isPlaying, position: position)
    }

    private func loadArtwork(_ track: Track) {
        guard let url = track.image else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            artwork[track.id] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            if current?.id == track.id { publish() }
        }
    }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }; return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }; return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }
}
