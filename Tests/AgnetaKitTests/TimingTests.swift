// Tests that hold Agneta to a wall-clock bound: a starved task pool, a bounded wait, a request that must end.
//
// Their bounds measure Agneta, so CI runs them on their own after the rest (ci.yml: --skip TimingTests, then
// --filter TimingTests), one at a time: inside the full suite, GitHub's 3-core runners were busy with hundreds of
// parallel tests and stretched 0.1 s sleeps past 10 s, failing them for the suite's load rather than Agneta's.
// Locally a plain `swift test` runs them with everything else.
import Foundation
import Testing

@testable import AgnetaKit

@Suite(.serialized) struct TimingTests {
    /// More engines than the task pool has threads stop reading their stdin mid-write; Agneta keeps running,
    /// and the stuck writes fail once the engines go.
    @Test func stalledEnginesDontFreezeAgneta() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        var children: [ChildProcess] = []
        for _ in 0..<count {
            children.append(try ChildProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:]))
        }
        defer { for child in children { kill(child.pid, SIGKILL) } }
        let payload = Data(repeating: 0x41, count: 512 << 10) // well past a pipe's 64 KB
        let failures = Counter()
        let writes = children.map { child in
            let writer = LineWriter(child.stdin)
            return Task.detached { do { try await writer.write(payload) } catch { failures.add() } }
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(100))
        // A starved pool never wakes the sleep at all; a busy CI runner has stretched it to 2.9 s.
        #expect(ContinuousClock.now - start < .seconds(10), "the task pool is starved")
        for child in children { kill(child.pid, SIGKILL) }
        for write in writes { await write.value }
        #expect(failures.value == count)
    }

    /// Closing waits at most the bound: work that would take 30 s gives up at the 0.2 s bound. Judged against 10 s, far
    /// from both, since a busy CI runner has stretched the 0.2 s to 2.5 s.
    @Test func boundedWorkGivesUp() async {
        let started = ContinuousClock.now
        await Router.bounded(seconds: 0.2) { try? await Task.sleep(for: .seconds(30)) }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// An error that isn't a well-formed JSON-RPC error (no message, a string code) was dropped as malformed, so the
    /// request it answered waited forever: a turn, or a permission request to an app, stuck until the connection
    /// closed. It's an error all the same, and now ends the request as one.
    @Test func aMalformedErrorStillEndsTheRequest() async throws {
        // A usable integer code is kept (the router acts on -32000, sign-in required); otherwise an internal error.
        for (error, code) in [
            (#"{"code":-32000}"#, -32000), (#"{"code":"E1","message":"failed"}"#, RPCError.internalError),
            (#""failed""#, RPCError.internalError), (#"null"#, RPCError.internalError)
        ] {
            let parsed = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":4,"error":\#(error)}"#.utf8))
            guard case .response(.int(4), .failure(let failure)) = parsed else {
                Issue.record("\(error): \(parsed)"); continue
            }
            #expect(failure.code == code, "\(error)")
        }

        let (lines, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let peer = RPCPeer { data in
            guard let id = try? RPCMessage.parse(data), case .request(let rid, _, _) = id else { return }
            input.yield(Data(#"{"jsonrpc":"2.0","id":\#(rid.description),"error":{"code":-32000}}"#.utf8))
        }
        Task { await peer.run(lines) }
        let outcome = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await peer.request("session/prompt"); return "answered" } catch let error as RPCError {
                    return "error \(error.code)"
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5)); return "hung"
            }
            let first = try await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        #expect(outcome == "error -32000")
        input.finish()
    }
}
