import Foundation
import Testing
@testable import AgnetaKit

@Suite struct JSONRPCTests {
    @Test func parsesRequestNotificationAndResponses() throws {
        let request = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/tmp"}}"#.utf8))
        #expect(request == .request(id: .int(7), method: "session/new", params: ["cwd": "/tmp"]))

        let note = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#.utf8))
        #expect(note == .notification(method: "session/cancel", params: ["sessionId": "s"]))

        let ok = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"a","result":{"stopReason":"end_turn"}}"#.utf8))
        #expect(ok == .response(id: .string("a"), result: .success(["stopReason": "end_turn"])))

        let failed = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad"}}"#.utf8))
        #expect(failed == .response(id: .int(3), result: .failure(RPCError(code: -32602, message: "bad"))))
    }

    @Test func rejectsMalformedMessages() {
        #expect(throws: RPCMessage.ParseFailure.notJSON) { try RPCMessage.parse(Data("{".utf8)) }
        #expect(throws: RPCMessage.ParseFailure.notObject) { try RPCMessage.parse(Data("[1]".utf8)) }
        #expect(throws: RPCMessage.ParseFailure.wrongVersion) { try RPCMessage.parse(Data(#"{"id":1,"method":"x"}"#.utf8)) }
        #expect(throws: RPCMessage.ParseFailure.malformed("response without result or error")) {
            try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        }
    }

    /// An error that isn't a well-formed JSON-RPC error (no message, a string code) was dropped as malformed, so the
    /// request it answered waited forever: a turn, or a permission request to an app, stuck until the connection
    /// closed. It's an error all the same, and now ends the request as one.
    @Test func aMalformedErrorStillEndsTheRequest() async throws {
        for error in [#"{"code":-32000}"#, #"{"code":"E1","message":"failed"}"#, #""failed""#, #"null"#] {
            let parsed = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":4,"error":\#(error)}"#.utf8))
            guard case .response(.int(4), .failure(let failure)) = parsed else { Issue.record("\(error): \(parsed)"); continue }
            #expect(failure.code == RPCError.internalError, "\(error)")
        }

        let (lines, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let peer = RPCPeer { data in
            guard let id = try? RPCMessage.parse(data), case .request(let rid, _, _) = id else { return }
            input.yield(Data(#"{"jsonrpc":"2.0","id":\#(rid.description),"error":{"code":-32000}}"#.utf8))
        }
        Task { await peer.run(lines) }
        let outcome = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await peer.request("session/prompt"); return "answered" } catch let error as RPCError { return "error \(error.code)" }
            }
            group.addTask { try await Task.sleep(for: .seconds(5)); return "hung" }
            let first = try await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        #expect(outcome == "error \(RPCError.internalError)")
        input.finish()
    }

    @Test func roundTripsUnknownFieldsLosslessly() throws {
        let raw = #"{"id":1,"jsonrpc":"2.0","method":"_goose/unstable/x","params":{"big":9007199254740993,"f":1.5,"n":null,"nested":[true,{"k":"v"}]}}"#
        let message = try RPCMessage.parse(Data(raw.utf8))
        #expect(String(decoding: try message.encoded(), as: UTF8.self) == raw)
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
