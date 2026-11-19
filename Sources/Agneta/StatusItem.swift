// The menu bar symbol and its panel. Our own NSStatusItem + glass NSPanel
// instead of MenuBarExtra, so the panel is real see-through Liquid Glass
// (blurred desktop behind it), sized to its content, placed under the symbol,
// and closed by a click elsewhere or Escape.
import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private var panel: NSPanel?
    private var host: NSView?
    private var outsideClicks: Any?
    private var escape: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.image = Mark.image(size: 18, hammer: model.isDevelopment)
        item.button?.setAccessibilityLabel(model.isDevelopment ? "Agneta Dev" : "Agneta")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        observeAttention()
    }

    private var announced: String?

    /// Keeps the badge dot in step with the model, and tells VoiceOver when something starts needing the user.
    private func observeAttention() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            item.button?.image = Mark.image(size: 18, badge: model.needsAttention, hammer: model.isDevelopment)
            let title = model.attentionMessage?.title
            if let title, title != announced {
                NSAccessibility.post(
                    element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Agneta: \(title)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
                )
            }
            announced = title
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAttention() }
        }
    }

    @objc func toggle() {
        if let panel, panel.isVisible { close() } else { open() }
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        item.button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escape { NSEvent.removeMonitor(escape) }
        outsideClicks = nil
        escape = nil
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(
            rootView: PanelView(
                model: model, dismiss: { [weak self] in self?.close() },
                resized: { [weak self] in self?.contentResized() }))
        host.sizingOptions = [.intrinsicContentSize] // so fittingSize measures the SwiftUI content
        self.host = host
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = GlassBackground.make(content: host, cornerRadius: 22)
        return panel
    }

    /// The panel's content grew or shrank (a task started, an account was added): it keeps fitting.
    private func contentResized() {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    /// Under the symbol, kept on screen, the size of its SwiftUI content. Measured from the hosting view: the glass
    /// view around it reports a fitting size of zero, which made the panel a 0×0 window whose content took no clicks.
    private func position(_ panel: NSPanel) {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = host?.fittingSize ?? panel.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(
            NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        // A borderless window's shadow follows the shape it had when the shadow was made: after a resize it's made
        // again, or an outline of the old size shows around the rounded glass.
        panel.invalidateShadow()
    }
}

/// A borderless panel that can still take keyboard focus (text fields, Escape).
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Real glass behind content: Liquid Glass on macOS 26, a behind-window blur before.
enum GlassBackground {
    enum Surface {
        /// The menu bar panel: frosted glass with a light tint of the window colour. What's behind it shows as colour
        /// and shape, never as text that competes with the panel's own (clear glass let a browser's tabs read through).
        case panel
        /// A dialog that asks the user to read and decide: frosted and tinted, so what's behind it never competes
        /// with its text, even while it's in front (clear glass is for media, not text).
        case dialog
    }

    @MainActor static func make(content: NSView, cornerRadius: CGFloat, surface: Surface = .panel) -> NSView {
        let content = EveningGlow.wrapping(content)
        // With Reduce Transparency, a visual effect view, which macOS draws opaque.
        if #available(macOS 26, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = NSGlassEffectView()
            switch surface {
            case .panel:
                // For design review: AGNETA_GLASS=clear shows the old see-through style, AGNETA_PANEL_TINT=<0…1> tries
                // another strength of tint.
                let environment = ProcessInfo.processInfo.environment
                glass.style = environment["AGNETA_GLASS"] == "clear" ? .clear : .regular
                let tint = environment["AGNETA_PANEL_TINT"].flatMap(Double.init).map { min(max($0, 0), 1) } ?? 0.35
                if glass.style == .regular { glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(tint) }
            case .dialog:
                glass.style = .regular
                glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5)
            }
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            // Its layer clipped to the same rounded shape: a borderless window's shadow follows the shape of what it
            // draws, and the glass view's own layer is a rectangle, which showed as a square dark outline around the
            // rounded panel (measured: gone with this, the shadow following the corner).
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }
}
