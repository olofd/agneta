// Draws Agneta's app icon: the menu bar's two linked rings, flat ice-white on flat fjord blue. Nordic and quiet: two
// colours, no gradients, no texture, the over-and-under crossings drawn as clean gaps. Written as code so the design
// can be tuned and every size redrawn from one place.
//   swift scripts/dev/app-icon.swift <out.png> [size]      one PNG (default 1024)
//   scripts/dev/app-icon <out.icns>                        every size, packed with iconutil
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = URL(filePath: args.count > 1 ? args[1] : "AppIcon.png")
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
/// Optical sizing, as Apple's own icons do: at 32 pixels and below, bolder rings.
let small = size <= 32

/// The two colours: fjord blue (a deeper shade of Agneta's accent) and ice white.
let fjord: UInt32 = 0x1f4b66, ice: UInt32 = 0xeef6fa

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

// The icon's own shadow, as the grid expects (macOS draws it under every icon of this shape), then the flat body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x0b2233, 0.3))
ctx.addPath(shape)
ctx.setFillColor(color(fjord))
ctx.fillPath()
ctx.restoreGState()

// The rings: the menu bar mark's geometry (24-point grid: radius 5.6, centres 6.8 apart, line 1.9), scaled up.
let unit: CGFloat = 30
let radius = 5.6 * unit, line = 1.9 * unit * (small ? 1.45 : 1.1), gap = 0.6 * unit
let centre = CGPoint(x: 512, y: 512)
let left = CGPoint(x: centre.x - 3.4 * unit, y: centre.y), right = CGPoint(x: centre.x + 3.4 * unit, y: centre.y)

func ring(_ c: CGPoint, from start: CGFloat = 0, to end: CGFloat = 360) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: c, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
    return path
}

/// A ring, or a stretch of one, in flat ice white.
func paint(_ c: CGPoint, from start: CGFloat = 0, to end: CGFloat = 360) {
    ctx.addPath(ring(c, from: start, to: end))
    ctx.setLineWidth(line)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(color(ice))
    ctx.strokePath()
}

// Rings on their own layer, so the over-crossing can cut a gap into the ring beneath it.
ctx.saveGState()
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
paint(left)
paint(right)
// Like the mark: the left ring passes over the right at the upper crossing, the right over the left at the lower
// one. In flat colour a crossing only reads with a gap, so each over-stretch cuts one into the ring beneath it,
// then is drawn on top.
func cross(over c: CGPoint, from start: CGFloat, to end: CGFloat) {
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    ctx.addPath(ring(c, from: start + 4, to: end - 4))
    ctx.setLineWidth(line + 2 * gap)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(color(0x000000))
    ctx.strokePath()
    ctx.restoreGState()
    paint(c, from: start, to: end)
}
cross(over: left, from: 18, to: 88)
cross(over: right, from: 198, to: 268)
ctx.endTransparencyLayer()
ctx.restoreGState()

let image = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: out)
print(out.path(percentEncoded: false))
