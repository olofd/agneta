// Agneta: a menu bar app. No Dock icon (LSUIElement); the glass panel lives
// under the linked-rings symbol beside the clock (StatusItemController).
import AppKit
import os
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
            model.updates.start(model)
            if model.accounts.isEmpty { WindowPresenter.shared.showWelcome(model) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Every quit comes here (the menu, Sparkle, a logout, AppleScript). The engines stop off the main actor, and
        // the answer goes back as a run-loop block: AppKit waits for it in a nested loop that may sit inside a
        // main-queue job, where neither main-actor work nor the main queue can run. Waiting on the main actor here hung
        // the menu's Quit forever. Should stopping hang, Agneta quits after 10 s anyway.
        let rest = model.beginStopping()
        let answered = OSAllocatedUnfairLock(initialState: false)
        @Sendable func answer() {
            guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        Task.detached { await rest(); answer() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { answer() }
        return .terminateLater
    }
}
