// Draws the NoNonsense app icon at 1024×1024: a white macOS squircle with a folded-paper N in black and greys.
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
// work in top-left coordinates, like a design tool
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple's icon shape: a superellipse ("squircle"), smoother than a rounded rectangle.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath(); return p
}

/// Fills a path with a vertical (top → bottom) gradient.
func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let box = path.boundingBox
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    ctx.restoreGState()
}

// ---- the body: white squircle on Apple's grid (824 of 1024), with the standard soft shadow
// Apple's icon grid: an 824 px body in a 1024 canvas, continuous corners (the curve SwiftUI's .continuous draws)
let body = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.30))   // y is flipped: positive = down
ctx.addPath(body); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
fill(body, top: rgb(0xFFFFFF), bottom: rgb(0xE9E9EE))
ctx.saveGState()
ctx.addPath(body); ctx.setStrokeColor(rgb(0x000000, 0.06)); ctx.setLineWidth(2); ctx.strokePath()
ctx.restoreGState()

// ---- the N: one paper strip, folded twice
let left: CGFloat = 316, right: CGFloat = 708, top: CGFloat = 296, bottom: CGFloat = 728, w: CGFloat = 110
let slope = (right - w - left) / (bottom - top)                         // the diagonal's dx per dy
let leftStem = polygon([CGPoint(x: left, y: top), CGPoint(x: left + w, y: top), CGPoint(x: left + w, y: bottom), CGPoint(x: left, y: bottom)])
let rightStem = polygon([CGPoint(x: right - w, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: right - w, y: bottom)])
let diagonal = polygon([CGPoint(x: left, y: top), CGPoint(x: left + w, y: top), CGPoint(x: right, y: bottom), CGPoint(x: right - w, y: bottom)])
// where the strip folds: the diagonal over the top of the left stem, and over the foot of the right stem
let foldTopY = top + w / slope
let foldBottomY = bottom - w / slope
let foldTop = polygon([CGPoint(x: left, y: top), CGPoint(x: left + w, y: top), CGPoint(x: left + w, y: foldTopY)])
let foldBottom = polygon([CGPoint(x: right - w, y: foldBottomY), CGPoint(x: right, y: bottom), CGPoint(x: right - w, y: bottom)])

let letter = CGMutablePath()
letter.addPath(leftStem); letter.addPath(rightStem); letter.addPath(diagonal)

// the whole letter lifts off the white with a soft shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: rgb(0x000000, 0.22))
ctx.addPath(letter); ctx.setFillColor(rgb(0x3A3A3E)); ctx.fillPath()
ctx.restoreGState()

// One strip folded in a zigzag, like paper: up the left stem (front, graphite), folded over at the top so its
// back (near-black) runs down the diagonal OVER the left stem, then folded again at the foot so the right stem
// (front again) lies OVER the diagonal. Not the Netflix construction (diagonal on top of both).
fill(leftStem, top: rgb(0x5C5C63), bottom: rgb(0x3F3F44))

// the diagonal (the strip's back) lies on the left stem: a short shadow onto it
ctx.saveGState()
ctx.addPath(leftStem); ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 16, color: rgb(0x000000, 0.50))
ctx.addPath(diagonal); ctx.setFillColor(rgb(0x1C1C1F)); ctx.fillPath()
ctx.restoreGState()
fill(diagonal, top: rgb(0x26262A), bottom: rgb(0x121214))
// the top fold: where the strip turns over, a crease of light along the bend
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(2.5)
ctx.move(to: CGPoint(x: left, y: top)); ctx.addLine(to: CGPoint(x: left + w, y: foldTopY)); ctx.strokePath()

// the right stem (front again) lies on the diagonal: it casts its shadow onto the diagonal
ctx.saveGState()
ctx.addPath(diagonal); ctx.clip()
ctx.setShadow(offset: CGSize(width: -5, height: 4), blur: 16, color: rgb(0x000000, 0.55))
ctx.addPath(rightStem); ctx.setFillColor(rgb(0x5A5A60)); ctx.fillPath()
ctx.restoreGState()
fill(rightStem, top: rgb(0x75757C), bottom: rgb(0x55555B))
// the bottom fold: the stem's corner where the strip turns, a touch darker, with its crease
ctx.saveGState()
ctx.addPath(foldBottom); ctx.clip()
fill(foldBottom, top: rgb(0x4E4E54), bottom: rgb(0x3E3E43))
ctx.restoreGState()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(2.5)
ctx.move(to: CGPoint(x: right - w, y: foldBottomY)); ctx.addLine(to: CGPoint(x: right, y: bottom)); ctx.strokePath()
// paper catches light along its top edges
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2)
ctx.move(to: CGPoint(x: right - w + 1, y: top + 1)); ctx.addLine(to: CGPoint(x: right - 1, y: top + 1)); ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
print(CGImageDestinationFinalize(destination) ? "wrote \(out.lastPathComponent)" : "FAILED")
