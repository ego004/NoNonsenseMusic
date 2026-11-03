import AppKit
import Sparkle

/// In-place updates, through Sparkle: at every launch, and every 4 hours while the app runs, it reads the latest
/// release's appcast on GitHub; a newer version
/// is offered with its notes, downloaded, checked against the release key's EdDSA signature (an update not signed by it
/// is refused), put in place of this app, and opened. Settings › Account › Check for updates turns the checks off;
/// the app menu's Check for Updates… asks at once. The appcast is the one request that does not go to your server.
///
/// Releases are ad-hoc signed (no Apple Developer ID), so the signature is what vouches for an update: Sparkle accepts
/// one when "Either DSA must be valid, or Apple Code Signing must be valid" (SUUpdateValidator.m, 2.10.0).
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "checkUpdates")
            shared.controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// At launch. A Debug build has no feed and does not start, unless the update self-test gives it one.
    func start() {
        guard controller == nil, feed != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = Self.enabled
        #if DEBUG
        if SelfTest.updateFeed != nil { controller.updater.automaticallyDownloadsUpdates = true }
        #endif
        do {
            try controller.updater.start()
        } catch {
            NSLog("Updater: not started: %@", error.localizedDescription)
            return
        }
        self.controller = controller
        // Sparkle's own schedule asks only when the interval since the last check has passed, so a launch an hour
        // after one asked nothing (a release stayed unseen for a day). Every launch asks, silently: a window opens only
        // when there is an update. The 4-hour schedule then runs from this check.
        if Self.enabled { controller.updater.checkForUpdatesInBackground() }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// The app menu's Check for Updates…: Sparkle's own window says what it finds.
    func checkNow() { controller?.checkForUpdates(nil) }

    /// The appcast: the latest release's (Info.plist's SUFeedURL), or the update self-test's.
    private var feed: String? {
        #if DEBUG
        if let test = SelfTest.updateFeed { return test }
        #endif
        let url = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return url.isEmpty ? nil : url
    }

    /// Only the update self-test's feed: otherwise nil, and Sparkle reads its own (a SUFeedURL in this app's defaults,
    /// else Info.plist's), so a test of a release build can point it at a local feed. An update must still be signed by
    /// the release key.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return MainActor.assumeIsolated { SelfTest.updateFeed }
        #else
        return nil
        #endif
    }

    #if DEBUG
    // the update self-test: what Sparkle did, reported, and an update installed at once instead of at quit
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.versionString
        MainActor.assumeIsolated { SelfTest.updateEvent("found \(version)") }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { SelfTest.updateEvent("ready to install \(item.versionString)") }
        immediateInstallHandler()
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let text = (error as NSError).localizedDescription
        MainActor.assumeIsolated { SelfTest.updateEvent("aborted: \(text)") }
    }

    func checkInBackgroundForTests() { controller?.updater.checkForUpdatesInBackground() }
    #endif
}
