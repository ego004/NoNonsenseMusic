import Foundation

/// Tells the server which listings come next, so they are looked up before you press play (MUS-1 step 3).
/// The list: the next 5 songs of the playing queue, then the top 5 of the search on screen; queue first, no song
/// twice, each as the copy that would play (its best listing). Sent 0.3 s after things settle (search results
/// change as you type), and only when it differs from the last one sent. The server replaces its waiting list
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
        searchPart = Array(top.prefix(5))
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            let list = (queuePart + searchPart).filter { seen.insert($0.key).inserted }
            guard !list.isEmpty, list.map(\.key) != lastSent else { return }
            lastSent = list.map(\.key)
            try? await API.prefetch(list)          // a server without /prefetch just answers 404: nothing breaks
        }
    }
}
