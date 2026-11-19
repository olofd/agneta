import Darwin
import Foundation
import Testing
@testable import Agneta

/// Getting installed: where a running copy is and whether it offers to move to Applications, and which windows replace
/// the first-run window.
@Suite struct InstallTests {
    @Test func placement() {
        let home = "/Users/someone"
        #expect(AppPlacement.of("/Applications/Agneta.app", home: home, readOnlyVolume: false) == .applications)
        #expect(AppPlacement.of("/Users/someone/Applications/Agneta.app", home: home + "/", readOnlyVolume: false) == .applications)
        // A disk image is read-only; an external drive someone keeps apps on isn't, and is left alone.
        #expect(AppPlacement.of("/Volumes/Agneta/Agneta.app", home: home, readOnlyVolume: true) == .diskImage)
        #expect(AppPlacement.of("/Volumes/Agneta 1/Agneta.app", home: home, readOnlyVolume: true) == .diskImage)
        #expect(AppPlacement.of("/Volumes/External/Apps/Agneta.app", home: home, readOnlyVolume: false) == .elsewhere)
        #expect(AppPlacement.of("/private/var/folders/x/T/AppTranslocation/1A2B/d/Agneta.app", home: home, readOnlyVolume: true) == .translocated)
        #expect(AppPlacement.of("/Users/someone/git/agneta/build/Agneta Dev.app", home: home, readOnlyVolume: false) == .elsewhere)
        // Only a folder inside Applications isn't Applications itself.
        #expect(AppPlacement.of("/Applications/Tools/Agneta.app", home: home, readOnlyVolume: false) == .elsewhere)
        #expect([AppPlacement.diskImage, .translocated].allSatisfy { $0.offersMove })
        #expect(![AppPlacement.applications, .elsewhere].contains { $0.offersMove })
        // A translocated download goes to the Trash once copied; a disk image's copy, read-only, stays.
        #expect(AppPlacement.translocated.trashesOriginal(onReadOnlyVolume: false))
        #expect(!AppPlacement.translocated.trashesOriginal(onReadOnlyVolume: true))
        #expect(!AppPlacement.diskImage.trashesOriginal(onReadOnlyVolume: false))
    }

    @Test func movesIntoApplicationsOrTheUsersOwn() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(MoveToApplications.destinationFolder(applicationsWritable: true, home: home).path() == "/Applications/")
        #expect(MoveToApplications.destinationFolder(applicationsWritable: false, home: home).path() == "/Users/someone/Applications/")
    }

    /// The pid and path reach the relaunch script as arguments, so a path with quotes or spaces can't change the script.
    @Test func relaunchPassesItsValuesAsArguments() {
        let app = URL(filePath: "/Applications/Ag\"neta $(x).app", directoryHint: .isDirectory)
        let arguments = MoveToApplications.relaunchArguments(pid: 4242, app: app)
        #expect(arguments.count == 5 && arguments[0] == "-c")
        #expect(!arguments[1].contains("4242") && !arguments[1].contains("neta"))
        #expect(arguments[3] == "4242" && arguments[4] == "/Applications/Ag\"neta $(x).app/")
    }

    /// An app's "Connect Your AI", its approval window and a sign-in do Welcome's job, naming who asked: Welcome closes.
    @Test func windowsThatReplaceWelcome() {
        #expect(["setup", "approval", "signin"].allSatisfy { WindowPresenter.replacesWelcome($0) })
        #expect(!["welcome", "settings", "details-1"].contains { WindowPresenter.replacesWelcome($0) })
    }
}

/// Moving to Applications, in temporary folders: never an older Agneta over a newer one, never no Agneta at all.
@Suite final class MoveTests {
    let root: URL

    deinit { try? FileManager.default.removeItem(at: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "agneta-move-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A bundle with an Info.plist and one file, `marker`, saying which copy it is.
    func bundle(_ path: String, id: String = "com.objectivecoder.agneta", version: String = "0.5.0", build: String = "50", marker: String) throws -> URL {
        let app = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": build], format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Contents/Info.plist"))
        try Data(marker.utf8).write(to: app.appending(path: "Contents/MacOS/marker"))
        return app
    }

    func marker(_ app: URL) -> String? { (try? String(contentsOf: app.appending(path: "Contents/MacOS/marker"), encoding: .utf8)) }

