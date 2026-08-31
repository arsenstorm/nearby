// Renders the app icon: the status dot with its ripples on a dark ground.
//   swift scripts/make-icon.swift [out.png]
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset/icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let green = [0.20, 0.84, 0.40]
func rgba(_ c: [Double], _ a: Double) -> CGColor { CGColor(colorSpace: space, components: [c[0], c[1], c[2], a])! }

// Ground
ctx.setFillColor(rgba([0.05, 0.05, 0.06], 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
// Radial glow, like the in-app background
let center = CGPoint(x: size / 2, y: size / 2)
let glow = CGGradient(colorsSpace: space, colors: [rgba(green, 0.30), rgba(green, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * 0.58, options: [])

// Ripples
let dotRadius = size * 0.105
for (i, alpha) in [0.55, 0.32, 0.16].enumerated() {
    let r = dotRadius + size * 0.085 * Double(i + 1) + size * 0.04
    ctx.setStrokeColor(rgba(green, alpha))
    ctx.setLineWidth(size * 0.012)
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}

// Dot: soft halo, then a radial core
let halo = CGGradient(colorsSpace: space, colors: [rgba(green, 0.45), rgba(green, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: center, startRadius: dotRadius * 0.9, endCenter: center, endRadius: dotRadius * 1.9, options: [])
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius))
ctx.clip()
let core = CGGradient(colorsSpace: space, colors: [rgba([0.55, 0.95, 0.65], 1), rgba(green, 1), rgba([0.12, 0.62, 0.30], 1)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawRadialGradient(core, startCenter: CGPoint(x: center.x - dotRadius * 0.3, y: center.y + dotRadius * 0.3), startRadius: 0,
                       endCenter: center, endRadius: dotRadius * 1.1, options: [.drawsAfterEndLocation])
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
