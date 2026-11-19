// Agneta started from its disk image (or from a download macOS translocated) offers to move itself to Applications and
// open again from there. Apps open Agneta through its URL scheme, and a copy on a disk image is gone once the image is
// ejected: measured, a forced eject leaves it serving for about a second and then it dies with SIGBUS, taking every
// app's tasks with it. The usual pattern (as LetsMove does it), with no dependency: copy the bundle, put a downloaded
// original in the Trash (a disk image's stays: it's read-only), relaunch the copy once this process has quit, quit.
// Measured, copying the 43 MB bundle off a freshly mounted disk image takes 0.2 s, so it runs without a progress
// window. Development builds and isolated instances never ask.
import AgnetaKit
import AppKit
import Darwin

/// Where a running copy of Agneta is, as far as moving it is concerned.
enum AppPlacement: Equatable {
    /// `/Applications` or `~/Applications`: where apps expect it.
    case applications
    /// On a read-only volume under `/Volumes`: a disk image, gone once ejected.
    case diskImage
    /// Run by macOS from a randomized read-only mount (App Translocation), because it hasn't been moved since it was
    /// downloaded.
    case translocated
    /// Anywhere else (a build folder, an external drive): left alone.
    case elsewhere

    static func of(_ path: String, home: String, readOnlyVolume: Bool) -> AppPlacement {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path.contains("/AppTranslocation/") { return .translocated }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == "/Applications" || parent == "\(home)/Applications" { return .applications }
        if path.hasPrefix("/Volumes/") && readOnlyVolume { return .diskImage }
        return .elsewhere
    }

    /// Whether to offer the move.
    var offersMove: Bool { self == .diskImage || self == .translocated }

    /// Whether the original goes to the Trash once copied: a download macOS translocated (so LaunchServices can't later
    /// open that copy for `agneta://`, translocated again or older), never one on a read-only volume (a disk image).
    func trashesOriginal(onReadOnlyVolume: Bool) -> Bool { self == .translocated && !onReadOnlyVolume }
}

@MainActor
enum MoveToApplications {
    /// Set by the alert's "Don't ask again".
    static let suppressedKey = "MoveToApplicationsSuppressed"

    /// The folder to move into: `/Applications` when this user may write there, else `~/Applications`.
    nonisolated static func destinationFolder(applicationsWritable: Bool, home: URL) -> URL {
        applicationsWritable ? URL(filePath: "/Applications", directoryHint: .isDirectory)
            : home.appending(path: "Applications", directoryHint: .isDirectory)
    }

    /// `/bin/sh`'s arguments to open `app` once process `pid` has ended. Both go as arguments, never into the script.
    nonisolated static func relaunchArguments(pid: Int32, app: URL) -> [String] {
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", "agneta-relaunch",
         String(pid), app.path(percentEncoded: false)]
    }

    /// Asks, when Agneta runs from its disk image or translocated, whether to move it to Applications; on a yes, moves
    /// it and quits so the copy in Applications opens. Returns true when Agneta is quitting for that.
    static func offerIfNeeded(_ model: AppModel) -> Bool {
        guard !model.isDevelopment, !model.isIsolated, !UserDefaults.standard.bool(forKey: suppressedKey) else { return false }
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let placement = AppPlacement.of(bundle.path(percentEncoded: false), home: NSHomeDirectory(), readOnlyVolume: readOnly)
        guard placement.offersMove else { return false }
        let folder = destinationFolder(applicationsWritable: FileManager.default.isWritableFile(atPath: "/Applications"),
                                       home: FileManager.default.homeDirectoryForCurrentUser)
        let destination = folder.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
        // Another Agneta already running from there serves apps; this copy couldn't take its port anyway.
        if NSRunningApplication.runningApplications(withBundleIdentifier: model.bundleID)
            .contains(where: { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }) {
            model.log.log("move-to-applications", ["outcome": "another-running"])
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Move Agneta to Applications?"
        alert.informativeText = placement == .diskImage
            ? "Agneta is running from its disk image. Apps open Agneta from your Applications folder, and this copy goes away when the disk image is ejected. Agneta can move itself there and open again."
            : "Agneta is running from where it was downloaded, which macOS treats as temporary. Apps open Agneta from your Applications folder. Agneta can move itself there and open again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressedKey) }
        guard answer == .alertFirstButtonReturn else {
            model.log.log("move-to-applications", ["outcome": "declined", "placement": .string("\(placement)")])
            return false
        }
        // A translocated copy runs from a random read-only mount; the download itself is where macOS found it.
        let original = placement == .translocated ? originalURL(ofTranslocated: bundle) : nil
        do {
            try move(bundle, to: destination, bundleID: model.bundleID)
        } catch {
            model.log.error("move-to-applications", ["outcome": "failed", "reason": .string("\(error)")])
            let failed = NSAlert()
            failed.messageText = "Agneta couldn't move itself"
            failed.informativeText = "\(error.localizedDescription)\n\nQuit Agneta, drag it into Applications yourself, and open it from there."
            failed.runModal()
            return false
        }
        model.log.log("move-to-applications", ["outcome": "moved", "folder": .string(folder.path(percentEncoded: false))])
        if let original, original.standardizedFileURL != destination.standardizedFileURL,
           placement.trashesOriginal(onReadOnlyVolume: (try? original.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true),
           Bundle(url: original)?.bundleIdentifier == model.bundleID {
            do {
                try FileManager.default.trashItem(at: original, resultingItemURL: nil)
                model.log.log("move-to-applications", ["original": "trashed"])
            } catch {
                model.log.error("move-to-applications", ["original": "kept", "reason": .string("\(error)")])
            }
        }
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, app: destination)
        do {
            try relaunch.run()
        } catch {
            model.log.error("move-to-applications", ["outcome": "relaunch-failed", "reason": .string("\(error)")])
        }
        NSApp.terminate(nil)
        return true
    }

    /// Copies the bundle into place: an older Agneta there goes to the Trash first; anything else there is left alone.
    private static func move(_ bundle: URL, to destination: URL, bundleID: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            guard Bundle(url: destination)?.bundleIdentifier == bundleID else {
                throw MoveError("Something else named \(destination.lastPathComponent) is already in \(destination.deletingLastPathComponent().path(percentEncoded: false)).")
            }
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: bundle, to: destination)
        // The copy keeps the download's quarantine mark. The user has already opened this signed, notarized bundle, so
        // macOS's "downloaded from the Internet" question would only be asked again: the mark goes from this copy only.
        removeQuarantine(destination)
    }

    /// Where macOS translocated this bundle from (Security's `SecTranslocateCreateOriginalPathForURL`, looked up at run
    /// time as LetsMove does: it isn't in the public headers). Nil when it can't say.
    private static func originalURL(ofTranslocated url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(security) }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    private static func removeQuarantine(_ root: URL) {
        let paths = [root] + ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
        for url in paths { _ = removexattr(url.path(percentEncoded: false), "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    struct MoveError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
