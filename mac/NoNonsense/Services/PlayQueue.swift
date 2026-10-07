import Foundation

/// The order songs play in, apart from the audio itself: shuffle, repeat, "play next", and keeping a playing
/// playlist's queue in step with your edits to that playlist. A plain value with no AVPlayer, so the self-test
/// can check every rule (`NN_SELFTEST_QUEUE`). `Player` owns one and does the playing.
struct PlayQueue {
    enum Repeat: String, CaseIterable {
        case off, all, one
        /// off → all → one → off: the order the repeat button steps through, as in Apple Music.
        var next: Repeat { switch self { case .off: .all; case .all: .one; case .one: .off } }
        var label: String { switch self { case .off: "Off"; case .all: "All"; case .one: "One" } }
        /// The repeat button's tooltip: what it does now, and what the next press does.
        var help: String {
            switch self {
            case .off: "Repeat (⌘R)"
            case .all: "Repeating the queue (⌘R: repeat one)"
            case .one: "Repeating this song (⌘R: off)"
            }
        }
    }

    /// One place in the queue.
    struct Entry: Identifiable {
        let track: Track
        /// Its place in the order you chose: shuffle off sorts by it, so the order comes back.
        var n: Double
        /// Names this entry for edits that come later: a playlist item id, so a song added twice is two entries.
        let key: String
        /// Added by Play Next: not one of the list's songs, so a playlist sync keeps it instead of removing it.
        var queued = false
        /// Added by Add to Queue: its place is the end of Up Next, not right after the playing song.
        var atEnd = false
        var id: String { key }
    }

    private(set) var entries: [Entry] = []
    private(set) var index = 0
    private(set) var isShuffled = false
    var repeatMode: Repeat = .off
    /// Where the queue came from, e.g. "playlist:<id>": edits to that playlist reach the queue only then.
    private(set) var source: String?
    /// Where it came from, for "From “Gym”" in Now Playing and Discord. Unlike `source`, a change by hand keeps it:
    /// a reordered queue still came from Gym (the label used to vanish at the first drag: audit, 7 Oct).
    private(set) var origin: String?

    var tracks: [Track] { entries.map(\.track) }
    var current: Track? { entries.indices.contains(index) ? entries[index].track : nil }
    var currentKey: String? { entries.indices.contains(index) ? entries[index].key : nil }
    var upNext: [Track] { upcoming.map(\.track) }
    /// The entries after the current one, in play order: what Up Next shows (each with its own key, for a list).
    var upcoming: [Entry] { entries.indices.contains(index + 1) ? Array(entries[(index + 1)...]) : [] }

    /// A new queue. `keys` name the entries (playlist item ids); without them each entry gets its own.
    mutating func load(_ tracks: [Track], startAt i: Int, keys: [String]? = nil, source: String? = nil, shuffled: Bool) {
        entries = tracks.enumerated().map { n, track in
            Entry(track: track, n: Double(n), key: keys.flatMap { $0.indices.contains(n) ? $0[n] : nil } ?? UUID().uuidString)
        }
        index = tracks.indices.contains(i) ? i : 0
        self.source = source
        origin = source
        isShuffled = false
        if shuffled {
            // a new queue with shuffle on: the song you picked first, then EVERY other song shuffled
            // (also the ones above it in the list), as in Apple Music
            var rng = SystemRandomNumberGenerator()
            let chosen = entries.remove(at: index)
            entries = [chosen] + Shuffle.artistSpread(entries, artist: { $0.track.artists.first ?? "" }, using: &rng)
            index = 0
            isShuffled = true
        }
    }

    /// On: the songs after the current one are shuffled (each artist spread out); the current one and the ones
    /// already played stay where they are. Off: back to the order you chose, still on the same song.
    mutating func setShuffle(_ on: Bool, using rng: inout some RandomNumberGenerator) {
        guard on != isShuffled else { return }
        isShuffled = on
        guard let key = currentKey else { return }
        if on {
            let rest = Array(entries[(index + 1)...])
            entries = Array(entries[...index]) + Shuffle.artistSpread(rest, artist: { $0.track.artists.first ?? "" }, using: &rng)
        } else {
            entries.sort { $0.n < $1.n }
            index = entries.firstIndex { $0.key == key } ?? 0
        }
    }

    mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    /// Where the queue goes when a song ends by itself: repeat one plays it again; at the end, repeat all
    /// starts over and repeat off stops (nil).
    func indexAfterEnd() -> Int? {
        repeatMode == .one ? index : step(1)
    }

    /// Where ⏭ goes: always another song (repeat one does not trap you), wrapping round unless repeat is off.
    func indexAfterNext() -> Int? { step(1) }

    /// Where ⏮ goes (after the first 3 seconds of a song, ⏮ restarts it instead: the Player decides that).
    func indexAfterPrevious() -> Int? { step(-1) }

