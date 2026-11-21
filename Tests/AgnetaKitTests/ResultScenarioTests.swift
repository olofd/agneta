// Structured results through real engines: the pinned goose-acp and OpenCode, driven by the fake model, reach Agneta's
// result server through the MCP entry Agneta gives them, and the prompt's reply carries the result.
import AgnetaFakes
import Foundation
import Testing

@testable import AgnetaKit

@Suite(
    .serialized,
    .enabled(if: GooseHarness.available && BuiltTools.shellBuilt, "run scripts/fetch-engines and swift build first"))
struct ResultScenarioTests {
    static let engines = ["dev"] + (GooseHarness.openCodeAvailable ? ["oc"] : [])
    static func offset(_ account: String) -> Int { account == "oc" ? 5 : 0 }
    /// How the engine names the result server's tool for the model: Goose `agneta-result__submit_result`, OpenCode
    /// `agneta-result_submit_result`.
    static func tool(_ name: String, _ account: String) -> String {
        account == "oc" ? "agneta-result_\(name)" : "agneta-result__\(name)"
    }

    static let contact: JSONValue = [
        "type": "object", "properties": ["name": ["type": "string"], "email": ["type": "string"]],
        "required": ["name"], "additionalProperties": false
    ]

    @Test(arguments: engines) func aRealEngineSubmitsAResult(account: String) async throws {
        let stack = try await RouterIntegrationTests.Stack.start(
            port: UInt16(47781 + Self.offset(account)), modelPort: 47791 + Self.offset(account))
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Results App")
            let project = try stack.workspace("Contacts")
            let created = try await client.request(
                "session/new",
                [
                    "cwd": .string(project.path(percentEncoded: false)), "mcpServers": [],
                    "_meta": [
                        SessionPolicy.key: ["tools": "app-only", "network": "none", "approval": "never-ask"],
                        "agneta": ["account": .string(account)],
                        "agneta/result": ["schema": Self.contact]
                    ]
                ])
            let session = try #require(created["sessionId"]?.stringValue)
            #expect(created["_meta"]?["agneta"]?["results"]?["declared"] == ["result"])

            // Valid on the first call.
            let valid = try await client.prompt(
                session,
                "CALL \(Self.tool("submit_result", account)) " + #"{"name": "Ada", "email": "ada@example.com"}"#)
            #expect(valid["stopReason"] == "end_turn")
            #expect(valid["_meta"]?["agneta/result"]?["status"] == "valid")
            #expect(valid["_meta"]?["agneta/result"]?["value"] == ["name": "Ada", "email": "ada@example.com"])

            // Invalid: the model reads Agneta's issues as the tool's error, and the reply says invalid.
            let invalid = try await client.request(
                "session/prompt",
                [
                    "sessionId": .string(session),
                    "prompt": [
                        [
                            "type": "text",
                            "text": .string("CALL \(Self.tool("submit_result", account)) " + #"{"name": 7}"#)
                        ]
                    ],
                    "_meta": ["agneta/result": ["name": "result", "attempts": 1]]
                ])
            let modelLog = try String(contentsOf: stack.root.appending(path: "model.log"), encoding: .utf8)
            if account == "oc" {
                // OpenCode checks a tool's arguments against its schema itself (measured on 2.3.0): the call never
                // reaches Agneta, the model reads OpenCode's own message, and Agneta saw no submission.
                #expect(invalid["_meta"]?["agneta/result"]?["status"] == "missing")
                #expect(invalid["_meta"]?["agneta/result"]?["reason"] == "not-submitted")
                #expect(modelLog.contains("Invalid arguments for tool"))
            } else {
                // Goose passes the call on: Agneta refuses it, and the model reads Agneta's issue.
                #expect(invalid["_meta"]?["agneta/result"]?["status"] == "invalid")
                #expect(invalid["_meta"]?["agneta/result"]?["issues"]?.arrayValue?.first?["path"] == "/name")
                #expect(modelLog.contains("expected a string, got the number 7"))
            }
            client.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
