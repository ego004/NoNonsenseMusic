import AppKit
import SwiftUI

/// Covers, downloaded once and kept in memory, and the colours the background and the accents are made from.
/// A cover shown once appears instantly afterwards, and a new cover replaces the old one without an empty frame
/// in between: that empty, light-grey frame was the white flash between songs (AsyncImage starts from its placeholder).
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let images = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]
    private var grids: [URL: [Color]] = [:]

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    /// The cover. Two views asking for the same URL at once share one download (single-flight).
    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = loading[url] { return await running.value }
        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// The cover shrunk to 3×3 pixels: nine colours, each where it sits on the cover, row by row from the top.
    /// They become the points of the moving mesh behind the window.
    func colorGrid(for url: URL) async -> [Color]? {
        if let hit = grids[url] { return hit }
        guard let image = await image(for: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let grid: [Color]? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high                      // average each ninth, not pick one pixel
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return stride(from: 0, to: 36, by: 4).map {
                Color(red: Double(buffer[$0]) / 255, green: Double(buffer[$0 + 1]) / 255, blue: Double(buffer[$0 + 2]) / 255)
            }
        }
        if let grid { grids[url] = grid }
        return grid
    }

    /// A vivid colour from the cover for sliders, the progress line and the heart: its most colourful ninth,
    /// made readable on this background. A grey cover keeps the system accent.
    func accent(for url: URL?, dark: Bool) async -> Color? {
        guard let url, let grid = await colorGrid(for: url) else { return nil }
        let colors = grid.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }
        guard let best = colors.max(by: { $0.saturationComponent * $0.brightnessComponent < $1.saturationComponent * $1.brightnessComponent }),
              best.saturationComponent > 0.15 else { return nil }
        return Color(hue: best.hueComponent, saturation: min(max(best.saturationComponent, 0.45), 0.8), brightness: dark ? 0.92 : 0.6)
    }
}
