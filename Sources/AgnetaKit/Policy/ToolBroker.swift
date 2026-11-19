// Runs engine shell commands under the strict tool profile. Goose calls
// GOOSE_SHELL -c <command>; that is `agneta-shell`, which forwards the command
// here over a Unix socket. macOS won't nest a stricter sandbox inside the
// engine's, so Agneta (unsandboxed) starts each command itself.
//
// Wire format, one line each: the client sends a JSON request
// {"token","cwd","command"}; the broker replies with lines "o <base64>",
// "e <base64>" and finally "x <status>". Closing the socket stops the command.
import CryptoKit
import Darwin
import Foundation

public struct ToolRequest: Codable, Sendable {
    public var token: String
    public var cwd: String
    public var command: String
}

public final class ToolBroker: @unchecked Sendable {
    /// What the broker needs to run a command for a session.
    public struct Grant: Sendable {
        public var profile: String
        public var environment: [String: String]
        public init(profile: String, environment: [String: String]) {
            self.profile = profile
            self.environment = environment
        }
    }

    public let socketPath: String
    private let resolve: @Sendable (_ token: String, _ cwd: URL) -> Grant?
    /// Each command's outcome for the task trace: command, cwd, exit status or signal, timing, output sizes.
    private let report: @Sendable (_ token: String, _ fields: [String: JSONValue]) -> Void
    private let shell: String
    /// `agneta-shell`, run as each command's group holder (`--hold`), so what a command starts in the background lives
    /// on until its engine ends; without it, a command's group ends with the command.
    private let holder: String?
    private var listener: Int32 = -1
    /// Each token's commands still running, so they stop with their engine: an engine killed, retired or revoked
    /// can leave its shells behind (Claude Code's are detached), and a command must never outlive its session.
    private let registryLock = NSLock()
    private var running: [String: [UUID: ChildProcess]] = [:]
    private var revoked: Set<String> = []
    /// Set once Agneta stops: every command has been ended and none starts again.
    private var stopped = false

    /// - Parameter resolve: maps an engine's token and the command's working directory to the
    ///   session that may run it, or nil to refuse. Each engine process has its own token.
    public init(
        socketPath: String, shell: String = "/bin/bash", holder: String? = nil,
        resolve: @escaping @Sendable (_ token: String, _ cwd: URL) -> Grant?,
        report: @escaping @Sendable (_ token: String, _ fields: [String: JSONValue]) -> Void = { _, _ in }
    ) {
        self.socketPath = socketPath
        self.shell = shell
        self.holder = holder
        self.resolve = resolve
        self.report = report
    }

