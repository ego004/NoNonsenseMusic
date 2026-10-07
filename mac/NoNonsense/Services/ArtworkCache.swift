import AppKit
import SwiftUI

/// Covers, downloaded once and kept in memory, and the colours the background and the accents are made from.
/// A cover shown once appears instantly afterwards, and a new cover replaces the old one without an empty frame
/// in between: that empty, light-grey frame was the white flash between songs (AsyncImage starts from its placeholder).
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    /// Decoded covers, at most 96 MB of pixels: past that the least used are dropped (they download again if needed).
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var loading: [String: Task<NSImage?, Never>] = [:]
    private var grids: [URL: [Color]] = [:]

    /// Two sizes. A cover shown at up to 128 pt (lists, shelves, the bar) is decoded at 256 px, about 0.25 MB; a larger
    /// one (Now Playing, cards) at up to 1,200 px. Every cover used to be decoded at full size, ~1.1 MB, even for a
    /// 44 pt row (7 Oct: the app held 185 MB).
    private static func pixels(for points: CGFloat) -> Int { points <= 128 ? 256 : 1200 }
    private static func key(_ url: URL, _ pixels: Int) -> String { "\(pixels)|\(url.absoluteString)" }

    func cached(_ url: URL, size points: CGFloat = 1000) -> NSImage? {
        images.object(forKey: Self.key(url, Self.pixels(for: points)) as NSString)
    }

    /// The cover, decoded for `size` points. Two views asking for the same one at once share one download.
    func image(for url: URL, size points: CGFloat = 1000) async -> NSImage? {
        let pixels = Self.pixels(for: points), key = Self.key(url, pixels)
        if let hit = images.object(forKey: key as NSString) { return hit }
        if let running = loading[key] { return await running.value }
        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await Task.detached(priority: .utility) { Self.decoded(data, maxPixels: pixels) }.value
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            images.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// A cover ready to draw: decoded once, at most 1,200 px (the largest it is ever shown: 560 pt on a Retina
    /// screen), already in sRGB. `NSImage(data:)` kept the compressed JPEG, so every repaint decoded it again and
    /// converted its colours: that was most of Now Playing's CPU (profiled 7 Oct).
    nonisolated static func decoded(_ data: Data, maxPixels: Int = 1200) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return NSImage(data: data) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let ready = context.makeImage() else { return NSImage(data: data) }
        return NSImage(cgImage: ready, size: NSSize(width: image.width, height: image.height))
    }

    /// The cover shrunk to 3×3 pixels: nine colours, each where it sits on the cover, row by row from the top.
    /// They become the points of the moving mesh behind the window.
    func colorGrid(for url: URL) async -> [Color]? {
        if let hit = grids[url] { return hit }
        guard let image = await image(for: url, size: 64),                 // 3×3 colours need only the small one
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
