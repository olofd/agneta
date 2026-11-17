// Agneta: a menu bar app. No Dock icon (LSUIElement); the glass panel lives
// under the linked-rings symbol beside the clock (StatusItemController).
import AppKit
import SwiftUI

@main
struct AgnetaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All windows are AppKit (StatusItemController, WindowPresenter); SwiftUI needs one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows most of the time, which macOS reads as idle: Automatic Termination ended
        // Agneta about 5 s after a launch with no window open, taking apps' tasks with it.
        ProcessInfo.processInfo.disableAutomaticTermination("Agneta serves apps from the menu bar")
        if Snapshots.runIfRequested(model) { return }
        statusItem = StatusItemController(model: model)
        Task {
            await model.start()
            if model.accounts.isEmpty { WindowPresenter.shared.showWelcome(model) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Engines are stopped by WindowPresenter.quit; a system logout also stops them here.
        Task {
            await model.stopEverything()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
