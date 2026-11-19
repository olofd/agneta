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
        applicationsWritable
            ? URL(filePath: "/Applications", directoryHint: .isDirectory)
            : home.appending(path: "Applications", directoryHint: .isDirectory)
    }

    /// `/bin/sh`'s arguments to open `app` once process `pid` has ended. Both go as arguments, never into the script.
    nonisolated static func relaunchArguments(pid: Int32, app: URL) -> [String] {
        [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "agneta-relaunch",
            String(pid), app.path(percentEncoded: false)
        ]
    }

    /// A bundle's identifier and versions, read from its `Info.plist` (not `Bundle`, which caches by path).
    struct BundleInfo: Equatable {
        let identifier: String
        let version: String
        let build: String

        init?(_ app: URL) {
            guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let identifier = plist["CFBundleIdentifier"] as? String
            else { return nil }
            self.identifier = identifier
            version = plist["CFBundleShortVersionString"] as? String ?? "0"
            build = plist["CFBundleVersion"] as? String ?? "0"
        }

        /// Whether this is an older version than `other`: by `CFBundleShortVersionString`, then `CFBundleVersion`.
        nonisolated func isOlder(than other: BundleInfo) -> Bool {
            let byVersion = MoveToApplications.compare(version, other.version)
            return byVersion == .orderedAscending
                || (byVersion == .orderedSame && MoveToApplications.compare(build, other.build) == .orderedAscending)
        }
    }

    /// Dotted numbers compared number by number (`0.10` after `0.9`); missing parts are 0.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// What to offer, given what's already where this Agneta would go.
    enum Offer: Equatable {
        /// Nothing there, or an older Agneta: move this one there, replacing it.
        case move
        /// The same or a newer Agneta is there: open that one instead; it's never replaced by an older one.
        case openExisting
        /// Something that isn't Agneta is there: leave it alone, and offer nothing.
        case nothing
    }

    nonisolated static func offer(running: BundleInfo, atDestination: BundleInfo?, destinationExists: Bool) -> Offer {
        guard destinationExists else { return .move }
        guard let existing = atDestination, existing.identifier == running.identifier else { return .nothing }
        return existing.isOlder(than: running) ? .move : .openExisting
    }

    /// Asks, when Agneta runs from its disk image or translocated, whether to move it to Applications (or, when the same
    /// or a newer Agneta is already there, whether to open that one); on a yes, does it and quits so the copy in
    /// Applications opens. Returns true when Agneta is quitting for that.
    static func offerIfNeeded(_ model: AppModel) -> Bool {
        guard !model.isDevelopment, !model.isIsolated, !UserDefaults.standard.bool(forKey: suppressedKey) else {
            return false
        }
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let placement = AppPlacement.of(
            bundle.path(percentEncoded: false), home: NSHomeDirectory(), readOnlyVolume: readOnly)
        guard placement.offersMove, let running = BundleInfo(bundle) else { return false }
        let files = FileManager.default
        let folder = destinationFolder(
            applicationsWritable: files.isWritableFile(atPath: "/Applications"), home: files.homeDirectoryForCurrentUser
        )
        let destination = folder.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
        // A translocated copy runs from a random read-only mount; the download itself is where macOS found it. When that
        // is the destination already (a quarantined copy in Applications), Agneta is installed: nothing to move.
        let original = placement == .translocated ? originalURL(ofTranslocated: bundle) : nil
        if let original, original.standardizedFileURL == destination.standardizedFileURL { return false }
        // Another Agneta already running from there serves apps; this copy couldn't take its port anyway.
        if NSRunningApplication.runningApplications(withBundleIdentifier: model.bundleID)
            .contains(where: { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL })
        {
            model.log.log("move-to-applications", ["outcome": "another-running"])
            return false
        }
        var offer = offer(
            running: running, atDestination: BundleInfo(destination),
            destinationExists: files.fileExists(atPath: destination.path(percentEncoded: false)))
        var target = destination
        // A standard user moves into ~/Applications. A same or newer Agneta in /Applications (which they can't change)
        // is the one to open; an older one there stays, and LaunchServices may prefer it, so the alert says so.
        var olderInApplications = false
        let shared = URL(filePath: "/Applications/\(bundle.lastPathComponent)", directoryHint: .isDirectory)
        if folder.path(percentEncoded: false) != "/Applications/", let other = BundleInfo(shared),
            other.identifier == running.identifier
        {
            if other.isOlder(than: running) {
                olderInApplications = true
            } else if offer != .openExisting {
                offer = .openExisting
                target = shared
            }
        }
        guard offer != .nothing else {
            model.log.log("move-to-applications", ["outcome": "something-else-there"])
            return false
        }
        let alert = NSAlert()
        if offer == .openExisting {
            alert.messageText = "Open Agneta from Applications?"
            alert.informativeText =
                "Agneta \(BundleInfo(target)?.version ?? "") is already in Applications, the same as this copy (\(running.version)) or newer. Apps open that one. Agneta can open it and quit this copy."
            alert.addButton(withTitle: "Open Agneta in Applications")
        } else {
            alert.messageText = "Move Agneta to Applications?"
            alert.informativeText =
                (placement == .diskImage
                    ? "Agneta is running from its disk image. Apps open Agneta from your Applications folder, and this copy goes away when the disk image is ejected. Agneta can move itself there and open again."
                    : "Agneta is running from where it was downloaded, which macOS treats as temporary. Apps open Agneta from your Applications folder. Agneta can move itself there and open again.")
                + (olderInApplications
                    ? "\n\nAn older Agneta is in /Applications, which only an administrator can change, and apps may open that one: ask an administrator to remove it."
                    : "")
            alert.addButton(withTitle: "Move to Applications")
        }
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
        if offer == .move {
            do {
                try move(bundle, to: destination, bundleID: model.bundleID)
            } catch {
                model.log.error("move-to-applications", ["outcome": "failed", "reason": .string("\(error)")])
                let failed = NSAlert()
                failed.messageText = "Agneta couldn't move itself"
                failed.informativeText =
                    "\(error.localizedDescription)\n\nQuit Agneta, drag it into Applications yourself, and open it from there."
                failed.runModal()
                return false
            }
            model.log.log(
                "move-to-applications",
                [
                    "outcome": "moved", "folder": .string(folder.path(percentEncoded: false)),
                    "olderInApplications": .bool(olderInApplications)
                ])
            if let original, original.standardizedFileURL != destination.standardizedFileURL,
                placement.trashesOriginal(
                    onReadOnlyVolume: (try? original.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly)
                        ?? true),
                BundleInfo(original)?.identifier == model.bundleID
            {
                do {
                    try files.trashItem(at: original, resultingItemURL: nil)
                    model.log.log("move-to-applications", ["original": "trashed"])
                } catch {
                    model.log.error("move-to-applications", ["original": "kept", "reason": .string("\(error)")])
                }
            }
        } else {
            model.log.log("move-to-applications", ["outcome": "opened-existing"])
        }
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, app: target)
        do {
            try relaunch.run()
        } catch {
            model.log.error("move-to-applications", ["outcome": "relaunch-failed", "reason": .string("\(error)")])
        }
        NSApp.terminate(nil)
        return true
    }

    /// The file operations `move` uses, replaceable in tests (which mustn't fill the user's Trash or the disk).
    struct Files {
        var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        /// Moves an item out of the way and says where it went (the Trash), so it can be put back.
        var discard: (URL) throws -> URL? = { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return trashed as URL?
        }
    }

    /// Puts a copy of `bundle` at `destination` without ever leaving the user with no Agneta: it copies into a temporary
    /// sibling (on the same volume) and takes the quarantine mark off there; only once that's complete does an older
    /// Agneta at the destination go to the Trash and the copy take its name, and should the rename fail, the old one is
    /// put back. Anything there that isn't Agneta is refused, and so is copying a bundle onto itself.
    nonisolated static func move(
        _ bundle: URL, to destination: URL, bundleID: String, files operations: Files = Files()
    ) throws {
        let files = FileManager.default
        guard
            bundle.standardizedFileURL.resolvingSymlinksInPath()
                != destination.standardizedFileURL.resolvingSymlinksInPath()
        else {
            throw MoveError(
                "Agneta is already in \(destination.deletingLastPathComponent().path(percentEncoded: false)).")
        }
        let exists = files.fileExists(atPath: destination.path(percentEncoded: false))
        if exists, BundleInfo(destination)?.identifier != bundleID {
            throw MoveError(
                "Something else named \(destination.lastPathComponent) is already in \(destination.deletingLastPathComponent().path(percentEncoded: false))."
            )
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appending(
                path: ".\(destination.lastPathComponent).moving-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try operations.copy(bundle, temporary)
            // The copy keeps the download's quarantine mark. The user has already opened this signed, notarized bundle,
            // so macOS's "downloaded from the Internet" question would only be asked again: the mark goes from the copy.
            removeQuarantine(temporary)
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
        var trashed: URL?
        do {
            if exists { trashed = try operations.discard(destination) }
            try files.moveItem(at: temporary, to: destination)
        } catch {
            if let trashed, !files.fileExists(atPath: destination.path(percentEncoded: false)) {
                try? files.moveItem(at: trashed, to: destination)
            }
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    /// Where macOS translocated this bundle from (Security's `SecTranslocateCreateOriginalPathForURL`, looked up at run
    /// time as LetsMove does: it isn't in the public headers). Nil when it can't say.
    private static func originalURL(ofTranslocated url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(security) }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    nonisolated private static func removeQuarantine(_ root: URL) {
        let paths =
            [root]
            + ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
        for url in paths { _ = removexattr(url.path(percentEncoded: false), "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    struct MoveError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
