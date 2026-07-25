// Draws the Lggr app icon at every size macOS asks for.
//
// Kept as a generator rather than a checked-in binary asset so the mark stays editable in review:
// the icon is a timer ring with an open gap, on the macOS squircle. No text — it has to stay legible
// at 16pt in the Finder sidebar, where letterforms turn to mush.
//
// Run via Scripts/make-icon.sh.

import AppKit
import CoreGraphics
import Foundation

struct IconRenderer {
    let size: CGFloat

    private var scale: CGFloat { size / 1024 }
    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    func render(into context: CGContext) {
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        drawSquircle(in: context)
        drawTimerRing(in: context)
    }

    /// The macOS app-icon plate: an 824pt rounded square centred on a 1024pt canvas.
    private func drawSquircle(in context: CGContext) {
        let inset = s(100)
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: s(185),
            cornerHeight: s(185),
            transform: nil
        )

        context.saveGState()
        context.addPath(path)
        context.clip()

        // A restrained two-stop vertical gradient. Enough to give the plate depth under the ring
        // without turning into the gradient soup the design direction rules out.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(colorSpace: colorSpace, components: [0.180, 0.192, 0.235, 1.0]),
            CGColor(colorSpace: colorSpace, components: [0.098, 0.106, 0.141, 1.0]),
        ].compactMap { $0 }

        if colors.count == 2,
           let gradient = CGGradient(
               colorsSpace: colorSpace,
               colors: colors as CFArray,
               locations: [0.0, 1.0]
           ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }
        context.restoreGState()

        // A hairline top highlight, the way Apple's own plates catch light.
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setStrokeColor(CGColor(gray: 1.0, alpha: 0.10))
        context.setLineWidth(s(3))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// A timer ring with a gap at the top-right, plus a filled cap marking the head of the arc.
    private func drawTimerRing(in context: CGContext) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = s(268)
        let lineWidth = s(74)

        // Track: the full circle, barely visible, so the ring reads as a dial rather than a crescent.
        context.setStrokeColor(CGColor(gray: 1.0, alpha: 0.14))
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: false
        )
        context.strokePath()

        // Progress arc: starts at 12 o'clock, sweeps clockwise through ~72% of the dial.
        let startAngle = CGFloat.pi / 2
        let endAngle = startAngle - (.pi * 2 * 0.72)

        context.setStrokeColor(CGColor(red: 0.996, green: 0.976, blue: 0.949, alpha: 1.0))
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        context.strokePath()

        // Centre dot: the "now" marker. Small enough to survive downscaling to 16pt.
        context.setFillColor(CGColor(red: 0.996, green: 0.976, blue: 0.949, alpha: 1.0))
        context.fillEllipse(
            in: CGRect(
                x: center.x - s(46),
                y: center.y - s(46),
                width: s(92),
                height: s(92)
            )
        )
    }
}

func writePNG(size: CGFloat, to url: URL) throws {
    let pixels = Int(size)
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.contextCreationFailed(pixels)
    }

    IconRenderer(size: size).render(into: context)

    guard let image = context.makeImage() else {
        throw IconError.imageCreationFailed(pixels)
    }

    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.encodingFailed(pixels)
    }

    try data.write(to: url)
}

enum IconError: Error, CustomStringConvertible {
    case contextCreationFailed(Int)
    case imageCreationFailed(Int)
    case encodingFailed(Int)
    case missingOutputDirectory

    var description: String {
        switch self {
        case .contextCreationFailed(let size): "could not create a \(size)px drawing context"
        case .imageCreationFailed(let size): "could not rasterise the \(size)px icon"
        case .encodingFailed(let size): "could not PNG-encode the \(size)px icon"
        case .missingOutputDirectory: "usage: IconGenerator <output.iconset directory>"
        }
    }
}

// iconutil requires exactly these filenames inside the .iconset directory.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    guard CommandLine.arguments.count > 1 else { throw IconError.missingOutputDirectory }
    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for variant in variants {
        let url = outputDirectory.appendingPathComponent("\(variant.name).png")
        try writePNG(size: variant.size, to: url)
    }
    print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
