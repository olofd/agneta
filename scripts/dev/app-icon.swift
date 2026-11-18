// Draws Agneta's app icon: the menu bar's two linked rings, in frosted ice, on a deep fjord-blue winter sky with a
// faint aurora. Nordic and quiet: one light source from above, a few cold colours, a fine snow grain. Written as code so the design can be
// tuned and every size redrawn from one place.
//   swift scripts/dev/app-icon.swift <out.png> [size]      one PNG (default 1024)
//   scripts/dev/app-icon <out.icns>                        every size, packed with iconutil
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = URL(filePath: args.count > 1 ? args[1] : "AppIcon.png")
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
/// Optical sizing, as Apple's own icons do: at 32 pixels and below, bolder rings and no fine detail.
let small = size <= 32

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Apple's icon grid: an 824-point body on a 1024 canvas with 185-point continuous corners.
func squircle(_ rect: CGRect) -> CGPath { CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil) }

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// The icon's own shadow, as the grid expects: soft, below.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x0b2233, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x15354b))
ctx.fillPath()
ctx.restoreGState()

// A winter sky over a fjord: deep blue below, lighter towards the top, an aurora's faint green-cyan band.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [color(0x3d6f8f), color(0x1d4560), color(0x0d2436)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.saveGState()
ctx.translateBy(x: 512, y: 760)
ctx.rotate(by: -0.32)
ctx.scaleBy(x: 2.4, y: 0.55)
let aurora = CGGradient(colorsSpace: space, colors: [color(0x8fe3d2, 0.42), color(0x6fc7d9, 0.16), color(0x6fc7d9, 0)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawRadialGradient(aurora, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 260, options: [])
ctx.restoreGState()
// Light pooling behind the rings.
let glow = CGGradient(colorsSpace: space, colors: [color(0xbfe2f2, 0.28), color(0xbfe2f2, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0, endCenter: CGPoint(x: 512, y: 520), endRadius: 400, options: [])
// Snow grain: fine specks, fixed seed so every build draws the same icon.
var seed: UInt64 = 0x5eed_a6e7a
func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
for _ in 0..<(small ? 0 : 4200) {
    let x = 100 + random() * 824, y = 100 + random() * 824, r = 0.6 + random() * 1.4
    ctx.setFillColor(color(0xffffff, 0.04 + random() * 0.12))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
}
// Light from above on the glass edge.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xffffff, 0.32), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 850), options: [])
ctx.restoreGState()

// The rings: the menu bar mark's geometry (24-point grid: radius 5.6, centres 6.8 apart, line 1.9), scaled up.
let unit: CGFloat = 30
let radius = 5.6 * unit, line = 1.9 * unit * (small ? 1.45 : 1.05), gap = 0.55 * unit
let centre = CGPoint(x: 512, y: 512)
let left = CGPoint(x: centre.x - 3.4 * unit, y: centre.y), right = CGPoint(x: centre.x + 3.4 * unit, y: centre.y)

func ring(_ c: CGPoint, from start: CGFloat = 0, to end: CGFloat = 360) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: c, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
    return path
}

/// A ring (or a stretch of one) in fjord blue, lit from above, with thin frost-white edges.
func paint(_ c: CGPoint, from start: CGFloat = 0, to end: CGFloat = 360) {
    let stroke = ring(c, from: start, to: end).copy(strokingWithWidth: line, lineCap: .butt, lineJoin: .round, miterLimit: 1)
    ctx.saveGState()
    ctx.addPath(stroke)
    ctx.clip()
    // Frosted ice: white where the light falls, a cold blue below.
    let fjord = CGGradient(colorsSpace: space, colors: [color(0xffffff), color(0xe2f0f7), color(0xa9cbdf)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(fjord, start: CGPoint(x: 512, y: centre.y + radius + line), end: CGPoint(x: 512, y: centre.y - radius - line), options: [])
    // The edges, along the arc only (never across a cut end): brighter outside, where the light falls.
    for (offset, alpha) in (small ? [] : [(line / 2 - 2.5, 0.9), (-line / 2 + 2.5, 0.35)]) as [(CGFloat, CGFloat)] {
        let edge = CGMutablePath()
        edge.addArc(center: c, radius: radius + offset, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
        ctx.addPath(edge)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(color(0xffffff, alpha))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// Rings on their own layer, so the over-crossing can cut a gap into the ring beneath it.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x03111c, 0.6))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
paint(left)
paint(right)
// Like the mark: the left ring passes over the right at the upper crossing (the right ring passes over at the
// lower one, as already drawn). Cut a gap around that stretch of the left ring, then draw it on top.
let over = ring(left, from: 22, to: 84)
ctx.saveGState()
ctx.setBlendMode(.destinationOut)
ctx.addPath(over)
ctx.setLineWidth(line + 2 * gap)
ctx.setLineCap(.butt)
ctx.setStrokeColor(color(0x000000))
ctx.strokePath()
ctx.restoreGState()
paint(left, from: 18, to: 88)
ctx.endTransparencyLayer()
ctx.restoreGState()

let image = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: out)
print(out.path(percentEncoded: false))
