// Everything an app does in a long agent task, in order, through the real
// WebSocket server, router, supervisor, pinned goose-acp, the fake model and a
// stand-in app's MCP server that requires its bearer (scripts/dev/fake-mcp.py).
// When this passes, an app's ACP backend has what it needs from Agneta
// (docs/APP_PROTOCOL.md).
import Foundation
import Testing
@testable import AgnetaKit

@Suite(.serialized, .enabled(if: GooseHarness.available && BuiltTools.shellBuilt, "run scripts/fetch-engines and swift build first"))
struct AppScenarioTests {
    /// A read-only review that starts with a copy of a finished run's conversation.
    @Test func aForkStartsWithTheConversationAndLeavesTheOriginal() async throws {
        let stack = try await RouterIntegrationTests.Stack.start(port: 47453, modelPort: 47463)
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Example App")
            let project = try stack.workspace("Forked")
            let run = try await client.newSession(cwd: project, tools: "workspace")
            _ = try await client.prompt(run, "remember the word fjord")

            // Fork while the run is open, then again after it closed.
            let live = try await client.request("agneta/fork", ["sessionId": .string(run), "mcpServers": []])
            #expect(live["_meta"]?["agneta"]?["forkOf"]?.stringValue == run)
            _ = try await client.request("session/close", ["sessionId": .string(run)])
            try await Task.sleep(for: .milliseconds(300))
            let originalLines = try String(contentsOf: stack.traces.file(for: run), encoding: .utf8).split(separator: "\n").count

            let review = try await client.request("agneta/fork", ["sessionId": .string(run), "mcpServers": []])
            let fork = try #require(review["sessionId"]?.stringValue)
            #expect(fork != run)
            let answer = try await client.prompt(fork, "what was the word?")
            #expect(answer["stopReason"]?.stringValue == "end_turn")
            let lastRequest = try String(contentsOf: stack.root.appending(path: "model.log"), encoding: .utf8).split(separator: "\n").last ?? ""
            #expect(lastRequest.contains("remember the word fjord"))

            // The original is untouched; the fork is its own task, read-only by default, linked to its source.
            #expect(try String(contentsOf: stack.traces.file(for: run), encoding: .utf8).split(separator: "\n").count == originalLines)
            let forkTrace = try String(contentsOf: stack.traces.file(for: fork), encoding: .utf8).split(separator: "\n").map { try JSONCoding.decode(Data($0.utf8)) }
            #expect(forkTrace.first?["policy"]?["tools"]?.stringValue == "read")
            #expect(forkTrace.contains { $0["event"]?.stringValue == "forked" && $0["from"]?.stringValue == run })
            // Only the owner can fork.
            let other = AppClient(port: stack.port)
            try await other.pairAndInitialize("Other")
            await #expect(throws: RPCError.self) { _ = try await other.request("agneta/fork", ["sessionId": .string(run), "mcpServers": []]) }
            client.close()
            other.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// The app reopens a project: the task resumes in its engine home, the engine replays the
    /// conversation, the next turn sees it, and the trace goes on where it stopped.
    /// The engines under test: Goose ("dev") always; OpenCode ("oc") when its binary was fetched.
    static let engines = ["dev"] + (GooseHarness.openCodeAvailable ? ["oc"] : [])
    static func offset(_ account: String) -> Int { account == "oc" ? 5 : 0 }
    /// How the engine names an MCP server's tool for the model: Goose `app__echo`, OpenCode `app_echo`.
    static func tool(_ name: String, _ account: String) -> String { account == "oc" ? "app_\(name)" : "app__\(name)" }

    @Test(arguments: engines) func aClosedTaskResumesWithItsConversation(account: String) async throws {
        let stack = try await RouterIntegrationTests.Stack.start(port: UInt16(47452 + Self.offset(account)), modelPort: 47462 + Self.offset(account))
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Example App")
            let project = try stack.workspace("Resumed")
            let session = try await client.newSession(cwd: project, tools: "workspace", account: account)
            _ = try await client.prompt(session, "remember the word fjord")
            _ = try await client.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(300))
            #expect(await stack.supervisor.processCount == 0) // the dedicated engine stopped with the session
            let before = client.text(session)

            let loaded = try await client.request("session/load", ["sessionId": .string(session), "cwd": .string(project.path(percentEncoded: false)), "mcpServers": []])
            #expect(loaded["_meta"]?["agneta"]?["resumed"]?.boolValue == true)
            #expect(client.text(session).count > before.count) // the conversation was replayed
            let next = try await client.prompt(session, "what was the word?")
            #expect(next["stopReason"]?.stringValue == "end_turn")
            // The model saw the earlier turn.
            let lastRequest = try String(contentsOf: stack.root.appending(path: "model.log"), encoding: .utf8).split(separator: "\n").last ?? ""
            #expect(lastRequest.contains("remember the word fjord"))
            // A second load while open is refused; another app can't load it.
            await #expect(throws: RPCError.self) { _ = try await client.request("session/load", ["sessionId": .string(session), "cwd": .string(project.path(percentEncoded: false)), "mcpServers": []]) }
            let other = AppClient(port: stack.port)
            try await other.pairAndInitialize("Other")
            await #expect(throws: RPCError.self) { _ = try await other.request("session/load", ["sessionId": .string(session), "cwd": .string(project.path(percentEncoded: false)), "mcpServers": []]) }
            _ = try await client.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(300))

