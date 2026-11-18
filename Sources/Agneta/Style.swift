// Agneta's visual language (design/proposal): Swedish restraint on native
// materials. Winter-sea blue accent, pine for running, amber for attention, quiet
// provider monograms, the connected-rings mark.
import AgnetaKit
import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(red: 0.55, green: 0.75, blue: 0.86, alpha: 1) : NSColor(red: 0.18, green: 0.37, blue: 0.48, alpha: 1) })
    /// The accent as a fill behind white text (a prominent button): deep enough in both modes for the label to read
    /// clearly (about 5:1 in dark mode, 6.5:1 in light). The accent itself, pale in dark mode, is for text and symbols
    /// on dark backgrounds; as a fill it made a default button look disabled.
    static let fill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(red: 0.20, green: 0.44, blue: 0.58, alpha: 1) : NSColor(red: 0.18, green: 0.37, blue: 0.48, alpha: 1) })
    static let running = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(red: 0.53, green: 0.79, blue: 0.64, alpha: 1) : NSColor(red: 0.25, green: 0.49, blue: 0.36, alpha: 1) })
    static let attention = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(red: 0.91, green: 0.71, blue: 0.42, alpha: 1) : NSColor(red: 0.66, green: 0.41, blue: 0.11, alpha: 1) })

    static func tile(_ kind: AccountKind) -> Color {
        switch kind {
        case .claude, .anthropicKey: Color(red: 0.87, green: 0.76, blue: 0.66)
        case .chatGPT, .openAIKey: Color(red: 0.72, green: 0.82, blue: 0.77)
        }
    }

    static func glyph(_ kind: AccountKind) -> Color {
        switch kind {
        case .claude, .anthropicKey: Color(red: 0.55, green: 0.33, blue: 0.2)
        case .chatGPT, .openAIKey: Color(red: 0.15, green: 0.36, blue: 0.29)
        }
    }
}

/// The two connected rings, drawn as a template image so the menu bar tints it.
enum Mark {
    /// Two linked rings: each passes over the other once, like links in a chain seen flat. `badge` adds the dot that
    /// says something needs the user; `hammer` the small hammer in the lower right corner that marks a development build
    /// (Agneta Dev), as its app icon has, so the two running side by side tell apart in the menu bar.
    static func image(size: CGFloat = 18, badge: Bool = false, hammer: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 24
            let radius = 5.6 * s, line = 1.9 * s
            let left = NSPoint(x: 8.6 * s, y: 12 * s), right = NSPoint(x: 15.4 * s, y: 12 * s)
            func ring(_ center: NSPoint, from start: CGFloat, to end: CGFloat) {
                let path = NSBezierPath()
                path.lineWidth = line
                path.lineCapStyle = .round
                path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
                path.stroke()
            }
            NSColor.black.setStroke()
            // Left ring, broken where the right ring passes over it (lower crossing).
            ring(left, from: -40, to: 290)
            // Right ring, broken where the left ring passes over it (upper crossing).
            ring(right, from: 140, to: 470)
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18.5 * s, y: 17.5 * s, width: 5.5 * s, height: 5.5 * s)).fill()
            }
            if hammer { Self.hammer(scale: s) }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The hammer, tilted, with a clear margin cut around it so it reads apart from the ring it overlaps.
    private static func hammer(scale s: CGFloat) {
        var transform = AffineTransform(translationByX: 20.2 * s, byY: 3.7 * s)
        transform.rotate(byRadians: -0.6)
        let handle = NSBezierPath(roundedRect: NSRect(x: -0.75 * s, y: -3.6 * s, width: 1.5 * s, height: 5.2 * s), xRadius: 0.75 * s, yRadius: 0.75 * s)
        // The head: a square face on the left, a claw tapering to a point on the right.
        let head = NSBezierPath()
        head.move(to: NSPoint(x: -3.4 * s, y: 0.9 * s))
        head.line(to: NSPoint(x: -1.1 * s, y: 0.9 * s))
        head.line(to: NSPoint(x: -1.1 * s, y: 1.6 * s))
        head.line(to: NSPoint(x: 3.2 * s, y: 1.1 * s))
        head.line(to: NSPoint(x: 1.2 * s, y: 3.2 * s))
        head.line(to: NSPoint(x: -1.1 * s, y: 3.2 * s))
        head.line(to: NSPoint(x: -1.1 * s, y: 3.9 * s))
        head.line(to: NSPoint(x: -3.4 * s, y: 3.9 * s))
        head.close()
        let shape = NSBezierPath()
        shape.append(handle)
        shape.append(head)
        shape.transform(using: transform)
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        shape.lineWidth = 2.4 * s
        shape.lineJoinStyle = .round
        NSColor.black.setStroke()
        shape.stroke()
        context.restoreGraphicsState()
        NSColor.black.setFill()
        shape.fill()
    }
}




extension Date {
    var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60)) min"
    }
}