    public func start() throws {
        unlink(socketPath)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ChildProcessError.pipeFailed(errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ChildProcessError.spawnFailed(path: socketPath, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw ChildProcessError.spawnFailed(path: socketPath, errno: errno)
        }
        let fd = listener
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                guard let self else { close(client); return }
                Thread { self.serve(client) }.start()
            }
        }
        thread.name = "agneta.tool-broker"
        thread.start()
    }

    /// Closes the socket and ends every command still running, background jobs included: none outlives Agneta.
    public func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        unlink(socketPath)
        let children = registryLock.withLock { () -> [ChildProcess] in
            stopped = true
            defer { running.removeAll() }
            return running.values.flatMap(\.values)
        }
        for child in children { child.signalGroup(SIGKILL) }
    }

    /// Stops every command a token's engine started and refuses any it starts later: its engine ended, was retired, or
    /// lost its session. Returns how many were running.
    @discardableResult
    public func stopCommands(token: String) -> Int {
        let children = registryLock.withLock { () -> [ChildProcess] in
            revoked.insert(token)
            return Array((running.removeValue(forKey: token) ?? [:]).values)
        }
        for child in children { child.signalGroup(SIGKILL) }
        return children.count
    }

    /// How many commands a token's engine has running now.
    public func runningCommands(token: String) -> Int { registryLock.withLock { running[token]?.count ?? 0 } }

    private func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let input = FileHandle(fileDescriptor: client, closeOnDealloc: true)
        @Sendable func reply(_ line: String) -> Bool {
            let data = Data((line + "\n").utf8)
            return data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) } == data.count
        }
        var splitter = LineSplitter(limit: 1 << 20)
        var requestLine: Data?
        while requestLine == nil {
            let chunk = input.availableData
            if chunk.isEmpty { return }
            requestLine = (try? splitter.push(chunk))?.first
        }
        guard let line = requestLine, let request = try? JSONDecoder().decode(ToolRequest.self, from: line),
            !request.token.isEmpty
        else {
            _ = reply("e " + Data("agneta: refused\n".utf8).base64EncodedString())
            _ = reply("x 126")
            return
        }
        let cwd = URL(filePath: request.cwd, directoryHint: .isDirectory).realFileURL
        let started = ContinuousClock.now
        var fields: [String: JSONValue] = [
            "command": .string(request.command), "cwd": .string(cwd.path(percentEncoded: false))
        ]
        guard let grant = resolve(request.token, cwd) else {
            _ = reply(
                "e "
                    + Data("agneta: no session allows commands in \(cwd.path(percentEncoded: false))\n".utf8)
                    .base64EncodedString())
            _ = reply("x 126")
            fields["refused"] = "outside the session's folders"
            report(request.token, fields)
            return
        }
        // An engine that ended starts nothing more, though its shell may live on.
        if registryLock.withLock({ stopped || revoked.contains(request.token) }) {
            _ = reply("e " + Data("agneta: this engine's session has ended\n".utf8).base64EncodedString())
            _ = reply("x 126")
            fields["refused"] = "engine ended"
            report(request.token, fields)
            return
        }
        // The command's group: its holder's when there is one (background jobs live on), else its own.
        var holding: ChildProcess?
        let child: ChildProcess
        do {
            holding = try holder.map { try ChildProcess(executable: $0, arguments: ["--hold"], environment: [:]) }
            child = try ChildProcess(
                executable: shell, arguments: ["-c", request.command], environment: grant.environment,
                directory: cwd.path(percentEncoded: false), wrapper: ["/usr/bin/sandbox-exec", "-p", grant.profile],
                joining: holding?.pid)
        } catch {
            holding?.signalGroup(SIGKILL)
            _ = reply("e " + Data("agneta: \(error)\n".utf8).base64EncodedString())
            _ = reply("x 127")
            fields["refused"] = .string("couldn't start: \(error)")
            report(request.token, fields)
            return
        }
        try? child.stdin.close()
        // The holder waits for this before watching its group, and ends the group if the pipe closes: Agneta gone.
        let keeper = holding
        try? keeper?.stdin.write(contentsOf: Data("g".utf8))
        let id = UUID()
        // What ends the command and all it started: its holder's group, which stays listed until the holder leaves (the
        // group is empty), so background jobs end with their engine; or the command's own group, listed while it runs.
        let ender = keeper ?? child
        let admitted = registryLock.withLock { () -> Bool in
            guard !stopped, !revoked.contains(request.token) else { return false }
            running[request.token, default: [:]][id] = ender
            return true
        }
        if !admitted { ender.signalGroup(SIGKILL) }
        defer { if keeper == nil { registryLock.withLock { _ = running[request.token]?.removeValue(forKey: id) } } }
        if let keeper {
            let token = request.token
            Task { [weak self] in
                _ = await keeper.waitForExit()
                self?.registryLock.withLock { _ = self?.running[token]?.removeValue(forKey: id) }
            }
        }
        let lock = NSLock()
        let counts = OutputCounts()
        // If the client goes away (Goose timed out or the session stopped), stop the command and whatever it
        // started. Only while the command runs: once it's done its group may be gone and its number reused.
        let watcher = Thread {
            var byte: UInt8 = 0
            while read(client, &byte, 1) > 0 {}
            lock.withLock { if !counts.finished { ender.signalGroup(SIGKILL) } }
        }
        watcher.start()
        let group = DispatchGroup()
        for (handle, tag) in [(child.stdout, "o"), (child.stderr, "e")] {
            group.enter()
            Thread {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    lock.lock()
                    if !counts.finished {
                        _ = reply("\(tag) \(data.base64EncodedString())")
                        counts.add(data, stderr: tag == "e")
                    }
                    lock.unlock()
                }
                group.leave()
            }.start()
        }
        // The shell's own exit ends the command, not its output: a background child (`npm run dev &`) keeps the
        // pipes open, and waiting for them would hang the tool call and leave the child running.
        let semaphore = DispatchSemaphore(value: 0)
        let box = StatusBox()
        Task {
            box.value = await child.waitForExit(); semaphore.signal()
        }
        semaphore.wait()
        let raw = box.value
        // Whatever the command left running in its group (`nohup … &`) ended with it (ChildProcess's reaper), which
        // also closes the pipes.
        // Output already written is still delivered; a process that left the group can't hold the answer up.
        _ = group.wait(timeout: .now() + 2)
        let status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        lock.withLock {
            counts.finished = true
            _ = reply("x \(status)")
        }
        shutdown(client, SHUT_RDWR)
        let elapsed = ContinuousClock.now - started
        if (raw & 0x7f) == 0 {
            fields["exit"] = .int(Int64(status))
        } else {
            fields["signal"] = .int(Int64(raw & 0x7f))
        }
        fields["ms"] = .double(
            ((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) * 10).rounded()
                / 10)
        fields["stdoutBytes"] = .int(Int64(counts.stdout))
        fields["stderrBytes"] = .int(Int64(counts.stderr))
        if !counts.stderrTail.isEmpty {
            fields["stderrTail"] = .string(String(decoding: counts.stderrTail, as: UTF8.self))
        }
        fields["profileSha256"] = .string(
            SHA256.hash(data: Data(grant.profile.utf8)).map { String(format: "%02x", $0) }.joined())
        report(request.token, fields)
    }
}

/// Output sizes and the end of stderr (where sandbox refusals show), filled from the reader threads under the broker's lock.
private final class OutputCounts: @unchecked Sendable {
    /// The exit status was sent: nothing more goes to the client, and the command's group is not ours to signal.
    var finished = false
    var stdout = 0
    var stderr = 0
    var stderrTail = Data()

    func add(_ data: Data, stderr isStderr: Bool) {
        if isStderr {
            stderr += data.count
            stderrTail = (stderrTail + data).suffix(2048)
        } else {
            stdout += data.count
        }
    }
}

private final class StatusBox: @unchecked Sendable { var value: Int32 = 0 }
