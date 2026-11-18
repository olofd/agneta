// Design review with real Liquid Glass: AGNETA_SHOWCASE=<seconds> opens the
// panel (in a glass window shaped like the menu bar panel) and every dialog
// with sample data, prints each window's number for `screencapture -l`, and
// quits after the given time. Nothing is stored or connected.
import AgnetaKit
import AppKit
import SwiftUI

@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["AGNETA_SHOWCASE"], let seconds = Double(raw) else { return false }
        if let mode = ProcessInfo.processInfo.environment["AGNETA_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        model.loadSample()
        let presenter = WindowPresenter.shared
        showBackdrop()
        presenter.showPanelPreview(model)
        presenter.showApproval(model, request: model.approval?.id ?? UUID())
        presenter.showSignIn(model, attempt: UUID())
        presenter.showWelcome(model) // after sign-in, which closes the welcome window
        // AGNETA_SHOWCASE_PANE picks the Settings pane, e.g. Activity or Privacy.
        let paneName = ProcessInfo.processInfo.environment["AGNETA_SHOWCASE_PANE"]
        let pane = paneName.flatMap { SettingsView.Pane(rawValue: $0) } ?? .providers
        presenter.showSettings(model, section: pane)
        // "Details" shows a task's details window from a sample trace, only in an isolated home.
        if paneName == "Details", ProcessInfo.processInfo.environment["AGNETA_HOME"] != nil {
            try? FileManager.default.createDirectory(at: model.store.tracesFolder, withIntermediateDirectories: true)
            try? TraceExport.write(sampleTrace, to: model.traceFile("sample"), redactContent: false)
            presenter.showDetails(model, task: "sample", title: "Drafting release notes")
            if let details = presenter.window("details-sample") { presenter.register("settings", details) }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        var x = screen.minX + 20
        for key in ["panel", "welcome", "approval", "signin"] {
            guard let window = presenter.window(key) else { continue }
            window.setFrameTopLeftPoint(NSPoint(x: x, y: screen.maxY - 20))
            x += window.frame.width + 20
        }
        presenter.window("settings")?.setFrameTopLeftPoint(NSPoint(x: screen.minX + 20, y: screen.maxY - 600))
        let out = ProcessInfo.processInfo.environment["AGNETA_SHOWCASE_OUT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let suffix = ProcessInfo.processInfo.environment["AGNETA_APPEARANCE"] ?? "system"
        // One window at a time becomes key, as it would in use, so buttons show their active tint.
        // Each line says where a capture went or why it failed; the app quits after the last one.
        NSApp.activate()
        let keys = ["panel", "welcome", "approval", "signin", "settings"]
        let step = 0.8, first = 1.5, settle = 0.5
        for (index, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + first + Double(index) * step) {
                guard let window = presenter.window(key) else { return }
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    var line = "\(key) \(window.windowNumber)"
                    if let out {
                        line += "  " + capture(window, to: out.appending(path: "\(key)-\(suffix).png"))
                        line += "  " + captureOverBackdrop(window, to: out.appending(path: "\(key)-\(suffix)-glass.png"))
                    }
                    print(line)
                    fflush(stdout)
                }
            }
        }
        let lastCapture = first + Double(keys.count - 1) * step + settle + 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, lastCapture)) { exit(0) }
        return true
    }
}

/// An app may capture its own windows without Screen Recording permission.
@available(macOS, deprecated: 14.0, message: "Design review only; ScreenCaptureKit needs a permission prompt")
@MainActor private func capture(_ window: NSWindow, to file: URL) -> String {
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
        return "window capture failed"
    }
    return write(image, to: file)
}

/// The window composited over whatever is below it on screen (the showcase backdrop), so
/// the glass blur shows.
@available(macOS, deprecated: 14.0, message: "Design review only")
@MainActor private func captureOverBackdrop(_ window: NSWindow, to file: URL) -> String {
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let frame = window.frame.insetBy(dx: -24, dy: -24)
    let rect = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    guard let image = CGWindowListCreateImage(rect, [.optionOnScreenBelowWindow, .optionIncludingWindow], CGWindowID(window.windowNumber), [.bestResolution]) else {
        return "glass capture failed (needs Screen Recording for the launching app)"
    }
    return write(image, to: file)
}

