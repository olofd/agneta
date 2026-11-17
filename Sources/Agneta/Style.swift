// Agneta's visual language (design/proposal): Nordic restraint on native
// materials. Fjord-blue accent, pine for running, amber for attention, quiet
// provider monograms, the connected-rings mark.
import AgnetaKit
import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(red: 0.55, green: 0.75, blue: 0.86, alpha: 1) : NSColor(red: 0.18, green: 0.37, blue: 0.48, alpha: 1) })
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
    /// Two linked rings: each passes over the other once, like links in a chain seen flat.
    static func image(size: CGFloat = 18, badge: Bool = false) -> NSImage {
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
            return true
        }
        image.isTemplate = true
        return image
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
