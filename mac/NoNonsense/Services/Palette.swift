import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The pastel colour of a song: its artwork's average colour, softened toward white (or black in dark mode).
enum Palette {
    private static var cache: [URL: Color] = [:]

    static func pastel(for url: URL?, dark: Bool) async -> Color? {
        guard let url else { return nil }
        let base: Color
        if let cached = cache[url] {
            base = cached
        } else {
            guard let response = try? await URLSession.shared.data(from: url),
                  let rgb = await averageRGB(response.0) else { return nil }
            base = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
            cache[url] = base
        }
        return base.mix(with: dark ? .black : .white, by: dark ? 0.3 : 0.5)
    }

    /// A fallback pastel when there is no artwork: a soft hue derived from the title.
    static func fallback(for title: String) -> Color {
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        return Color(hue: hue, saturation: 0.35, brightness: 0.95)
    }

    /// Average colour of an image (Core Image's area-average filter). @concurrent: runs off the main thread.
    @concurrent
    nonisolated static func averageRGB(_ data: Data) async -> (Double, Double, Double)? {
        guard let image = CIImage(data: data) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
