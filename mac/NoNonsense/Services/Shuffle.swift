import Foundation

/// Two shuffles: true random, and Spotify's 2014 "spread each artist out" version.
nonisolated enum Shuffle {
    /// Fisher–Yates: walk from the last position backwards; swap each item with a random one at or before it.
    /// Every order is equally likely. Returns a new array (the caller's array is not changed).
    static func fisherYates<T>(_ items: [T], using rng: inout some RandomNumberGenerator) -> [T] {
        var result = items
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = Int.random(in: 0...i, using: &rng)
            result.swapAt(i, j)
        }
        return result
    }

    /// Artist spread: an artist with k songs gets positions offset + i/k (+ a little jitter),
    /// so their songs land roughly evenly through the list instead of clumping.
    static func artistSpread<T>(_ items: [T], artist: (T) -> String,
                                using rng: inout some RandomNumberGenerator) -> [T] {
        var byArtist: [String: [T]] = [:]
        for item in items { byArtist[artist(item), default: []].append(item) }

        var placed: [(position: Double, item: T)] = []
        for (_, songs) in byArtist {
            let k = Double(songs.count)
            let offset = Double.random(in: 0..<(1 / k), using: &rng)
            // shuffle the artist's own songs too, so the same song does not always come first
            for (i, song) in fisherYates(songs, using: &rng).enumerated() {
                let jitter = Double.random(in: -0.1...0.1, using: &rng) / k
                placed.append((offset + Double(i) / k + jitter, song))
            }
        }
        return placed.sorted { $0.position < $1.position }.map(\.item)
    }
}

extension Shuffle {
    /// What the Shuffle button uses: spread by each track's first artist.
    static func tracks(_ tracks: [Track]) -> [Track] {
        var rng = SystemRandomNumberGenerator()
        return artistSpread(tracks, artist: { $0.artists.first ?? "" }, using: &rng)
    }
}
