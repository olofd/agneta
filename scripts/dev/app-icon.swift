// Draws Agneta's app icon: the menu bar's two linked rings, warm white on a Swedish summer evening (coral sky going
// pink, then violet, with the low sun's glow behind the rings). The over-and-under crossings are clean gaps. On macOS 26
// the rings are the glass layer of a Liquid Glass icon (packaging/AppIcon.icon) over the evening as its background
// layer, which the system lights; older macOS gets these drawings, flattened by actool.
// Written as code so the design can be tuned and every size redrawn from one place.
//   swift scripts/dev/app-icon.swift <out.png> [size]           the whole icon, flat (default 1024)
//   swift scripts/dev/app-icon.swift <out.png> 1024 rings       only the rings, full-bleed, for the Liquid Glass layer
//   swift scripts/dev/app-icon.swift <out.png> 1024 background  only the evening, full-bleed, for the layer beneath
//   swift scripts/dev/app-icon.swift <out.png> 1024 hammer  only the development build's hammer, for its own layer
//   scripts/dev/app-icon                                     everything, see there
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = URL(filePath: args.count > 1 ? args[1] : "AppIcon.png")
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
/// Optical sizing, as Apple's own icons do: at 32 pixels and below, bolder rings.
let small = size <= 32
/// Only the rings, on a transparent canvas where the whole canvas is the icon's body (Icon Composer's layout).
let ringsOnly = args.count > 3 && args[3] == "rings"
/// Only the hammer that marks a development build (Agneta Dev), on the same canvas: low on the right, clear of the rings.
let hammerOnly = args.count > 3 && args[3] == "hammer"
/// Only the background, filling the canvas (the icon's body in Icon Composer's layout).
let backgroundOnly = args.count > 3 && args[3] == "background"

/// The evening, top left to bottom right: coral, rose, violet; the sun's warm glow; the rings' warm white.
let evening: [(UInt32, CGFloat)] = [(0xff9a5a, 0), (0xff5f7e, 0.55), (0x8b3dff, 1)]
let sun: UInt32 = 0xfff1d6, ice: UInt32 = 0xfffaf6

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Apple's icon grid: an 824-point body on a 1024 canvas with 185-point continuous corners.
func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// The icon's own shadow, as the grid expects (macOS draws it under every icon of this shape), then the flat body.
if hammerOnly {
    drawHammer()
    write()
    exit(0)
}
if backgroundOnly {
    drawEvening(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    write()
    exit(0)
}
if !ringsOnly {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x3a0f3f, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(color(evening[1].0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawEvening(in: body)
    ctx.restoreGState()
}
// The rings layer fills Icon Composer's whole canvas, which is the body, so it's drawn larger by the body's ratio.
if ringsOnly {
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
    ctx.translateBy(x: -512, y: -512)
}

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

write()

/// The evening sky across `rect`: the gradient corner to corner, the sun's glow behind where the rings sit, and a faint
/// sheen from above, as on glass.
func drawEvening(in rect: CGRect) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(
        colorsSpace: space, colors: evening.map { color($0.0) } as CFArray, locations: evening.map(\.1))!
    ctx.drawLinearGradient(
        sky, start: CGPoint(x: rect.minX + 0.02 * rect.width, y: rect.maxY - 0.02 * rect.height),
        end: CGPoint(x: rect.maxX - 0.03 * rect.width, y: rect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: space, colors: [color(sun, 0.45), color(sun, 0)] as CFArray, locations: [0, 1])!
    let centre = CGPoint(x: rect.midX, y: rect.midY - 0.015 * rect.height)
    ctx.drawRadialGradient(
        glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 0.52 * rect.width, options: [])
    let sheen = CGGradient(
        colorsSpace: space, colors: [color(0xffffff, 0.18), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        sheen, start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.maxY - 0.44 * rect.height), options: [])
}

/// The development build's mark: a small claw hammer in the rings' warm white, tilted as if mid-swing, in the lower right
/// corner where the rings leave room, against the evening's violet, so it reads at a glance, even at Dock size.
func drawHammer() {
    let paint: UInt32 = ice
    ctx.saveGState()
    ctx.translateBy(x: 806, y: 132)
    ctx.scaleBy(x: 0.66, y: 0.66)
    ctx.rotate(by: -0.4)
    ctx.setFillColor(color(paint))
    // The handle, then the head across its top: a square face on the left, a short claw on the right.
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: -34, y: -190, width: 68, height: 270), cornerWidth: 30, cornerHeight: 30,
            transform: nil))
    ctx.fillPath()
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: -150, y: 54, width: 96, height: 124), cornerWidth: 18, cornerHeight: 18,
            transform: nil))
    ctx.fillPath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: -64, y: 74))
    head.addLine(to: CGPoint(x: 70, y: 74))
    head.addQuadCurve(to: CGPoint(x: 150, y: 48), control: CGPoint(x: 118, y: 72))
    head.addQuadCurve(to: CGPoint(x: 70, y: 158), control: CGPoint(x: 150, y: 140))
    head.addLine(to: CGPoint(x: -64, y: 158))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.fillPath()
    ctx.restoreGState()
}

func write() {
    let image = ctx.makeImage()!
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: out)
    print(out.path(percentEncoded: false))
}
