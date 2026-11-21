import Foundation
import GRDB
import Testing

@testable import AgnetaKit

@Suite struct DiagnosticsCLITests {
    private func command(_ home: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = GooseHarness.repo.appending(path: ".build/debug/agneta-diag")
        process.arguments = ["--home", home.path] + arguments
        return process
    }

    @Test func listingTasksOnlyReadsAnExistingCompatibleStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-diag-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgnetaStore(root: root)
        func list(_ home: URL) throws -> Int32 {
            let process = command(home, ["tasks"])
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let missing = root.appending(path: "missing")
        #expect(try list(missing) != 0)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: store.databaseFile.path)
            try AgnetaDatabase.migrator.migrate(queue, upTo: AgnetaDatabase.schema)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: store.databaseFile.path)
        let before = try Data(contentsOf: store.databaseFile)
        #expect(try list(root) != 0)
        #expect(try Data(contentsOf: store.databaseFile) == before)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.databaseFile.path)
        #expect(attributes[.posixPermissions] as? Int == 0o640)

        _ = try AgnetaDatabase(file: store.databaseFile)
        #expect(try list(root) == 0)
    }
}