    private func step(_ by: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        let target = index + by
        if entries.indices.contains(target) { return target }
        return repeatMode == .off ? nil : (target + entries.count) % entries.count
    }

    mutating func move(to i: Int) {
        if entries.indices.contains(i) { index = i }
    }

    /// "Play Next": right after the current song, both now and in the order you chose (so it stays next to it
    /// when shuffle is turned off).
    mutating func insertNext(_ track: Track) {
        guard let current = entries.indices.contains(index) ? entries[index] : nil else {
            load([track], startAt: 0, shuffled: false)
            return
        }
        let following = entries.map(\.n).filter { $0 > current.n }.min()
        let n = following.map { (current.n + $0) / 2 } ?? current.n + 1
        entries.insert(Entry(track: track, n: n, key: UUID().uuidString, queued: true), at: index + 1)
    }

    /// "Add to Queue": after everything already queued, both now and in the order you chose. Marked `queued`, like
    /// Play Next, so a playlist sync keeps it.
    mutating func append(_ track: Track) {
        guard !entries.isEmpty else { load([track], startAt: 0, shuffled: false); return }
        entries.append(Entry(track: track, n: (entries.map(\.n).max() ?? 0) + 1, key: UUID().uuidString, queued: true, atEnd: true))
    }

    /// Up Next rearranged by hand (a drag in Now Playing). `offsets` and `destination` count from the first song
    /// after the current one, as Up Next shows them; the current song never moves.
    mutating func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var list = upcoming
        guard !offsets.isEmpty, offsets.allSatisfy(list.indices.contains) else { return }
        let moving = offsets.map { list[$0] }
        list = list.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        list.insert(contentsOf: moving, at: min(list.count, destination - offsets.filter { $0 < destination }.count))
        entries = Array(entries[...index]) + list
        handEdited()
    }

    /// Takes one song out of Up Next (`offset` counts from the next song).
    mutating func removeUpcoming(at offset: Int) {
        guard upcoming.indices.contains(offset) else { return }
        entries.remove(at: index + 1 + offset)
        handEdited()
    }

    /// Empties Up Next; the current song plays on.
    mutating func clearUpcoming() {
        guard entries.indices.contains(index) else { return }
        entries = Array(entries[...index])
        handEdited()
    }

    /// After a change by hand the queue is yours: the playlist it came from no longer reorders it (a sync would
    /// undo the change), and with shuffle off your order becomes the play order, so turning shuffle on and off
    /// again comes back to it.
    private mutating func handEdited() {
        source = nil
        if !isShuffled {
            for i in entries.indices { entries[i].n = Double(i) }
        }
    }

    /// The playlist this queue came from now has these items, in this order (after a move, an add or a remove, and
    /// each time it is opened). Your order follows it; removed items leave the queue, except the playing one, which
    /// plays on; new items join at the end. Shuffled, the play order stays shuffled and only "your order" changes
    /// underneath. Songs you queued with Play Next stay next, in their order: they are not the playlist's, and were
    /// removed here, so opening the playlist silently took them out of Up Next (audit, 7 Oct).
    mutating func sync(source: String, items: [(key: String, track: Track)]) {
        guard self.source == source, let playing = currentKey else { return }
        let queued = upcoming.filter { $0.queued && !$0.atEnd }    // put back after the playing song, below
        let atEnd = upcoming.filter { $0.queued && $0.atEnd }      // put back at the end, in their order
        let order = Dictionary(items.enumerated().map { ($1.key, Double($0)) }, uniquingKeysWith: { first, _ in first })
        entries.removeAll { ($0.queued || order[$0.key] == nil) && $0.key != playing }
        for i in entries.indices {
            if let n = order[entries[i].key] { entries[i].n = n }
        }
        let known = Set(entries.map(\.key))
        for (n, item) in items.enumerated() where !known.contains(item.key) {
            entries.append(Entry(track: item.track, n: Double(n), key: item.key))
        }
        if !isShuffled { entries.sort { $0.n < $1.n } }
        index = entries.firstIndex { $0.key == playing } ?? 0
        let last = entries.map(\.n).max() ?? 0
        for (i, entry) in atEnd.enumerated() {
            var back = entry
            back.n = last + Double(i + 1)
            entries.append(back)
        }
        // back in right after the playing song, each with a place between it and the next song in your order, so
        // turning shuffle off keeps them there too
        guard !queued.isEmpty, entries.indices.contains(index) else { return }
        let here = entries[index].n
        let following = entries.map(\.n).filter { $0 > here }.min() ?? here + 1
        for (i, entry) in queued.enumerated() {
            var back = entry
            back.n = here + (following - here) * Double(i + 1) / Double(queued.count + 1)
            entries.insert(back, at: index + 1 + i)
        }
    }
}
