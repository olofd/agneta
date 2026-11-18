// Updates for release builds (docs/RELEASING.md, part 3). Sparkle reads this Mac's architecture's feed from the
// latest published GitHub release; build-app writes the feed and the EdDSA key updates are verified with into a
// release build's Info.plist. Development builds have no updater, so they never replace themselves; nor does an
// isolated instance, unless whoever started it gave it a feed to test the update path with (AGNETA_UPDATE_FEED). An update installs only when no task is running (or when Agneta quits): apps then reconnect and
// resume their tasks with session/load.
import AppKit
import Combine
import Sparkle

// Sparkle calls its user driver delegate on the main thread but its header doesn't say so; @preconcurrency checks
// that at run time.
@MainActor @Observable
final class Updates: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// nil when this build doesn't update itself: a development build, an isolated instance, or no feed or key.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var watchers: Set<AnyCancellable> = []
    @ObservationIgnored private var waiting: _Concurrency.Task<Void, Never>?

    var enabled: Bool { controller != nil }
    private(set) var canCheck = false
    /// A version a scheduled check found and is waiting for the user (gentle reminders: a menu bar app doesn't
    /// put a window in front of whatever the user is doing).
    private(set) var available: String?
    /// An update that is ready and waits for the running tasks to end; `installNow` doesn't wait.
    private(set) var waitingToInstall: String?
    @ObservationIgnored private var install: (() -> Void)?
    /// An isolated instance's test feed, in place of the release feed.
    @ObservationIgnored private var testFeed: String?

    /// Why this build has no updater, for Settings.
    private(set) var unavailableReason = "Development builds don't update themselves."

    func start(_ model: AppModel) {
        self.model = model
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? "", key = info["SUPublicEDKey"] as? String ?? ""
        if model.isDevelopment { return }
        if model.isIsolated {
            guard let feed = ProcessInfo.processInfo.environment["AGNETA_UPDATE_FEED"] else { unavailableReason = "An isolated instance doesn't update itself."; return }
            testFeed = feed
        }
        guard !feed.isEmpty, !key.isEmpty else { unavailableReason = "This build has no update feed."; return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &watchers)
        controller.startUpdater()
        model.log.log("updates-started", ["feed": .string(testFeed ?? feed), "automatic": .bool(controller.updater.automaticallyChecksForUpdates)])
    }

    func check() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue } }
    }

    var downloadsAutomatically: Bool {
        get { access(keyPath: \.downloadsAutomatically); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { withMutation(keyPath: \.downloadsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue } }
    }

    /// Installs the waiting update now; the caller has confirmed stopping the running tasks.
    func installNow() {
        guard let install else { return }
        waiting?.cancel()
        clearWaiting()
        model?.log.log("update-installing", ["reason": .string("user")])
        install()
    }

    // MARK: Installing only when no task is running

    private var busy: Bool { !(model?.tasks.isEmpty ?? true) }

    /// Holds `handler` until no task runs, then runs it.
    private func whenIdle(_ version: String, reason: String, _ handler: @escaping () -> Void) {
        waiting?.cancel()
        install = handler
        waitingToInstall = version
        model?.log.log("update-waiting", ["version": .string(version), "tasks": .int(Int64(model?.tasks.count ?? 0))])
        waiting = _Concurrency.Task { [weak self] in
            while let self, self.busy, !_Concurrency.Task.isCancelled { try? await _Concurrency.Task.sleep(for: .seconds(2)) }
            guard let self, !_Concurrency.Task.isCancelled else { return }
            self.clearWaiting()
            self.model?.log.log("update-installing", ["version": .string(version), "reason": .string(reason)])
            handler()
        }
    }

    private func clearWaiting() {
        install = nil
        waitingToInstall = nil
        waiting = nil
    }

    func feedURLString(for updater: SPUUpdater) -> String? { testFeed }

    // macOS would relaunch an isolated instance without its environment, as the user's own Agneta.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { testFeed == nil }

    // The user chose Install and Relaunch.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        whenIdle(item.displayVersionString, reason: "tasks-ended", installHandler)
        return true
    }

    // An automatic download is ready: install it once nothing runs rather than waiting for a quit, which a menu bar
    // app may not see for weeks.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        whenIdle(item.displayVersionString, reason: "automatic", immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model?.log.log("update-found", ["version": .string(item.displayVersionString), "build": .string(item.versionString)])
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        // "No update" ends a check this way too; it isn't a failure.
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) { return }
        model?.log.error("update-failed", ["domain": .string(error.domain), "code": .int(Int64(error.code)), "reason": .string(error.localizedDescription)])
    }

    // MARK: Gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { available = nil }

    func standardUserDriverWillFinishUpdateSession() { available = nil }
}
