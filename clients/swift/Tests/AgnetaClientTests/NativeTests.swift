import Foundation
import Testing

@testable import AgnetaClient

@MainActor final class TestProcess {
    let process = Process()
    let log: URL
    private let output: FileHandle
    private let input = Pipe()
    init(executable: URL, arguments: [String], log: URL) throws {
        self.log = log
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardError = output; process.standardInput = input
        try process.run()
    }
    func text() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    func waitFor(_ condition: (String) -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(text()) {
            guard process.isRunning else { throw AgnetaError(.internalError, "Test subprocess exited: \(text())") }
            if start.duration(to: .now) > .seconds(20) {
                throw AgnetaError(.timeout, "Test subprocess did not start: \(text())")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func stop() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let start = ContinuousClock.now
        while process.isRunning, start.duration(to: .now) < .seconds(8) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.close()
    }
}
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGNETA_CLIENT_NATIVE_TESTS"] == "1"))
@MainActor struct NativeTests {
    @Test(.timeLimit(.minutes(1))) func foundationWebSocketInteroperability() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agneta-swift-native-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try TestProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", repositoryRoot.appendingPathComponent("clients/swift/Tests/native-stand-in.mjs").path],
            log: folder.appendingPathComponent("server.log"))
        do {
            try await server.waitFor { $0.contains("\"url\"") }
            let line = server.text().split(separator: "\n").first!
            let info = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let url = URL(string: info["url"]!.string!)!
            let raw = try await Connection.open(url: url)
            let value = try await raw.request("echo", params: ["text": .string(String(repeating: "x", count: 200_000))])
            #expect(value["text"]?.string?.count == 200_000); #expect(value["origin"] == .null)
            await expectKind(.timeout) { try await raw.request("hang", options: .init(timeout: 0.02)) }
            #expect(raw.isOpen); raw.close()
            var options = ClientOptions(name: "Native Swift Test"); options.url = url
            let client = try AgnetaClient(options: options)
            _ = try await client.connect()
            let session = try await client.newSession()
            let result = try await session.prompt("Hello").result
            #expect(!result.text.isEmpty)
            try await session.close(); client.close()
            await expectKind(.refused) { try await Connection.open(url: URL(string: info["refused"]!.string!)!) }
            do {
                let redirected = try await Connection.open(
                    url: URL(string: info["redirect"]!.string!)!, connectTimeout: 2);
                redirected.close(); Issue.record("Redirect followed")
            } catch { #expect(error is AgnetaError) }
            await server.stop()
            try FileManager.default.removeItem(at: folder)
        } catch { await server.stop(); throw error }
    }
}
