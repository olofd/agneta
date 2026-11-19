// Draws the DMG window's background: the app icon's summer evening, muted to a dusk so the icon names Finder draws
// over it (black in light mode, white in dark) both read (about 4.9:1 and 4.3:1 under them), with an arrow from
// Agneta to Applications and what to do next. 660 × 400 points, the window scripts/dev/dmg-layout sets up.
//   swift scripts/dev/dmg-background.swift <out.png> <scale: 1 or 2>
import AppKit

let out = URL(filePath: CommandLine.arguments[1])
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = CGSize(width: 660, height: 400)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size // points, so Finder lays it out at 660 × 400 whatever the pixels
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// The rep's size in points already scales drawing to its pixels.
let ctx = NSGraphicsContext.current!.cgContext

// Dusk, corner to corner: a warmer rose top left to a deeper violet bottom right, the middle band (where the names
// sit, y ≈ 120 from the bottom) at the mid-tone.
let dusk = CGGradient(
    colorsSpace: space, colors: [color(0xa8728c), color(0x8f6f99), color(0x6f5d94)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(dusk, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
// The low sun's glow behind Agneta, and a faint sheen from above.
let glow = CGGradient(
    colorsSpace: space, colors: [color(0xffd9b8, 0.35), color(0xffd9b8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 165, y: 215), startRadius: 0, endCenter: CGPoint(x: 165, y: 215), endRadius: 170,
    options: [])
let sheen = CGGradient(
    colorsSpace: space, colors: [color(0xffffff, 0.12), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    sheen, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height - 140), options: [])

// The arrow, between the two icons (centres at x 165 and 495, y 215 from the bottom): a soft curve and a head.
ctx.setStrokeColor(color(0xffffff, 0.85))
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 262, y: 222))
arrow.addQuadCurve(to: CGPoint(x: 392, y: 222), control: CGPoint(x: 327, y: 252))
ctx.addPath(arrow)
ctx.strokePath()
let head = CGMutablePath()
head.move(to: CGPoint(x: 376, y: 238))
head.addLine(to: CGPoint(x: 394, y: 222))
head.addLine(to: CGPoint(x: 372, y: 213))
ctx.addPath(head)
ctx.strokePath()

// What to do, centred low in the window.
func text(_ string: String, y: CGFloat, size points: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(
        string: string,
        attributes: [
            .font: NSFont.systemFont(ofSize: points, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: style
        ])
    attributed.draw(in: CGRect(x: 0, y: y, width: size.width, height: points * 1.5))
}
text("Drag Agneta to Applications to install it.", y: 62, size: 15, weight: .semibold, alpha: 0.95)
text(
    "Then open it from Applications: it lives in the menu bar, beside the clock.", y: 38, size: 12, weight: .regular,
    alpha: 0.8)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path(percentEncoded: false))