            let records = try String(contentsOf: stack.traces.file(for: session), encoding: .utf8).split(separator: "\n").map { try JSONCoding.decode(Data($0.utf8)) }
            #expect(records.map { $0["seq"]?.intValue } == (1...Int64(records.count)).map { $0 })
            #expect(records.filter { $0["type"]?.stringValue == "event" && $0["kind"]?.stringValue == "turn" }.map { $0["n"]?.intValue } == [1, 2])
            #expect(records.contains { $0["event"]?.stringValue == "resumed" })
            #expect(records.filter { $0["type"]?.stringValue == "end" }.count == 2)
            client.close()
            other.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    @Test(arguments: engines) func aLongTaskEndToEnd(account: String) async throws {
        let stack = try await RouterIntegrationTests.Stack.start(port: UInt16(47451 + Self.offset(account)), modelPort: 47461 + Self.offset(account))
        let mcpPort = 47471 + Self.offset(account)
        let bearer = "app-mcp-\(UUID().uuidString)"
        let mcp = try GooseHarness.fake("fake-mcp.py", [String(mcpPort), bearer, stack.root.appending(path: "mcp.log").path(percentEncoded: false)],
                                        root: stack.root, name: "mcp")
        defer { killpg(mcp.pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(400))
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Example App")
            let project = try stack.workspace("Meeting Notes")

            // 1. A session in the project's workspace with the app's tools, instructions, a title and a live trace.
            let created = try await client.request("session/new", [
                "cwd": .string(project.path(percentEncoded: false)),
                "mcpServers": [["type": "http", "name": "app", "url": .string("http://127.0.0.1:\(mcpPort)/mcp"),
                                "headers": [["name": "Authorization", "value": .string("Bearer \(bearer)")]]]],
                "_meta": [
                    SessionPolicy.key: ["tools": "workspace", "network": "none", "approval": "never-ask"],
                    "agneta": ["account": .string(account)],
                    "agneta/task@1": ["title": "Summarizing meeting notes", "stopWarning": "The app keeps the work so far"],
                    "agneta/instructions": ["text": "You are the app's agent. Use the app's tools."],
                    "agneta/trace@1": ["live": true],
                ],
            ])
            let session = try #require(created["sessionId"]?.stringValue)
            let model = created["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }
            let modelID = try #require(model?["currentValue"]?.stringValue) // "gpt-4o" on Goose, "agneta/gpt-4o" on OpenCode
            #expect(modelID.hasSuffix("gpt-4o"))
            let capabilities = try #require(created["_meta"]?["agneta"]?["capabilities"])

            // 2. The app picks the model before the first prompt.
            _ = try await client.request("session/set_config_option", ["sessionId": .string(session), "configId": "model", "value": .string(modelID)])

            // 3. The app's text tool and image tool, over its MCP server with the bearer.
            let echo = try await client.prompt(session, "CALL \(Self.tool("echo", account)) " + #"{"text": "agneta"}"#)
            #expect(echo["stopReason"]?.stringValue == "end_turn")
            #expect(client.toolOutput(session).contains("agneta"))
            let swatch = try await client.prompt(session, "CALL \(Self.tool("swatch", account)) {}")
            #expect(swatch["stopReason"]?.stringValue == "end_turn")

            // 4. Every turn reports its usage and what the cost means.
            let usage = try #require(echo["_meta"]?["agneta/usage@1"])
            #expect(usage["modelCalls"]?.intValue == 2 && usage["inputTokens"]?.intValue == 84)
            #expect(usage["billing"]?.stringValue == "api-key" && usage["costKind"]?.stringValue == "estimated")

            // 5. Steering a running turn, then changing instructions between turns.
            let slow = Task { try await client.prompt(session, "think slowly") }
            var steered: JSONValue?
            for _ in 0..<40 where steered == nil {
                try await Task.sleep(for: .milliseconds(100))
                steered = try? await client.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "keep the knee soft"]]])
            }
            #expect(steered?["delivery"]?.stringValue == "accepted")
            _ = try await slow.value
            if capabilities["instructionsBetweenTurns"]?.boolValue == true {
                _ = try await client.request("agneta/instructions/set", ["sessionId": .string(session), "text": "Be brief from now on.", "mode": "append"])
            } else {
                await #expect(throws: RPCError.self) {
                    _ = try await client.request("agneta/instructions/set", ["sessionId": .string(session), "text": "Be brief from now on."])
                }
            }

            // 6. Cancel ends a turn quickly.
            let cancelled = Task { try await client.prompt(session, "answer slowly") }
            try await Task.sleep(for: .milliseconds(400))
            let cancelAt = ContinuousClock.now
            client.notify("session/cancel", ["sessionId": .string(session)])
            let result = try await cancelled.value
            #expect(result["stopReason"]?.stringValue == "cancelled")
            #expect(ContinuousClock.now - cancelAt < .seconds(3))

            // 7. Close; the live trace and the stored one agree, and tell the whole story.
            _ = try await client.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(500))
            let live = client.traceRecords(session)
            var read: [JSONValue] = []
            var after: Int64 = 0
            while true {
                let page = try await client.request("agneta/trace/read", ["sessionId": .string(session), "after": .int(after), "limit": 2000])
                read += page["records"]?.arrayValue ?? []
                if page["complete"]?.boolValue == true { break }
                after = try #require(page["next"]?.intValue)
            }
            #expect(live == read)
            func events(_ kind: String) -> [JSONValue] { read.filter { $0["type"]?.stringValue == "event" && $0["kind"]?.stringValue == kind } }
            let tools = events("tool-call").map { "\($0["extension"]?.stringValue ?? "?")/\($0["tool"]?.stringValue ?? "?")" }
            #expect(tools == ["app/echo", "app/swatch"])
            #expect(events("tool-result").count == 2 && events("tool-result").allSatisfy { $0["isError"]?.boolValue == false })
            let image = events("tool-result").last?["content"]?.arrayValue?.contains { $0["content"]?["type"]?.stringValue == "image" } ?? false
            #expect(image)
            #expect(events("turn").map { $0["stopReason"]?.stringValue } == ["end_turn", "end_turn", "end_turn", "cancelled"])
            #expect(read.contains { $0["event"]?.stringValue == "steer" && $0["delivery"]?.stringValue == "accepted" })
            #expect(read.contains { $0["type"]?.stringValue == "config" && $0["method"]?.stringValue == "session/set_config_option" })
            #expect(read.contains { $0["type"]?.stringValue == "config" && $0["method"]?.stringValue == "agneta/instructions/set" }
                    == (capabilities["instructionsBetweenTurns"]?.boolValue == true))
            #expect(read.first?["instructions"]?.stringValue == "You are the app's agent. Use the app's tools.")
            #expect(events("init").first?["model"]?.stringValue?.hasSuffix("gpt-4o") == true)
            // The app's bearer never reaches the trace.
            let file = try String(contentsOf: stack.traces.file(for: session), encoding: .utf8)
            #expect(!file.contains(bearer))
            // The MCP server saw every call with its bearer (it refuses calls without it).
            let mcpLog = try String(contentsOf: stack.root.appending(path: "mcp.log"), encoding: .utf8)
            #expect(mcpLog.components(separatedBy: "tools/call").count - 1 == 2)
            client.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
