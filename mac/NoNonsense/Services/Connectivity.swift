import Foundation
import Network
import Observation

/// Is this Mac online, and does the server answer? The window shows a banner while either is not so, and the player
/// stops instead of trying song after song (with no internet every song failed and the queue cycled, 7 Oct).
/// Online/offline comes from macOS's own network path monitor: told when it changes, no polling.
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var online = true
    private(set) var serverAnswers = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.pathChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "app.nononsense.connectivity"))
    }

    private func pathChanged(_ up: Bool) {
        guard up != online else { return }
        online = up
        if up { Task { await checkServer() } }       // back online: is the server there too?
    }

    /// Asks the server's /health once and remembers the answer.
    @discardableResult
    func checkServer() async -> Bool {
        serverAnswers = await API.health()
        return serverAnswers
    }

    /// A request to the server got no answer at all (not an error reply): show the banner until it answers again.
    func serverDidNotAnswer() { serverAnswers = false }
}
