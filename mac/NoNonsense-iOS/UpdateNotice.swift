import SwiftUI

/// The iPhone's update check, on the Mac's and Windows' schedule: at every launch, and every 4 hours while the app is
/// open, it reads the latest release's AltStore source (releases/latest/download/altstore.json). A phone cannot install
/// an update by itself (AltStore or SideStore signs the app with your Apple ID and installs it), so a newer version is
/// announced and its release page offered. Settings › Check for updates turns it off; Skip This Version is not asked
/// again.
@MainActor
@Observable
final class UpdateNotice {
    static let shared = UpdateNotice()

    struct Found: Identifiable {
        let version: String
        var id: String { version }
    }
    /// A newer version, to be shown.
    var found: Found?

    static let feed = URL(string: "https://github.com/ego004/NoNonsenseMusic/releases/latest/download/altstore.json")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }   // the Mac's key too

    func releasePage(_ version: String) -> URL {
        URL(string: "https://github.com/ego004/NoNonsenseMusic/releases/tag/v\(version)")!
    }

    func skip(_ version: String) { UserDefaults.standard.set(version, forKey: "skippedUpdate") }

    /// Asks once. Nothing when it is off, a version is already shown, the feed cannot be read, or nothing newer is out.
    func check() async {
        guard Self.enabled, found == nil else { return }
        if case .newer(let version) = await lookUp(), version != UserDefaults.standard.string(forKey: "skippedUpdate") {
            found = Found(version: version)
        }
    }

    enum Outcome: Equatable {
        case newer(String)
        case upToDate
        case unreachable
    }

    /// Reads the feed: what is newest, whatever the settings say (Settings › Check Now uses it as it is).
    func lookUp() async -> Outcome {
        guard let (data, response) = try? await URLSession.shared.data(from: Self.feed),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = try? JSONDecoder().decode(Source.self, from: data),
              let latest = source.apps.first?.version else { return .unreachable }
        return Self.isNewer(latest, than: Self.current) ? .newer(latest) : .upToDate
    }

    /// Settings › Check Now: asks at once, even with automatic checks off, and shows a newer version even if it was
    /// skipped. Returns what to tell the person when nothing is shown.
    func checkNow() async -> String? {
        switch await lookUp() {
        case .newer(let version): found = Found(version: version); return nil
        case .upToDate: return "NoNonsenseMusic \(Self.current) is the latest version."
        case .unreachable: return "GitHub did not answer. Check the connection and try again."
        }
    }

    private struct Source: Decodable {
        struct App: Decodable { let version: String }
        let apps: [App]
    }

    /// "0.6.10" is newer than "0.6.9": the dotted numbers compared one by one, a missing one counting as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

extension View {
    /// Checks at launch and every 4 hours, and offers a newer version.
    func offersUpdates() -> some View { modifier(OffersUpdates()) }
}

private struct OffersUpdates: ViewModifier {
    @Environment(\.openURL) private var openURL
    private var notice: UpdateNotice { .shared }

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    await notice.check()
                    try? await Task.sleep(for: .seconds(4 * 60 * 60))
                }
            }
            .alert("NoNonsenseMusic \(notice.found?.version ?? "") is available",
                   isPresented: Binding(get: { notice.found != nil }, set: { if !$0 { notice.found = nil } }),
                   presenting: notice.found) { found in
                Button("Open Release Page") { openURL(notice.releasePage(found.version)) }
                Button("Skip This Version") { notice.skip(found.version) }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("You have \(UpdateNotice.current). AltStore or SideStore installs it: open it and refresh, or see what's new on the release page.")
            }
    }
}
