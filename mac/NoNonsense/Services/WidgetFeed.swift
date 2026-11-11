#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// What the Mac widget shows (NoNonsense-Widget): the song playing and its cover, written to the app's own folder when
/// the song or play/pause changes (not on every publish), then the widget is asked to reload. The widget is sandboxed
/// and reads these two files through a read-only exception; no app group is needed, which an ad-hoc signed app cannot have.
@MainActor
enum WidgetFeed {
    private static let folder = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "app.nononsense.music")
    private static var last = ""

    static func update(_ track: Track?, playing: Bool) {
        #if DEBUG
        if SelfTest.isRunning { return }              // a test writes nothing to the widget's files and asks WidgetKit for nothing
        #endif
        let key = "\(track?.id ?? "")|\(playing)"
        guard key != last else { return }
        let songChanged = last.split(separator: "|").first.map(String.init) != track?.id
        last = key
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let track else {
            try? FileManager.default.removeItem(at: folder.appending(path: "widget.json"))
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let info = ["title": track.title, "artist": track.artistLine, "playing": playing] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: folder.appending(path: "widget.json"), options: .atomic) }
        // another song: the last one's cover goes now, so the widget never shows old art under a new title
        if songChanged { try? FileManager.default.removeItem(at: folder.appending(path: "cover.jpg")) }
        guard songChanged, let url = track.image else { WidgetCenter.shared.reloadAllTimelines(); return }
        Task {
            // the cover is the cache's 128-point copy (256 px), as small as a widget needs
            if let image = await ArtworkCache.shared.image(for: url, size: 128), let jpeg = jpeg(image), last.hasPrefix("\(track.id)|") {
                try? jpeg.write(to: folder.appending(path: "cover.jpg"), options: .atomic)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func jpeg(_ image: PlatformImage) -> Data? {
        guard let cg = image.readableCGImage else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}
#endif
