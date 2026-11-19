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
