import Foundation
import Testing

@testable import AgnetaKit

@Suite struct JSONRPCTests {
    @Test func parsesRequestNotificationAndResponses() throws {
        let request = try RPCMessage.parse(
            Data(#"{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/tmp"}}"#.utf8))
        #expect(request == .request(id: .int(7), method: "session/new", params: ["cwd": "/tmp"]))

        let note = try RPCMessage.parse(
            Data(#"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#.utf8))
        #expect(note == .notification(method: "session/cancel", params: ["sessionId": "s"]))

        let ok = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"a","result":{"stopReason":"end_turn"}}"#.utf8))
        #expect(ok == .response(id: .string("a"), result: .success(["stopReason": "end_turn"])))

        let failed = try RPCMessage.parse(
            Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad"}}"#.utf8))
        #expect(failed == .response(id: .int(3), result: .failure(RPCError(code: -32602, message: "bad"))))
    }

    @Test func rejectsMalformedMessages() {
        #expect(throws: RPCMessage.ParseFailure.notJSON) { try RPCMessage.parse(Data("{".utf8)) }
        #expect(throws: RPCMessage.ParseFailure.notObject) { try RPCMessage.parse(Data("[1]".utf8)) }
        #expect(throws: RPCMessage.ParseFailure.wrongVersion) {
            try RPCMessage.parse(Data(#"{"id":1,"method":"x"}"#.utf8))
        }
        #expect(throws: RPCMessage.ParseFailure.malformed("response without result or error")) {
            try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        }
    }

    @Test func roundTripsUnknownFieldsLosslessly() throws {
        let raw =
            #"{"id":1,"jsonrpc":"2.0","method":"_goose/unstable/x","params":{"big":9007199254740993,"f":1.5,"n":null,"nested":[true,{"k":"v"}]}}"#
        let message = try RPCMessage.parse(Data(raw.utf8))
        #expect(String(decoding: try message.encoded(), as: UTF8.self) == raw)
    }

    @Test func duplicateAndCanonicallyEquivalentKeysAreRefusedBeforeDecoding() throws {
        for text in [
            #"{"é":1,"e\u0301":"wrong"}"#,
            #"{"properties":{"é":{"type":"integer"},"e\u0301":{"type":"string"}}}"#,
            #"{"same":1,"\u0073ame":2}"#,
            #"{"a":{"x":1,"x":2}}"#
        ] {
            #expect(throws: DecodingError.self) { _ = try JSONCoding.decode(Data(text.utf8)) }
        }
        #expect(try JSONCoding.decode(Data(#"{"a":{"x":1},"b":{"x":2},"text":"\"x\": 3"}"#.utf8))["b"]?["x"] == 2)
    }

    @Test func aKeyWithALongRunOfCombiningMarksIsRefusedBeforeItsHashed() throws {
        let mark = "\u{0301}"
        let thirty = "e" + String(repeating: mark, count: JSONCoding.maxCombiningRun)
        let ok: JSONValue = .object(["k": .object([thirty: 1])])
        #expect(try JSONCoding.decode(JSONCoding.encode(ok))["k"] != nil)
        let over = "e" + String(repeating: mark, count: JSONCoding.maxCombiningRun + 1)
        #expect(throws: DecodingError.self) { _ = try JSONCoding.decode(Data("{\"\(over)\":1}".utf8)) }
        // A run that would take seconds to hash is refused at once; the same run in a value is fine.
        let huge = "e" + String(repeating: mark, count: 160_000)
        let started = ContinuousClock.now
        #expect(throws: DecodingError.self) { _ = try JSONCoding.decode(Data("{\"\(huge)\":1}".utf8)) }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(try JSONCoding.decode(Data("{\"k\":\"\(over)\"}".utf8))["k"]?.stringValue == over)
        // Escaped keys are read as their text.
        #expect(try JSONCoding.decode(Data(#"{"\u0061":1,"b\"c":2}"#.utf8))["a"] == 1)
    }

    @Test func aRefusedFramesAnswerSaysWhy() async throws {
        let (lines, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let (answers, output) = AsyncStream<Data>.makeStream()
        let peer = RPCPeer { data in output.yield(data) }
        let running = Task { await peer.run(lines) }
        var iterator = answers.makeAsyncIterator()
        input.yield(Data(#"{"jsonrpc":"2.0","id":1,"method":"example","params":{"a":1,"a":2}}"#.utf8))
        input.yield(Data(#"{"jsonrpc":"1.0","id":2,"method":"example"}"#.utf8))
        var reasons: [String] = []
        for _ in 0..<2 {
            let answer = try #require(await iterator.next())
            if case .response(_, .failure(let error)) = try RPCMessage.parse(answer) { reasons.append(error.message) }
        }
        #expect(reasons.count == 2)
        #expect(reasons.first?.contains("duplicate or canonically equivalent") == true)
        #expect(reasons.last == "The message isn't a valid JSON-RPC message")
        input.finish(); await running.value
    }

    @Test func anAmbiguousReplyFailsItsPendingRequest() async throws {
        let (lines, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let peer = RPCPeer { data in
            guard case .request(let id, _, _) = try RPCMessage.parse(data) else { return }
            input.yield(Data(#"{"jsonrpc":"2.0","id":\#(id.description),"result":{"é":1,"e\u0301":2}}"#.utf8))
        }
        let running = Task { await peer.run(lines) }
        await #expect(throws: RPCError.self) { _ = try await peer.request("example") }
        input.finish(); await running.value
    }

    @Test func anAmbiguousRequestGetsAnError() async throws {
        let (lines, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let (answers, output) = AsyncStream<Data>.makeStream()
        let peer = RPCPeer { data in output.yield(data) }
        let running = Task { await peer.run(lines) }
        input.yield(Data(#"{"jsonrpc":"2.0","id":7,"method":"example","params":{"é":1,"e\u0301":2}}"#.utf8))
        var iterator = answers.makeAsyncIterator()
        let answer = try #require(await iterator.next())
        guard case .response(.int(7), .failure(let error)) = try RPCMessage.parse(answer) else {
            Issue.record("Ambiguous request was not refused"); input.finish(); await running.value; return
        }
        #expect(error.code == RPCError.invalidRequest)
        input.finish(); await running.value
    }

    @Test func remapsIDsPerHop() {
        var map = RPCIDMap()
        let a = map.forward(.string("app-1"))
        let b = map.forward(.int(1))
        #expect(a != b)
        #expect(map.reverse(b) == .int(1))
        #expect(map.reverse(a) == .string("app-1"))
        #expect(map.reverse(a) == nil)
        #expect(map.pending == 0)
    }
}
