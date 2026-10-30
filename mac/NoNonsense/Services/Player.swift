import Foundation
#if os(macOS)
import AppKit
#endif
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
    /// How long the song playing is: the copy playing, as it will play, once it has loaded (its listed length cuts
    /// it short when the audio runs on past it: see `load`); until then its listed length.
    var duration: Double { audioLength ?? Double(playingListing?.duration ?? current?.duration ?? 0) }
    /// The playing copy's length in seconds, as it will play: nil until it has loaded (and for audio with no fixed length)
    private(set) var audioLength: Double?
    var upNext: [Track] { order.upNext }
    var nextTrack: Track? { order.nextTrack }

    /// What plays next, for every view that shows it: the room's queue in a jam, else this Mac's Up Next, each song with
    /// what playing it does. One answer for all of them: Home's card read this Mac's queue in a jam, and showed nothing
    /// while Now Playing showed the room's (24 Oct).
    var nextSongs: [NextSong] {
        if let room = JamSession.shared.state {
            return room.queue.map { entry in
                NextSong(id: entry.id.uuidString, track: Track(best: entry.listing, listings: [entry.listing], choosingVersion: false)) {
                    JamSession.shared.jump(to: entry)
                }
            }
        }
        let from = index + 1
        return order.upNext.enumerated().map { i, track in
            NextSong(id: "\(from + i)|\(track.id)", track: track) { [weak self] in self?.jump(to: from + i) }
        }
    }
    /// The playlist the queue came from ("Gym"), for Now Playing and Discord; nil for other queues.
    var playingFrom: String? {
        guard let source = order.origin, source.hasPrefix("playlist:"),
              let id = UUID(uuidString: String(source.dropFirst("playlist:".count))) else { return nil }
        return library.playlists.first { $0.id == id }?.name ?? library.details[id]?.name
    }

    /// A queue player, so the next song can wait behind the playing one (gapless); otherwise it holds one item. During a
    /// crossfade the song fading out plays on on the last one (`outgoing`) while this is a new one, with the next song.
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var outgoing: AVQueuePlayer?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let downloads: DownloadStore
    /// True while the playing copy is a downloaded file (no server, no internet needed).
    private(set) var playingFile = false
    /// The playing file's own codec and bitrate ("AAC 129 kbps"), read once it is ready; nil until then. The listing's
    /// `quality` is what its source usually serves, this is what is playing.
    private(set) var playingQuality: String?
    @ObservationIgnored private let presence: Presence
    /// AVPlayer's own playing / waiting / paused state, observed when it changes (no timer: see `position`)
    @ObservationIgnored private var controlStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var cacheObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var fallbacksTried = 0
    @ObservationIgnored private var failuresInARow = 0     // with repeat on, a queue where nothing plays must stop somewhere
    /// Shuffle on or off for the next queue too, and repeat: both remembered between launches, as in Apple Music.
    @ObservationIgnored private var shufflePreferred = UserDefaults.standard.bool(forKey: "shuffle")
    private(set) var playingListing: Listing?                         // the copy AVPlayer is playing right now
    private(set) var volume: Float = Player.savedVolume()   // 0...1: the slider's place, remembered; AVPlayer gets `gain`
    private(set) var isMuted = false
    /// A jam member with Play here off: the room's song follows along without sound. Apart from your own mute.
    private(set) var jamSilent = false
    @ObservationIgnored private var freshRetried: Set<String> = []   // listing keys already retried with serve_fresh
    @ObservationIgnored private var messageTimer: Task<Void, Never>?
    @ObservationIgnored private var artwork: [String: MPMediaItemArtwork] = [:]

    init(library: LibraryStore, presence: Presence, downloads: DownloadStore) {
        self.library = library
        self.downloads = downloads
        self.presence = presence
        setUp(player)
        #if os(macOS)
        SoundChain.shared.volumeChanged(place: Double(volume))
        #endif
        order.repeatMode = UserDefaults.standard.string(forKey: "repeat").flatMap(PlayQueue.Repeat.init(rawValue:)) ?? .off
        // the equalizer switched on or off: the song playing gets its tap, or loses it, at once
        SoundChain.shared.changed = { [weak self] in self?.soundChanged() }
        _ = SoundProfiles.shared                            // each output's equalizer and correction, from launch
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        }
        // the next song's file just came in: it can wait behind this one now (gapless)
        cacheObserver = NotificationCenter.default.addObserver(forName: AudioCache.stored, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueNext() }
        }
        setUpRemoteCommands()
        // a playlist you edit while it plays: the queue follows (PlayQueue.sync ignores other playlists)
        library.playlistChanged = { [weak self] detail in
            self?.syncQueue(source: detail.queueSource, items: zip(detail.keys, detail.tracks).map { (key: $0, track: $1) })
        }
    }

    /// A player as every one is: the active one at launch, and each new one a crossfade starts.
    private func setUp(_ new: AVQueuePlayer) {
        // start as soon as audio arrives, instead of first buffering several seconds (the CDN answers in ~0.26 s)
        new.automaticallyWaitsToMinimizeStalling = false
        new.actionAtItemEnd = .pause                        // as AVPlayer: an ended song stays loaded; `.advance` only while one is queued
        new.volume = Self.gain(volume)
        new.isMuted = isMuted || jamSilent
        // No periodic time observer: it set `position` twice a second and every view reading it redrew, the app's
        // biggest steady cost while playing (7 Oct). `position` now changes only on events; the progress line and
        // times are drawn by Core Animation (PlaybackTimeline), and code that needs the exact time reads livePosition.
        // @Sendable: KVO calls this on whatever thread changed the status (as for the item's status, below)
        controlStatusObservation = new.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] avPlayer, _ in
            let status = avPlayer.timeControlStatus
            Task { @MainActor in self?.controlStatusChanged(status) }
        }
    }

    // MARK: - controls

    /// Plays `tracks` from song `i`. With shuffle on, song `i` plays first and the rest are shuffled.
    /// `keys` name the entries (a playlist's item ids) and `source` says where they came from ("playlist:<id>"),
    /// so later edits to that playlist reach this queue (`syncQueue`).
    func play(_ tracks: [Track], startAt i: Int = 0, keys: [String]? = nil, source: String? = nil) {
        guard tracks.indices.contains(i) else { return }
        if let jam { jam.add([tracks[i]], .now); return }   // in a jam: this song plays for the room at once, not the list
        reportSkipIfNeeded()
        radioAskedAfter = nil                             // a new queue: Autoplay may ask for it, whatever came before
        order.load(tracks, startAt: i, keys: keys, source: source, shuffled: shufflePreferred)
        startCurrent()
    }

    /// The Play button on a list: in your order (shuffle off), from the first song.
    func playInOrder(_ tracks: [Track], keys: [String]? = nil, source: String? = nil) {
        if let jam { jam.add(Array(tracks.prefix(50)), .now); return }   // a list's Play in a jam: the list plays for the room
        setShufflePreference(false)
        play(tracks, startAt: 0, keys: keys, source: source)
    }

    /// The Shuffle button on a list: shuffle on, then a random song first and the rest spread out.
    func shufflePlay(_ tracks: [Track], keys: [String]? = nil, source: String? = nil) {
        guard !tracks.isEmpty else { return }
        if let jam { jam.add(Array(tracks.shuffled().prefix(50)), .now); return }
        setShufflePreference(true)
        play(tracks, startAt: Int.random(in: tracks.indices), keys: keys, source: source)
    }

    func playNext(_ track: Track) {
        if let jam { jam.add([track], .next); return }
        guard current != nil else { play([track]); return }
        order.insertNext(track)
        announceNext()
    }

    /// The end of Up Next (Play Next puts it at the start).
    func addToQueue(_ track: Track) {
        if let jam { jam.add([track]); return }
        guard current != nil else { play([track]); return }
        order.append(track)
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

    func moveUpNext(from: Int, to: Int, autoplay: Bool) {
        order.moveUpcoming(from: from, to: to, autoplay: autoplay)
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
        // the next two songs that will stream (a downloaded one plays from its file: nothing to make ready)
        var probe = order, next: [Listing] = [], steps = 0
        while next.count < 2, steps < 10, let n = probe.indexAfterNext(), n != order.index {
            let track = probe.tracks[n]
            if downloads.file(for: track) == nil { next.append(track.best) }
            probe.move(to: n)
            steps += 1
        }
        Prefetcher.shared.queueChanged(next, playing: playingListing)
        refillIfNeeded()
        queueNext()
    }

    // MARK: - autoplay

    /// Autoplay was switched on: the queue may need songs now.
    func upNextChanged() { refillIfNeeded() }

    /// Up Next › Autoplay (on by default): when two songs or fewer are left, songs like the last one you chose are added.
    static var autoplay: Bool { UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true }
    /// Settings › Playback › Autoplay (on by default): the server leaves out your last 50 played songs, skipped ones too.
    static var autoplaySkipsRecent: Bool { UserDefaults.standard.object(forKey: "autoplaySkipsRecent") as? Bool ?? true }
    /// The queue's last song when Autoplay last had an answer: one request per last song, so a station with nothing new
    /// is not asked again and again.
    @ObservationIgnored private var radioAskedAfter: String?
    @ObservationIgnored private var radioAsking = false

    /// Asks the server's radio (POST /radio) for songs like the last one you chose. Not in a jam (the room decides), not
    /// with repeat on (the queue never runs out).
    private func refillIfNeeded() {
        guard Self.autoplay, jam == nil, order.repeatMode == .off, upNext.count <= 2, let last = queue.last,
              radioAskedAfter != last.best.key, !radioAsking else { return }
        // every refill asks for the station of the last song you chose, which the server reads on past the songs it
        // gave. Seeded from the one before's last song, refills drifted: 98% of a first refill was the chosen song's
        // station, then 32%, 14%, 13% (Do I Wanna Know? to Fifth Harmony in three, 17 Oct). A video of the song first:
        // the server starts YouTube Music's station from one, and a JioSaavn copy needs it found first (#24)
        let chosen = order.autoplaySeed ?? last
        let seed = ["ytmusic", "youtube", "jiosaavn"].lazy.compactMap { source in chosen.listings.first { $0.source == source } }.first
            ?? chosen.best
        // every song in the queue, played ones too, each copy once: the station read on must not give them again (the
        // server also leaves out what was played lately, unless that is switched off). As on Windows and Android
        var seen = Set<String>()
        let exclude = queue.flatMap(\.listings).filter { seen.insert($0.key).inserted }
        radioAsking = true
        Task {
            let songs = try? await API.radio(seed: seed, exclude: exclude, skipRecent: Self.autoplaySkipsRecent)
            radioAsking = false
            // another song was played meanwhile: the answer is not for its queue, and this request kept that queue from
            // asking, so it is asked for now (its Up Next stayed empty, and the music stopped after it)
            guard queue.last?.id == last.id else { refillIfNeeded(); return }
            guard let songs, !songs.isEmpty else { return }
            // marked only after an answer: a failure (offline, a busy server) is asked again at the next song
            radioAskedAfter = last.best.key
            order.appendAutoplay(songs.map(Track.init))
            announceNext()
            publish()
        }
    }

    private func setShufflePreference(_ on: Bool) {
        shufflePreferred = on
        UserDefaults.standard.set(on, forKey: "shuffle")
    }

    #if DEBUG
    /// Self-tests: whether the loaded copy's audio goes through an equalizer tap
    var itemHasTapForTests: Bool { player.currentItem?.audioMix != nil }

    /// Self-tests: the loaded copy's state, as AVPlayer sees it
    var itemStatusForTests: String {
        switch player.currentItem?.status { case .readyToPlay: "ready"; case .failed: "failed"; case .unknown: "loading"; default: "none" }
    }
    #endif

    func togglePlayPause() {
        if let jam { jam.setPlaying(!isPlaying); return }          // what the button shows, as on Windows (docs/jam.md)
        guard current != nil else { return }
        // after "Stopped: … Press play to try again" the loaded copy is the one that failed: play() on it did nothing
        // (isPlaying on, no sound). Play means: try this song again, from its first copy
        if !isPlaying, player.currentItem?.status == .failed { startCurrent(); return }
        // the same when the server gave it no address (nothing loaded): play() on no item did nothing
        if !isPlaying, !resolving, player.currentItem == nil { startCurrent(); return }
        if isPlaying { endFade() }                                  // a pause mid-crossfade: the song going out stops
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
        refreshBuffering()
        position = livePosition                                     // the clock's new starting point
        publish()
    }

    func next() {
        if let jam { jam.skip(); return }
        guard current != nil else { return }
        nextPresses += 1
        let after = order.indexAfterNext()
        if after != nil { reportSkipIfNeeded() }          // ⏭ on the last song ends the queue; nothing was skipped
        go(to: after)
    }

    func previous() {
        if let jam { jam.previous(); return }                      // the room's last song, or this one again: the server decides
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

    /// 0...1: the slider's place. The app's own volume, under the Mac's; remembered between launches.
    func setVolume(_ level: Float) {
        volume = min(1, max(0, level))
        player.volume = Self.gain(volume)
        outgoing?.volume = player.volume
        SoundChain.shared.volumeChanged(place: Double(volume))     // loudness compensation follows the volume
        if isMuted { isMuted = false; player.isMuted = jamSilent; outgoing?.isMuted = jamSilent }
        // saved once the slider settles, not on every pointer move of a drag
        volumeSave?.cancel()
        volumeSave = Task { [volume] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { UserDefaults.standard.set(volume, forKey: "volume") }
        }
    }
    @ObservationIgnored private var volumeSave: Task<Void, Never>?

    /// The gain for a slider place: its place to the power 5/3. AVPlayer's volume is linear, but loudness is heard in
    /// ratios: +10 dB sounds about twice as loud, so for the slider to change the loudness evenly, half way must sound half
    /// as loud: -10 dB, a quarter -20 dB, a tenth -33 dB. A straight line put a quarter of the way at -12 dB, barely quieter
    /// than full; the cube that followed (13 to 29 Oct) put half at -18 dB and a quarter at -36 dB, which nothing below
    /// half could be heard through.
    nonisolated static let volumeCurve = 5.0 / 3.0
    nonisolated static func gain(_ place: Float) -> Float { Float(pow(Double(place), volumeCurve)) }

    /// The remembered slider place. Until 13 Oct the place was the gain itself: a place saved then is moved once to the
    /// place with that gain, so the music plays exactly as loud as before the update.
    nonisolated private static func savedVolume() -> Float {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: "volume") as? Float else { return 1 }
        if defaults.bool(forKey: "volumeIsPlace") { return saved }
        let place = Float(pow(Double(saved), 1 / volumeCurve))
        defaults.set(place, forKey: "volume")
        defaults.set(true, forKey: "volumeIsPlace")
        return place
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted || jamSilent
        outgoing?.isMuted = player.isMuted
    }

    func jamSetSilent(_ silent: Bool) {
        guard silent != jamSilent else { return }
        jamSilent = silent
        player.isMuted = isMuted || silent
        outgoing?.isMuted = player.isMuted
    }

    /// Where the song is right now, read from the audio player itself: `position` changes only on events (play,
    /// pause, seek, a stall), so it is the time of the last event. Not observed: read it when you need it.
    var livePosition: Double {
        let now = player.currentTime().seconds
        return now.isFinite ? now : position
    }

    /// ← and →: a few seconds back or on, within the song (not past its end: that would skip it).
    func seek(by seconds: Double) {
        seek(to: min(max(0, livePosition + seconds), max(0, duration - 1)))
    }

    func seek(to seconds: Double) {
        if let jam, !jamApplying { jam.seek(to: seconds); return }
        position = seconds
        seeks += 1
        endFade()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        if let plan = endPlan, seconds >= plan.at { moveEnd(of: plan.item) }     // a boundary is only crossed by playing
        publish()
    }
    /// Counts every seek. `position` alone can miss one: ⏮ in the middle of a song seeks to 0, and `position` may
    /// still be 0 from the song's start (it changes only on events), so nothing would change. Lyrics follow this.
    private(set) var seeks = 0

    #if os(macOS)
    /// Space plays/pauses anywhere in the window, ← → seek 5 s, L likes or unlikes the song, M mutes or unmutes, and /
    /// puts the keyboard in the command bar, except while typing in a text field. And while typing, ⌘← ⌘→ ⌘↑ ⌘↓
    /// move the cursor, as in any text field: menus answer their shortcuts before the field sees the key, so the
    /// Controls menu's Next, Previous and Volume took them (audit, 7 Oct). A monitor sees the key before the menus do.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // decided on the main actor as a plain Bool (an NSEvent cannot cross isolation); consumed outside
            let handled = MainActor.assumeIsolated { self?.heard(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Whether a key down is the window's own (true: nothing else gets it). The key monitor's decision; self-tests ask it
    /// directly, as the events they make do not pass the app's monitors.
    func heard(_ event: NSEvent) -> Bool {
        // arrow keys also carry the numeric-pad and function flags: only ⌘ itself counts
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let focused = (event.window ?? NSApp.keyWindow)?.firstResponder       // a text field's editor while typing
        if (123...126).contains(event.keyCode), modifiers == .command {
            guard let field = focused as? NSTextView else { return false }
            field.keyDown(with: event)                      // the field's own ⌘-arrow: start or end of line or text
            return true
        }
        // the rest never while typing: the key is the field's (a space typed into Search once paused the song)
        guard !(focused is NSText) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        // / : the command bar, where it is on screen (also where / is a shifted key, as ⇧7 on a German keyboard)
        if key == "/", modifiers.subtracting(.shift).isEmpty, CommandBarState.shared.onScreen, !showNowPlaying {
            if !event.isARepeat { CommandBarState.shared.summon() }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 123, 124:                                      // ← → : 5 s back or on (as on YouTube), not on a focused slider
            guard current != nil, !(focused is NSSlider) else { return false }
            seek(by: event.keyCode == 124 ? 5 : -5)
            return true
        case 49:                                            // Space
            guard current != nil else { return false }
            togglePlayPause()
            return true
        default:
            break
        }
        // L and M once per press: held down, they neither repeat nor beep
        switch key {
        case "l":
            guard let song = current else { return false }
            if !event.isARepeat { Task { await library.toggleLike(song) } }
            return true
        case "m":
            if !event.isARepeat { toggleMute() }
            return true
        default:
            return false
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
                // the bar is hidden under Now Playing: a sideways swipe there skipped songs (audit, 7 Oct)
                guard !self.showNowPlaying, self.barFrame.contains(point) else { return false }
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
    #endif

    // MARK: - loading

    /// The session ended (signed out): nothing of that account keeps playing, stays queued, or shows in Control Center
    /// and Discord. Shuffle and repeat are this Mac's settings, so they stay.
    func stop() {
        radioAskedAfter = nil
        loads += 1                                                // an address still on its way is dropped
        resolving = false
        player.pause()
        unqueue()
        endFade()
        cancelFadePlan()
        player.replaceCurrentItem(with: nil)
        let repeatMode = order.repeatMode
        order = PlayQueue()
        order.repeatMode = repeatMode
        isPlaying = false
        isBuffering = false
        playingListing = nil
        playingFile = false
        audioLength = nil
        position = 0
        showNowPlaying = false
        errorMessage = nil
        Prefetcher.shared.queueChanged([])
        publish()
    }

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
        resumeAt = nil
        resumeFromRoom = false
        fallbacksTried = 0
        freshRetried = []
        let first = downloads.file(for: track)?.listing ?? track.best   // a downloaded copy plays from the file
        firstCopy = first.key
        load(first)
        playReported = false                                      // reported when it is ready to play (statusChanged)
        announceNext()
    }

    /// Whether this song's "play" has been reported (once, when it first becomes ready).
    @ObservationIgnored private var playReported = true

    /// The copy the song started with: a downloaded one need not be `best`. The fallbacks are the others.
    @ObservationIgnored private var firstCopy: String?

    /// `fromFile: false` streams even a downloaded copy (its file would not play). `start: false` loads it paused: a copy
    /// that fails while you have paused hands over to the next one without starting it (it always started, 8 Oct).
    private func load(_ listing: Listing, fromFile: Bool = true, start: Bool = true) {
        unqueue()                                                 // first: a queue player replacing its item would go into it
        switchObservation = nil
        endFade()
        cancelFadePlan()
        cancelEndPlan()
        position = 0
        playingQuality = nil
        audioLength = nil                                         // the listed length, until this copy says its own
        isBuffering = true                                        // the spinner, until audio arrives
        playingListing = listing
        loads += 1
        if start { isPlaying = true }
        // a downloaded copy plays from its file
        if let file = fromFile ? downloads.localURL(for: listing) : nil {
            resolving = false                                     // an address still on its way for the last copy no longer matters
            playingFile = true
            attach(AVPlayerItem(url: file), for: listing)
            return
        }
        playingFile = false
        // any other through the server, which needs the token; the player is given only the audio's own address
        // (API.audioURL, handoff 3.2, 8 Oct). The last song stops now, not when this one's address arrives
        player.replaceCurrentItem(with: nil)
        resolving = true
        refreshBuffering()
        publish()
        let mine = loads
        Task {
            // played before: its file, from this Mac's cache; no link and no network (TICKETS 0b, 8 Oct)
            if let cached = await AudioCache.shared.file(for: listing.key) {
                guard mine == loads else { return }
                resolving = false
                attach(AVPlayerItem(url: cached), for: listing)
                return
            }
            let url: URL
            do {
                url = try await API.audioURL(listing)
            } catch {
                guard mine == loads else { return }               // another song or copy since: this one no longer matters
                resolving = false
                if let track = current { copyFailed(listing, of: track) }
                return
            }
            guard mine == loads else { return }
            resolving = false
            // through the loader: bounded ranges (YouTube sends open-ended ones at playback speed), and the whole file
            // kept in the cache once it is in (TICKETS 0a, 0b, 8 Oct)
            var direct = false
            #if DEBUG
            direct = ProcessInfo.processInfo.environment["NN_NO_LOADER"] != nil      // the latency test's "before"
            #endif
            await AudioDownloads.shared.play(listing.key)              // this song's fetch is never the one stopped for room
            attach(direct ? AVPlayerItem(url: url) : AVPlayerItem(asset: BoundedRangeLoader.shared.asset(for: url, key: listing.key)), for: listing)
        }
    }

    /// Now Playing's source menu: the song now playing switches to another of its copies, from the same moment.
    func switchCopy(to listing: Listing) {
        guard current != nil, listing.key != playingListing?.key else { return }
        let at = livePosition
        fallbacksTried = 0
        freshRetried = []
        firstCopy = listing.key
        resumeAt = at
        load(listing, start: isPlaying)
    }

    /// Where a copy chosen mid-song starts, once it is ready (`switchCopy`).
    @ObservationIgnored private var resumeAt: Double?
    /// The song loading is the room's (jamLoad): it starts at the room's playhead once ready, not where the room was
    /// when the load began.
    @ObservationIgnored private var resumeFromRoom = false

    // MARK: - jam (JamSession)

    /// In a jam: the room decides what plays, and the transport sends it commands (JamSession). nil otherwise.
    @ObservationIgnored weak var jam: JamSession?
    /// True while the room's state is applied: those seeks are the room's own, not commands to send back.
    @ObservationIgnored private var jamApplying = false

    /// The host's player: the room's current song, from the room's playhead.
    func jamLoad(_ track: Track, at seconds: Double, playing: Bool) {
        reportSkipIfNeeded()
        order.load([track], startAt: 0, keys: nil, source: "jam", shuffled: false)
        startCurrent()
        resumeAt = seconds
        resumeFromRoom = true
        if !playing { jamFollow(playing: false) }
    }

    /// The host's player: playing or paused as the room is.
    func jamFollow(playing: Bool) {
        guard isPlaying != playing else { return }
        playing ? player.play() : player.pause()
        isPlaying = playing
        refreshBuffering()
        position = livePosition
        publish()
    }

    /// The host's player: the room's playhead after someone seeked.
    func jamFollow(seek seconds: Double) {
        jamApplying = true
        seek(to: seconds)
        jamApplying = false
    }

    /// Counts loads: an address that arrives after another load began (⏭ pressed meanwhile) is dropped.
    @ObservationIgnored private var loads = 0
    /// True while /play is asked for the copy's address: the spinner shows (`refreshBuffering`).
    @ObservationIgnored private var resolving = false

    private func attach(_ item: AVPlayerItem, for listing: Listing) {
        prepare(item, for: listing)
        observe(item)
        player.replaceCurrentItem(with: item)
        // you may have paused or played while its address was on its way: as you left it
        if isPlaying { player.play() }
        refreshBuffering()
        publish()
    }

    /// Set up as every song is, playing now or queued.
    private func prepare(_ item: AVPlayerItem, for listing: Listing, fadeIn: Double? = nil) {
        // no time-stretching: the default algorithm processed every sample to allow speed changes we never make
        // (MEMixerChannel::TimePitch, a steady share of the audio thread, profiled 7 Oct). Varispeed at 1x is a pass-through
        item.audioTimePitchAlgorithm = .varispeed
        // the song ends at its listed length (+1 s: listings count whole seconds). Some YouTube audio runs on in silence:
        // Redbone's listing said 1:42, its audio went on, silent, past 1:48, and the bar sat at -0:00 (7 Oct). AVPlayer
        // stops here and posts the usual "played to the end", so the next song starts as after any other
        if listing.duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: Double(listing.duration) + 1, preferredTimescale: 600)
        }
        SoundChain.shared.apply(to: item, key: listing.key, fadeIn: fadeIn)   // its tap when any of the chain is on; none when off
    }

    private func observe(_ item: AVPlayerItem) {
        // @Sendable: KVO calls this on whatever thread changed the status, not necessarily the main one
        statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
            let status = item.status, which = ObjectIdentifier(item)
            Task { @MainActor in self?.statusChanged(status, of: which) }
        }
    }

    /// A bitrate the file's header can vouch for. The rate is bytes over the file's own duration, and some YouTube files
    /// state double their length in the header (checked 29 Oct on 150 of them: decoded 128.3 s where the header said
    /// 256.5), which halves it. The listing's duration, from the source, says which: equal, the reading stands; double,
    /// it is doubled; anything else, the header cannot be trusted and nil leaves the listing's usual label.
    nonisolated static func trustedKbps(_ kbps: Double, header: Double, listed: Double) -> Double? {
        guard header.isFinite, listed > 0 else { return nil }
        let ratio = header / listed
        if abs(ratio - 2) < 0.1 { return kbps * 2 }
        return abs(ratio - 1) <= 0.1 ? kbps : nil
    }

    /// The codec and bitrate of the file playing, from its audio track.
    private func measureQuality(of item: AVPlayerItem) {
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  let rate = try? await track.load(.estimatedDataRate), rate > 0,
                  let format = try? await track.load(.formatDescriptions).first else { return }
            let codec = switch CMFormatDescriptionGetMediaSubType(format) {
            case kAudioFormatMPEG4AAC: "AAC"
            case kAudioFormatOpus: "Opus"
            case kAudioFormatMPEGLayer3: "MP3"
            case kAudioFormatFLAC: "FLAC"
            case kAudioFormatAppleLossless: "Lossless"
            default: "Audio"
            }
            guard item === player.currentItem else { return }          // another song since
            guard let kbps = Self.trustedKbps(Double(rate) / 1000, header: item.duration.seconds, listed: Double(playingListing?.duration ?? 0))
            else { return }
            playingQuality = "\(codec) \(Int(kbps.rounded())) kbps"
        }
    }

    // MARK: - gapless

    /// Settings › Playback › Gapless playback (28 Oct; off by default). The next song, when its file is on this
    /// Mac (the cache, where it was fetched while this one played, or Downloads), waits behind the playing one in the
    /// queue player, which goes straight into it: no load at the change. Measured 8 Oct, a song from a file took ~0.15 s
    /// to sound: that was the gap. A song that would stream, repeat one and a jam change songs as before.
    static var gapless: Bool { UserDefaults.standard.bool(forKey: "gapless") }

    /// The song queued behind the playing one: its item and copy, its place in the queue, and the item it follows.
    private struct Queued { let item: AVPlayerItem; let listing: Listing; let index: Int; weak var after: AVPlayerItem? }
    @ObservationIgnored private var queued: Queued?
    /// Between the end of a song and the queue player making the queued one current (their order is not documented).
    @ObservationIgnored private var switchObservation: NSKeyValueObservation?

    /// The song that plays when this one ends, and the copy it would start with, when gapless can play it.
    private func gaplessNext() -> (index: Int, listing: Listing)? { Self.gapless ? nextSong() : nil }

    /// The song that plays when this one ends, and the copy it would start with; none in a jam or on repeat one.
    private func nextSong() -> (index: Int, listing: Listing)? {
        guard jam == nil, let i = order.indexAfterEnd(), i != order.index, order.tracks.indices.contains(i) else { return nil }
        let track = order.tracks[i]
        return (i, downloads.file(for: track)?.listing ?? track.best)
    }

    /// The next song's file, if it is on this Mac (Downloads or the cache).
    private func localFile(for listing: Listing) async -> URL? {
        if let downloaded = downloads.localURL(for: listing) { return downloaded }
        return await AudioCache.shared.file(for: listing.key)
    }

    /// Queues the next song if its file is here and the playing one has loaded; a queued song that is no longer next
    /// is taken out first.
    private func queueNext() {
        let wanted = gaplessNext()
        if let queued, let wanted, queued.index == wanted.index, queued.listing.key == wanted.listing.key,
           queued.after === player.currentItem { return }
        unqueue()
        guard let wanted, switchObservation == nil, let playing = player.currentItem, playing.status == .readyToPlay else { return }
        let mine = loads
        Task {
            let file = await localFile(for: wanted.listing)
            guard let file, mine == loads, queued == nil, player.currentItem === playing,
                  let now = gaplessNext(), now.index == wanted.index, now.listing.key == wanted.listing.key else { return }
            let item = AVPlayerItem(url: file)
            prepare(item, for: wanted.listing)
            guard player.canInsert(item, after: playing) else { return }
            player.insert(item, after: playing)
            player.actionAtItemEnd = .advance
            queued = Queued(item: item, listing: wanted.listing, index: wanted.index, after: playing)
        }
    }

    /// Settings › Playback: switched on or off.
    func gaplessChanged() {
        unqueue()
        queueNext()
        if let item = player.currentItem, item.status == .readyToPlay { planFade(for: item) }   // the handover on or off
    }

    #if DEBUG
    /// Self-tests: the copy queued behind the playing song.
    var queuedKeyForTests: String? { queued?.listing.key }
    /// Self-tests: what the queue player itself is doing, for a failure's message.
    var playerStateForTests: String {
        let item = (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "none"
        return "item \(item), \(player.items().count) in its queue, rate \(player.rate), status \(player.timeControlStatus.rawValue), "
            + "at \(String(format: "%.2f", livePosition)) s, playing \(isPlaying), listing \(playingListing?.title ?? "none")"
    }
    #endif

    private func unqueue() {
        guard let queued else { return }
        self.queued = nil
        player.actionAtItemEnd = .pause
        player.remove(queued.item)
    }

    /// The playing song ended and the queue player went into the queued one: everything a load would do, but the
    /// audio is already playing.
    private func playedOn(into next: Queued) {
        guard let track = current else { return }
        report("finish", track, at: Int(duration))
        queued = nil
        // `.advance` stays until the switch: set back to `.pause` now, when the end notification came before the queue
        // player moved on, it paused on the ended song instead (CI, 28 Oct: no switch, nothing playing)
        moved(to: next.index, playing: next.listing)
        // the rest once the queued song is current: its status, and the song after it queued behind it, not the old one
        let expected = ObjectIdentifier(next.item)
        switchObservation = player.observe(\.currentItem, options: [.initial, .new]) { @Sendable [weak self] player, _ in
            let now = player.currentItem.map(ObjectIdentifier.init)
            Task { @MainActor in self?.switched(to: now, expecting: expected) }
        }
    }

    /// What a load does to the player's state, for a song that is already playing (gapless, crossfade).
    private func moved(to index: Int, playing listing: Listing) {
        order.move(to: index)
        resumeAt = nil
        resumeFromRoom = false
        fallbacksTried = 0
        freshRetried = []
        firstCopy = listing.key
        position = 0
        playingQuality = nil
        audioLength = nil
        playingListing = listing
        playingFile = downloads.localURL(for: listing) != nil
        resolving = false
        loads += 1
        playReported = false
    }

    private func switched(to now: ObjectIdentifier?, expecting expected: ObjectIdentifier) {
        guard now == expected, switchObservation != nil, let item = player.currentItem else { return }
        switchObservation = nil
        player.actionAtItemEnd = .pause                           // until the next song is queued (announceNext)
        observe(item)
        statusChanged(item.status, of: expected)                 // ready already: no change for KVO to report
        announceNext()
        refreshBuffering()
        publish()
    }

    // MARK: - crossfade

    /// Settings › Playback › Crossfade (28 Oct): seconds over which a song fades out as the next fades in; 0 (the
    /// default) is off. The next song starts on a second player `crossfade` seconds before this one ends, both through
    /// the sound chain's taps, which shape the fades (equal power: the two together are as loud as one). Only for a next
    /// song whose file is on this Mac, as gapless; a song shorter than two fades, a jam, repeat one, or a seek into the
    /// last seconds ends as before. Pausing, seeking or skipping mid-fade stops the song going out.
    static var crossfade: Double { UserDefaults.standard.double(forKey: "crossfadeSeconds") }

    /// The boundary observer on the playing song: on the player it was added to, for that item.
    @ObservationIgnored private var fadePlan: (player: AVQueuePlayer, item: ObjectIdentifier, token: Any)?
    @ObservationIgnored private var fadeEnd: Task<Void, Never>?

    /// The end of the song playing, to move up to the file's own (`statusChanged`): the item, where it moves, the observer.
    @ObservationIgnored private var endPlan: (player: AVQueuePlayer, item: ObjectIdentifier, at: Double, token: Any)?

    private func planEnd(for item: AVPlayerItem, listedEnd end: Double) {
        cancelEndPlan()
        let own = item.duration.seconds
        guard end.isFinite, own.isFinite, own > 3, own <= end else { return }
        let at = 1.0
        let id = ObjectIdentifier(item)
        let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: at, preferredTimescale: 600))], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.moveEnd(of: id) }
        }
        endPlan = (player, id, at, token)
    }

    private func moveEnd(of id: ObjectIdentifier) {
        guard let plan = endPlan, plan.item == id else { return }
        cancelEndPlan()
        guard let item = player.currentItem, ObjectIdentifier(item) == id else { return }
        item.forwardPlaybackEndTime = item.duration
    }

    private func cancelEndPlan() {
        guard let plan = endPlan else { return }
        plan.player.removeTimeObserver(plan.token)
        endPlan = nil
    }

    /// Gapless with an effect on (29 Oct): a song with a tap on it changes over to the next with a gap of about 0.1 s, as
    /// the player starts a song's audio pipeline only when it starts (measured: 109 ms against 2 ms with no tap). So the
    /// next song starts `handoverLead` early on the second player, and the two overlap for `handoverFade`, equal power:
    /// too short to hear as a blend, long enough that nothing is cut.
    nonisolated static let handoverFade = 0.06
    nonisolated static let handoverLead = 0.16

    /// The seconds the songs overlap: the crossfade chosen, else the short handover when gapless needs it, else 0.
    private var fadeSeconds: Double {
        if Self.crossfade > 0 { return Self.crossfade }
        return Self.gapless && SoundChain.shared.active ? Self.handoverFade : 0
    }

    /// The song is ready: the crossfade's start is set at its length less the fade (and less the lead, for the handover).
    private func planFade(for item: AVPlayerItem) {
        cancelFadePlan()
        let seconds = fadeSeconds, length = audioLength ?? 0
        let lead = Self.crossfade > 0 ? 0 : Self.handoverLead
        guard seconds > 0, jam == nil, length > 2 * seconds + 3 * lead else { return }
        let at = NSValue(time: CMTime(seconds: length - seconds - lead, preferredTimescale: 600))
        let token = player.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.crossfadeNow() }
        }
        fadePlan = (player, ObjectIdentifier(item), token)
    }

    private func cancelFadePlan() {
        guard let plan = fadePlan else { return }
        plan.player.removeTimeObserver(plan.token)
        fadePlan = nil
    }

    /// The fade's start: the song playing goes on fading out on its player; the next one starts, fading in, on a new one.
    private func crossfadeNow() {
        guard let plan = fadePlan, plan.player === player, let item = player.currentItem, ObjectIdentifier(item) == plan.item,
              let next = nextSong(), isPlaying, outgoing == nil, let track = current else { return }
        cancelFadePlan()
        let seconds = fadeSeconds
        let handover = Self.crossfade == 0                    // the short overlap that stands in for gapless
        let mine = loads
        Task {
            guard let file = await localFile(for: next.listing), mine == loads, isPlaying, player.currentItem === item,
                  let now = nextSong(), now.index == next.index, now.listing.key == next.listing.key else { return }
            unqueue()                                         // gapless's item: the next song plays on the new player instead
            if !handover { SoundChain.shared.fade(item, outOver: seconds) }
            let old = player
            let new = AVQueuePlayer()
            setUp(new)
            player = new
            outgoing = old
            report("finish", track, at: Int(duration))
            moved(to: next.index, playing: next.listing)
            let incoming = AVPlayerItem(url: file)
            prepare(incoming, for: next.listing, fadeIn: seconds)
            observe(incoming)
            player.replaceCurrentItem(with: incoming)
            player.play()
            announceNext()
            refreshBuffering()
            publish()
            if handover {
                // the next song's sound reaches the speakers `handoverLead` after it starts: this one fades out then
                Task {
                    try? await Task.sleep(for: .seconds(Self.handoverLead))
                    if outgoing === old { SoundChain.shared.fade(item, outOver: seconds) }
                }
            }
            fadeEnd = Task {
                try? await Task.sleep(for: .seconds(seconds + (handover ? Self.handoverLead : 0) + 0.3))
                if !Task.isCancelled { endFade() }
            }
        }
    }

    /// The song going out stops now (its fade is over, or you paused, seeked or skipped), and its player goes.
    private func endFade() {
        fadeEnd?.cancel()
        fadeEnd = nil
        guard let old = outgoing else { return }
        outgoing = nil
        old.pause()
        old.removeAllItems()
    }

    #if DEBUG
    /// Self-tests: a second player is playing the song going out.
    var fadingForTests: Bool { outgoing != nil }
    #endif

    private func soundChanged() {
        if let item = player.currentItem, let key = playingListing?.key { SoundChain.shared.apply(to: item, key: key) }
        unqueue()
        queueNext()                                               // the queued song gets the new chain too
        if let item = player.currentItem, item.status == .readyToPlay { planFade(for: item) }   // crossfade on, off or longer
    }

    /// A copy loaded (its real length is now known), or would not play (MUS-1, rule 7). For a failed copy the server is
    /// asked for a fresh URL: that fixes its cache for next time, and its answer says WHY the copy failed, which the
    /// message then tells you.
    private func statusChanged(_ status: AVPlayerItem.Status, of item: ObjectIdentifier) {
        // news about a copy already replaced (it failed just as you pressed ⏭) must not act on the new one
        guard let loaded = player.currentItem, ObjectIdentifier(loaded) == item else { return }
        refreshBuffering()
        if status == .readyToPlay {
            failuresInARow = 0                                    // this song loads: the run of failures is over
            if queued == nil { queueNext() }
            // "play" once it can sound: songs that never loaded no longer count as played, nor show in Recently Played
            if !playReported, let track = current { playReported = true; report("play", track, at: 0) }
            // its length as it will play (the audio's, or the end set in `load` when that comes first): the bar, the
            // times and Control Center follow it from here. An end time that is not set reads as nan
            let end = loaded.forwardPlaybackEndTime.seconds
            // a file that ends before the listed length + 1 s: the end is moved up to the file's own a second before it, so
            // there is no silence after it (measured 28 Oct: a 3 s file with its end at 4 s ended at 4.2 s). Moved mid-song,
            // not now: now, 1 song in 4 was reported finished at 0:00 (29 Oct, 12 runs without the move: none), and with no
            // end time at all a song sometimes never ended. It stays as it was for audio that runs on past its length (Redbone)
            planEnd(for: loaded, listedEnd: end)
            let length = end.isFinite ? min(loaded.duration.seconds, end) : loaded.duration.seconds
            if length.isFinite, length > 0, length != audioLength { audioLength = length; publish() }
            planFade(for: loaded)                                 // needs the length, just set
            measureQuality(of: loaded)
            // another copy chosen mid-song: it carries on from the same moment
            if let saved = resumeAt {
                let at = resumeFromRoom ? jam?.playhead ?? saved : saved
                resumeAt = nil
                resumeFromRoom = false
                if at > 1, length.isFinite, at < length - 2 { jamFollow(seek: at) }     // a local seek, never a jam command
            }
        }
        guard status == .failed, let track = current, let failed = playingListing else { return }
        copyFailed(failed, of: track)
    }

    /// A copy would not play: AVPlayer failed on it, or the server gave no address for it.
    private func copyFailed(_ failed: Listing, of track: Track) {
        // a YouTube link this Mac looked up and that would not play: never handed out again (the retry looks it up anew)
        let youtube = Listing.isYouTube(failed.source)
        let forgotten = youtube ? Task { await YouTubeLookup.shared.forget(failed.id) } : nil
        // a copy that fails mid-song: the next one starts from the same moment, not from 0:00
        let at = livePosition
        Task { await AudioCache.shared.remove(failed.key) }        // a cached file that would not play is fetched again
        // every copy but the one it started with: excluding `best` instead retried a broken downloaded copy that was not
        // `best`, and never tried `best` (audit, 7 Oct)
        let others = track.listings.filter { $0.key != (firstCopy ?? track.best.key) }

        // another copy exists: switch to it at once, then say why the first one failed
        if fallbacksTried < others.count {
            let next = others[fallbacksTried]
            fallbacksTried += 1
            load(next, start: isPlaying)
            if at > 1 { resumeAt = at }
            Task {
                // the server explains a JioSaavn failure; a YouTube link was this Mac's own lookup, the server has no say
                let answer = youtube ? (status: 0, detail: nil) : await API.refresh(failed)
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
            isBuffering = isPlaying                               // paused: no spinner while it asks
            Task {
                await forgotten?.value
                // YouTube: a fresh lookup on this Mac (the link was forgotten above); JioSaavn: the server's fresh link
                let answer = youtube ? (status: 307, detail: nil) : await API.refresh(failed)
                guard current?.id == track.id, playingListing?.key == failed.key else { return }
                // streamed: when the copy that failed was a downloaded file, loading it again replayed the same broken file
                if answer?.status == 307 {
                    load(failed, fromFile: false, start: isPlaying)
                    if at > 1 { resumeAt = at }
                } else {
                    giveUp(track, because: Self.reason(answer, failed))
                }
            }
            return
        }

        if !youtube { Task { await API.refresh(failed) } }                        // still fix the server's cache for next time
        giveUp(track, because: nil)
    }

    private func giveUp(_ track: Track, because reason: String?) {
        isBuffering = false
        // in a jam a copy failing is this Mac's alone: the room plays on, and this Mac waits for the next song
        // (docs/jam.md). A skip here moved the room on for everyone: a member's failure until 12 Oct, the host's until 17 Oct
        if jam != nil {
            show("Couldn't play “\(track.title)”." + (reason.map { " " + $0 } ?? "") + " The jam plays on.", seconds: 6)
            return
        }
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
        // not the failure count: AVPlayer says "playing" as soon as play() is called, before a broken song fails,
        // so resetting it here meant 3 failures in a row never added up (7 Oct). A song that loads resets it
        refreshBuffering()
        position = livePosition
    }

    /// The spinner: you want it playing and no audio flows yet, because the copy is still loading or AVPlayer waits for
    /// data. AVPlayer's own "playing" comes the moment play() is called, before any audio, and it cleared the spinner:
    /// on a slow line the button showed ⏸ over silence for the whole load (6 s, emulated with NN_SELFTEST_SLOWPLAY, 8 Oct)
    private func refreshBuffering() {
        let loading = resolving || player.currentItem?.status == .unknown
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let now = isPlaying && (loading || waiting)
        if now != isBuffering { isBuffering = now }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        // gapless: the queue player has gone (or is going) straight into the queued song
        if let queued, let item, queued.after === item { playedOn(into: queued); return }
        guard item === player.currentItem, let track = current else { return }
        // in a jam the room moves on at the first device to finish (docs/jam.md)
        if let jam { report("finish", track, at: Int(duration)); jam.songEnded(); return }
        report("finish", track, at: Int(duration))
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
        if now < duration - 3 { report("skip", track, at: Int(now)) }
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
        #if os(macOS)
        WidgetFeed.update(current, playing: isPlaying)
        #endif
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
            // from ArtworkCache, at 512 px: macOS shows it small (Control Center, the lock screen). At Now Playing's
            // 1,200 px every song played left a 5.8 MB picture in the cache, and about 15 songs filled it, pushing the
            // lists' covers out (21 Oct); Now Playing fetches its own large one when it opens. Only the playing song's
            // is kept: the dictionary used to hold every cover played since launch
            guard let image = await ArtworkCache.shared.image(for: url, size: 256) else { return }
            // @Sendable: macOS asks for the image from its own background queue (this crashed on 5 Oct
            // when the closure was inferred main-thread-only)
            artwork = [track.id: MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }]
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

/// One song of what plays next (Player.nextSongs): the song, and playing it from there, in a jam or not.
struct NextSong: Identifiable {
    let id: String
    let track: Track
    let play: @MainActor () -> Void
}
