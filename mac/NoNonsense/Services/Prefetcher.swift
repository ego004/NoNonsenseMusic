import Foundation

/// Tells the server which listings come next, so they are looked up before you press play (MUS-1 step 3).
/// The list: the next 5 songs of the playing queue, then the top results of the search on screen (Settings ›
/// Footprint › Search: none, the top one by default, or the top 5); queue first, no song twice, each as the copy that
/// would play (its best listing). Sent 0.3 s after the queue settles, 1 s after the search does (results change as
/// you type: each one fetched is a YouTube lookup on your server), and only when it differs from the last one sent. The server replaces its waiting list
/// with each new one, so an old list never piles up.
final class Prefetcher {
    static let shared = Prefetcher()

    private var queuePart: [Listing] = []
    private var searchPart: [Listing] = []
    private var lastSent: [String] = []
    private var pending: Task<Void, Never>?

    /// The playing queue moved or changed: these come next, in play order.
    func queueChanged(_ next: [Listing]) {
        queuePart = Array(next.prefix(5))
        schedule()
    }

    /// The search on screen changed (empty when it is cleared or left).
    func searchChanged(_ top: [Listing]) {
        let count = UserDefaults.standard.object(forKey: "searchPrefetch") as? Int ?? Self.searchDefault
        searchPart = Array(top.prefix(max(0, count)))
        schedule(after: .seconds(1))
    }

    /// How many of a search's top results are made ready: 1 (the one you usually click). Was 5 (7 Oct).
    static let searchDefault = 1

    private func schedule(after delay: Duration = .milliseconds(300)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            let list = (queuePart + searchPart).filter { seen.insert($0.key).inserted }
            guard !list.isEmpty, list.map(\.key) != lastSent else { return }
            lastSent = list.map(\.key)
            // YouTube copies are looked up by this Mac (YouTubeLookup, 8 Oct): its links carry the asker's IP. The rest
            // (JioSaavn) the server makes ready, as before
            let youtube = list.filter { $0.source == "ytmusic" }.map(\.id)
            let others = list.filter { $0.source != "ytmusic" }
            if !others.isEmpty { try? await API.prefetch(others) }   // a server without /prefetch answers 404: nothing breaks
            await YouTubeLookup.shared.warm(youtube)
        }
    }
}
