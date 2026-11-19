import Foundation
import Testing
@testable import AgnetaKit

@Suite struct LineSplitterTests {
    @Test func splitsAcrossChunksAndDropsCarriageReturns() throws {
        var splitter = LineSplitter(limit: 100)
        #expect(try splitter.push(Data("{\"a\":1}\r\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(try splitter.push(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(splitter.finish() == nil)
    }

    @Test func rejectsOverlongLines() {
        var splitter = LineSplitter(limit: 8)
        #expect(throws: LineStreamError.lineTooLong(limit: 8)) { try splitter.push(Data("0123456789".utf8)) }
        // A whole line over the limit too, not only one still arriving.
        var whole = LineSplitter(limit: 8)
        #expect(throws: LineStreamError.lineTooLong(limit: 8)) { try whole.push(Data("0123456789\nok\n".utf8)) }
    }

    /// A long line arriving in small chunks is scanned once: each push looks only at the bytes it brought.
    /// (Rescanning the whole buffer per 64 KB chunk took 32 MB to ~9 s, quadratic in the line's length.) Judged by
    /// growth, not a wall clock, so a slow machine can't fail it: eight times the line takes about eight times as
    /// long, while a rescan would take sixty-four. The best of three runs each, and a limit far from both, so a busy
    /// runner's noise can't decide it (one CI run measured 10.5x at four times the line, against a limit of 8).
    @Test func aLongLineIsFramedInLinearTime() throws {
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 << 10)
        func frame(chunks: Int) throws -> Duration {
            var splitter = LineSplitter(limit: 128 << 20)
            let started = ContinuousClock.now
            for _ in 0..<chunks { #expect(try splitter.push(chunk).isEmpty) }
            let lines = try splitter.push(Data("y\nz\r\n".utf8))
            #expect(lines.map(\.count) == [chunks * (64 << 10) + 1, 1] && lines.first?.last == UInt8(ascii: "y"))
            return ContinuousClock.now - started
        }
        func best(chunks: Int) throws -> Duration { try (0..<3).map { _ in try frame(chunks: chunks) }.min()! }
        let small = try best(chunks: 64), large = try best(chunks: 512)
        #expect(large < small * 24, "framing 32 MB took \(large), 4 MB \(small): more than linear growth")
        #expect(large < .seconds(20))
    }

    /// Many short lines in one chunk come out in order, with nothing copied twice.
    @Test func manyLinesInOneChunk() throws {
        var splitter = LineSplitter(limit: 100)
        let text = (0..<10_000).map { "line \($0)" }.joined(separator: "\n") + "\npartial"
        let lines = try splitter.push(Data(text.utf8))
        #expect(lines.count == 10_000 && lines.last == Data("line 9999".utf8))
        #expect(try splitter.push(Data(" end\n".utf8)) == [Data("partial end".utf8)])
    }
}

@Suite struct ChildProcessTests {
    @Test func passesOnlyTheGivenEnvironment() async throws {
        let child = try ChildProcess(executable: "/usr/bin/env", arguments: [], environment: ["ONLY": "this"])
        var output = Data()
        for try await line in LineStream.lines(from: child.stdout) { output.append(line) }
        #expect(String(decoding: output, as: UTF8.self) == "ONLY=this")
        #expect(await child.waitForExit() == 0)
    }

    @Test func stopEndsTheWholeGroup() async throws {
        // The shell starts a grandchild that would outlive a plain kill of the leader.
        let child = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $!; wait"], environment: [:])
        var grandchild: pid_t = 0
        for try await line in LineStream.lines(from: child.stdout) {
            grandchild = pid_t(String(decoding: line, as: UTF8.self))!
            break
        }
        #expect(kill(grandchild, 0) == 0)
        let started = ContinuousClock.now
        await child.stop(grace: .milliseconds(200))
        // It doesn't wait for the grandchild's minute (a loaded CI runner took 4.5 s, so the bound is loose).
        #expect(ContinuousClock.now - started < .seconds(20))
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(grandchild, 0) != 0)
    }
}

@Suite struct RPCPeerTests {
    /// Two peers wired back to back in memory.
    static func pair() -> (RPCPeer, RPCPeer) {
        let (toB, toBInput) = AsyncThrowingStream<Data, Error>.makeStream()
        let (toA, toAInput) = AsyncThrowingStream<Data, Error>.makeStream()
        let a = RPCPeer { toBInput.yield($0) }
        let b = RPCPeer { toAInput.yield($0) }
        Task { await a.run(toA) }
        Task { await b.run(toB) }
        return (a, b)
    }

    @Test func requestsResponsesAndNotifications() async throws {
        let (client, agent) = Self.pair()
        let (notes, notesInput) = AsyncStream<String>.makeStream()
        await agent.handle(requests: { method, params in
            method == "echo" ? .success(params ?? .null) : .failure(RPCError(code: RPCError.methodNotFound, message: method))
        })
        await client.handle(notifications: { method, _ in notesInput.yield(method) })

        #expect(try await client.request("echo", ["x": 1]) == ["x": 1])
        await #expect(throws: RPCError(code: RPCError.methodNotFound, message: "nope")) { try await client.request("nope") }
        try await agent.notify("session/update", ["sessionId": "s"])
        var iterator = notes.makeAsyncIterator()
        #expect(await iterator.next() == "session/update")
    }

    /// An engine connection is routed once, completely: whichever session wires it first installs the handlers,
    /// and a later attempt (another session on the shared engine) changes nothing.
    @Test func routingIsInstalledOnce() async throws {
        let (client, agent) = Self.pair()
        await agent.route(tap: nil, requests: { _, _ in .success("first") }, notifications: { _, _ in })
        await agent.route(tap: nil, requests: { _, _ in .success("second") }, notifications: { _, _ in })
        #expect(try await client.request("anything") == "first")
    }

    @Test func closingFailsPendingRequests() async throws {
        let (client, agent) = Self.pair()
        await agent.handle(requests: { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return .success(.null)
        })
        let answer = Task { try await client.request("slow") }
        try await Task.sleep(for: .milliseconds(50))
        await client.close("engine stopped")
        await #expect(throws: RPCPeer.PeerError.closed("engine stopped")) { _ = try await answer.value }
    }
}

@Suite struct LocalHTTPServerTests {
    /// Opens a TCP connection to the server and returns its descriptor.
    private func connect(_ port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        return socket
    }

    /// Connections that fail (here, reset by the client) are counted out once, so the cap of 16 holds: a count
    /// that went below zero let more through.
    @Test func failedConnectionsAreCountedOutOnce() async throws {
        let server = try LocalHTTPServer(port: 47616) { _ in .init(status: 200) }
        try await server.start()
        defer { server.stop() }
        for _ in 0..<20 {
            let socket = try connect(server.port)
            try await Task.sleep(for: .milliseconds(20))
            var reset = linger(l_onoff: 1, l_linger: 0) // close with a reset: the server's side fails
            setsockopt(socket, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
            close(socket)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.openConnections == 0)
        // The cap: 16 held open, and a 17th is turned away.
        let held = try (0..<LocalHTTPServer.maxConnections).map { _ in try connect(server.port) }
        defer { held.forEach { close($0) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.openConnections == LocalHTTPServer.maxConnections)
        let extra = try connect(server.port)
        defer { close(extra) }
        try await Task.sleep(for: .milliseconds(300))
        var byte: UInt8 = 0
        #expect(recv(extra, &byte, 1, 0) == 0) // closed by the server at once
        #expect(server.openConnections == LocalHTTPServer.maxConnections)
    }
}
