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

    @Test func followsAResumedTraceUntilItsNewEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-follow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = AgnetaStore(root: root).tracesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let trace = folder.appending(path: "task.jsonl")
        let initial = #"{"type":"end"}"# + "\n" + #"{"type":"lifecycle","event":"resumed"}"# + "\n"
        try Data(initial.utf8).write(to: trace)
        let output = root.appending(path: "output")
        try Data().write(to: output)
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        let process = command(root, ["tail", "-f", "--json", "task"])
        process.standardOutput = sink
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }

        let ready = ContinuousClock.now + .seconds(5)
        while try String(contentsOf: output, encoding: .utf8) != initial && ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(String(contentsOf: output, encoding: .utf8) == initial)
        let final = #"{"type":"end","seq":3}"# + "\n"
        let append = try FileHandle(forWritingTo: trace)
        try append.seekToEnd()
        try append.write(contentsOf: Data(final.utf8))
        try append.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!process.isRunning)
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == initial + final)
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