    /// Discards into a folder of the test's own instead of the Trash.
    func files(copy: ((URL, URL) throws -> Void)? = nil) -> MoveToApplications.Files {
        let trash = root.appending(path: "Trash", directoryHint: .isDirectory)
        var files = MoveToApplications.Files()
        if let copy { files.copy = copy }
        files.discard = { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let to = trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        return files
    }

    func leftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.contains(".moving-") }
    }

    @Test func movesIntoAnEmptyFolderWithoutTheQuarantineMark() throws {
        let source = try bundle("Volume/Agneta.app", marker: "new")
        _ = setxattr(source.appending(path: "Contents/MacOS/marker").path(percentEncoded: false), "com.apple.quarantine", "0081;0;Test;", 12, 0, 0)
        let destination = root.appending(path: "Applications/Agneta.app", directoryHint: .isDirectory)
        try MoveToApplications.move(source, to: destination, bundleID: "com.objectivecoder.agneta", files: files())
        #expect(marker(destination) == "new" && marker(source) == "new")
        #expect(getxattr(destination.appending(path: "Contents/MacOS/marker").path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0) < 0)
        #expect(leftovers(in: destination.deletingLastPathComponent()).isEmpty)
    }

    @Test func replacesAnOlderAgnetaWhichGoesToTheTrash() throws {
        let source = try bundle("Volume/Agneta.app", marker: "new")
        let destination = try bundle("Applications/Agneta.app", version: "0.4.0", marker: "old")
        try MoveToApplications.move(source, to: destination, bundleID: "com.objectivecoder.agneta", files: files())
        #expect(marker(destination) == "new")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Trash").path(percentEncoded: false))
        #expect(trashed.count == 1)
    }

    @Test func refusesSomethingElseAndItself() throws {
        let source = try bundle("Volume/Agneta.app", marker: "new")
        let other = try bundle("Applications/Agneta.app", id: "com.example.other", marker: "other")
        #expect(throws: MoveToApplications.MoveError.self) {
            try MoveToApplications.move(source, to: other, bundleID: "com.objectivecoder.agneta", files: files())
        }
        #expect(marker(other) == "other")
        // Never onto itself (a translocated copy whose original is the destination).
        #expect(throws: MoveToApplications.MoveError.self) {
            try MoveToApplications.move(source, to: source, bundleID: "com.objectivecoder.agneta", files: files())
        }
        #expect(marker(source) == "new")
    }

    /// Disk full halfway: the old Agneta stays where it was, and no partial copy is left behind.
    @Test func aFailedCopyLeavesTheOldAgnetaInPlace() throws {
        let source = try bundle("Volume/Agneta.app", marker: "new")
        let destination = try bundle("Applications/Agneta.app", version: "0.4.0", marker: "old")
        let failing = files(copy: { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        #expect(throws: CocoaError.self) {
            try MoveToApplications.move(source, to: destination, bundleID: "com.objectivecoder.agneta", files: failing)
        }
        #expect(marker(destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Trash").path(percentEncoded: false)))
        #expect(leftovers(in: destination.deletingLastPathComponent()).isEmpty)
    }

    @Test func neverAnOlderOverANewer() throws {
        let running = try #require(MoveToApplications.BundleInfo(try bundle("Volume/Agneta.app", version: "0.4.0", build: "40", marker: "x")))
        let newer = MoveToApplications.BundleInfo(try bundle("A/Agneta.app", version: "0.6.0", build: "60", marker: "x"))
        let same = MoveToApplications.BundleInfo(try bundle("B/Agneta.app", version: "0.4.0", build: "40", marker: "x"))
        let olderBuild = MoveToApplications.BundleInfo(try bundle("C/Agneta.app", version: "0.4.0", build: "39", marker: "x"))
        let other = MoveToApplications.BundleInfo(try bundle("D/Agneta.app", id: "com.example.other", version: "9.0", marker: "x"))
        #expect(MoveToApplications.offer(running: running, atDestination: newer, destinationExists: true) == .openExisting)
        #expect(MoveToApplications.offer(running: running, atDestination: same, destinationExists: true) == .openExisting)
        #expect(MoveToApplications.offer(running: running, atDestination: olderBuild, destinationExists: true) == .move)
        #expect(MoveToApplications.offer(running: running, atDestination: nil, destinationExists: false) == .move)
        #expect(MoveToApplications.offer(running: running, atDestination: other, destinationExists: true) == .nothing)
        // A folder that isn't a bundle (no Info.plist) is something else too.
        #expect(MoveToApplications.offer(running: running, atDestination: nil, destinationExists: true) == .nothing)
        #expect(MoveToApplications.compare("0.10.0", "0.9.3") == .orderedDescending && MoveToApplications.compare("1.2", "1.2.0") == .orderedSame)
    }
}
