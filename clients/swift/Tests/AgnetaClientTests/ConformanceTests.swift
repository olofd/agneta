import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct ConformanceTests {
    @Test func sharedStructuredResultContract() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "structured-results", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        for item in try #require(fixture["cases"]?.array) {
            let id = try #require(item["id"]?.string)
            let host = StandIn(), client = try host.client()
            defer { client.close() }
            host.overrides = { method, message, socket in
                guard method == "session/prompt" else { return false }
                if let code = item["rpcCode"]?.integer {
                    socket.fail(message, code: Int(code), data: ["agneta": ["result": item["report"]!]])
                } else {
                    socket.reply(
                        message, result: ["stopReason": "end_turn", "_meta": [resultExtension: item["report"]!]])
                }
                return true
            }
            _ = try await client.connect()
            var options = SessionOptions(); options.results = ResultDeclaration(schema: item["schema"]!)
            let session = try await client.newSession(options)
            let wire = host.transport.calls("session/new")[0]["params"]?["_meta"]?[resultExtension]?["schemas"]?[
                "result"]
            #expect(wire == item["wireSchema"], "\(id): schema changed on the wire")
            let answer = try session.ask("Return the result", as: JSONValue.self)
            do {
                let value = try await answer.value
                #expect(item["kind"] == "valid", "\(id): unexpectedly accepted")
                #expect(value == item["value"], "\(id): wrong app-facing value")
            } catch let error as ResultFailure {
                #expect(
                    item["kind"]?.string == (error.kind == .missing ? "missing" : "invalid"),
                    "\(id): wrong result failure")
                #expect(error.value == item["value"], "\(id): refused value was not unwrapped")
                #expect(error.submitted == item["report"]?["value"], "\(id): submission was not retained")
                if let paths = item["issuePaths"]?.array {
                    #expect(error.issues.map(\.path) == paths.compactMap(\.string), "\(id)")
                }
                if let paths = item["schemaPaths"]?.array {
                    #expect(error.issues.map(\.schemaPath) == paths.compactMap(\.string), "\(id)")
                }
            } catch let error as AgnetaError {
                if item["kind"] == "rpc" {
                    #expect(error.code == Int(item["rpcCode"]!.integer!), "\(id)")
                    #expect(error.accepted?.value == item["value"], "\(id): accepted value was lost")
                    #expect(error.accepted?.issues == nil, "\(id)")
                    #expect(error.structured?.raw == item["report"], "\(id): host report changed")
                } else {
                    #expect(item["kind"] == "protocol", "\(id): unexpected RPC failure")
                    #expect(error.kind == .protocolViolation, "\(id)")
                }
            }
            #expect(
                host.transport.calls("session/prompt")[0]["params"]?["_meta"]?[resultExtension] == ["name": "result"],
                "\(id)")
        }
    }
}