private func write(_ image: CGImage, to file: URL) -> String {
    do {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "PNG encoding failed" }
        try png.write(to: file)
        return file.path(percentEncoded: false)
    } catch {
        return "write failed: \(error.localizedDescription)"
    }
}

/// A soft, colourful desktop-like backdrop behind the showcase windows.
@MainActor private func showBackdrop() {
    let frame = NSScreen.main?.frame ?? .zero
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .normal
    window.contentView = NSHostingView(rootView: Backdrop())
    window.orderFront(nil)
    WindowPresenter.shared.register("backdrop", window)
}

private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.47), Color(red: 0.55, green: 0.69, blue: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.93, green: 0.55, blue: 0.38)).frame(width: 520).offset(x: -380, y: -220).blur(radius: 40)
            Circle().fill(Color(red: 0.36, green: 0.62, blue: 0.48)).frame(width: 600).offset(x: 360, y: 180).blur(radius: 50)
            Circle().fill(Color(red: 0.98, green: 0.86, blue: 0.55)).frame(width: 380).offset(x: 80, y: -280).blur(radius: 30)
            Text("Agneta").font(.system(size: 160, weight: .heavy)).foregroundStyle(.white.opacity(0.35)).offset(y: 120)
            // AGNETA_BACKDROP=text: a busy page of text behind the windows, the hardest case for reading glass.
            if ProcessInfo.processInfo.environment["AGNETA_BACKDROP"] == "text" {
                Color(white: 0.12)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<40, id: \.self) { n in
                        Text(n % 5 == 0 ? "What's happening with Field Notes? Version 1.2 is due Thursday." : "Offline search and PDF export are ready to announce; shared folders stay out.")
                            .font(.system(size: n % 5 == 0 ? 34 : 17, weight: n % 5 == 0 ? .bold : .regular)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
    }
}

extension WindowPresenter {
    /// The menu bar panel's content in a glass window of the same shape, for design review.
    func showPanelPreview(_ model: AppModel) {
        let host = NSHostingView(rootView: PanelView(model: model))
        let size = host.fittingSize
        let window = GlassPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = GlassBackground.make(content: host, cornerRadius: 22)
        window.orderFrontRegardless()
        register("panel", window)
    }
}

/// A task's trace in miniature, for the details window's design review.
private let sampleTrace: [JSONValue] = {
    var records: [JSONValue] = [
        ["type": "meta", "app": ["name": "Example App"], "account": ["label": "Claude", "billing": "subscription"],
         "engine": ["info": ["name": "goose", "version": "1.59.2"], "dedicated": true], "policy": ["tools": "workspace", "network": "none"]],
    ]
    for (n, calls) in [(1, 3), (2, 5), (3, 2)] {
        for c in 0..<calls {
            records.append(["type": "event", "kind": "tool-call", "call": .string("c\(n)\(c)"), "tool": c % 2 == 0 ? "search" : "read_note", "extension": "app"])
            records.append(["type": "event", "kind": "tool-result", "call": .string("c\(n)\(c)"), "ms": .double(Double(400 + 300 * c)), "isError": .bool(n == 2 && c == 3)])
        }
        records.append(["type": "event", "kind": "model-call", "input": 23_000, "output": 900, "cacheRead": 21_000])
        records.append(["type": "event", "kind": "turn", "n": .int(Int64(n)), "stopReason": n == 3 ? "cancelled" : "end_turn", "ms": .double(Double(41_000 * n)),
                        "msToFirstToken": 4_200, "modelCalls": .int(Int64(calls + 1)), "ledger": ["input": 23_000, "output": 900], "cost": .double(0.12 * Double(n))])
    }
    records.append(["type": "shell", "command": "python3 fit.py", "exit": 0])
    records.append(["type": "permission", "decision": "allowed-by-policy"])
    records.append(["type": "lifecycle", "event": "queued"])
    records.append(["type": "lifecycle", "event": "stop", "by": "user"])
    records.append(["type": "end"])
    return records
}()
