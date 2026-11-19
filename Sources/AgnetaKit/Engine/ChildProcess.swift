// Starts an engine in its own process group with an explicit environment and
// stdio pipes. Agneta stops engines by their recorded group, never by name.
import Darwin
import Foundation

public enum ChildProcessError: Error, Equatable {
    case spawnFailed(path: String, errno: Int32)
    case pipeFailed(errno: Int32)
}

public final class ChildProcess: @unchecked Sendable {
    /// Whether it leads its own process group (the default) or joined a holder's.
    public let ownsGroup: Bool
    public let pid: pid_t
    public let stdin: FileHandle
    public let stdout: FileHandle
    public let stderr: FileHandle
    private let lock = NSLock()
    private var status: Int32?
    /// Whether the leader has been reaped, after which its number may be reused: group signals stop then.
    private final class Group: @unchecked Sendable {
        let lock = NSLock()
        var reaped = false
    }
    private let group = Group()
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// - Parameters:
    ///   - executable: absolute path.
    ///   - environment: the complete environment; nothing is inherited.
    ///   - wrapper: optional launcher prefix, for example `sandbox-exec -f profile`.
    ///   - joining: an existing process group to start in, whose leader (a holder) keeps it, rather than a group of its
    ///     own. Its exit then ends nothing else, and only it is signalled: the group is its holder's to end.
    public init(
        executable: String, arguments: [String], environment: [String: String], directory: String? = nil,
        wrapper: [String] = [],
        joining: pid_t? = nil
    ) throws {
        ownsGroup = joining == nil
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        for index in 0..<3 {
            let result = index == 0 ? pipe(&inPipe) : index == 1 ? pipe(&outPipe) : pipe(&errPipe)
            if result != 0 { throw ChildProcessError.pipeFailed(errno: errno) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group (pgid = pid) so Stop can signal the engine and its tools together;
        // close every other descriptor so no Agneta socket or file leaks into the engine.
        // Reset signal dispositions and the mask: a test runner or launcher that ignores
        // SIGTERM must not make the engine immune to Stop.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, joining ?? 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = (wrapper.isEmpty ? [executable] : wrapper + [executable]) + arguments
        let path = wrapper.first ?? executable
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var child: pid_t = 0
        let result = posix_spawn(&child, path, &actions, &attributes, &cArgs, &cEnv)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw ChildProcessError.spawnFailed(path: path, errno: result)
        }
        pid = child
        // A dead engine must surface as a write error, not SIGPIPE killing Agneta.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        stdin = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
        stdout = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        stderr = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)

        let leader = child, group = self.group, owns = ownsGroup
        let reaper = Thread { [weak self] in
            // Seen exited but not yet reaped: the leader is a zombie that still holds its number, so the group can't be
            // anyone else's. Whatever it left running in its group ends now, and only then is it reaped.
            // The exit, seen with kqueue: it neither reaps the leader nor fires for a stop (macOS's waitid with WNOWAIT
            // reports a stopped child over and over, spinning). If it can't tell, the group is left alone.
            let exited = ChildProcess.waitForExitUnreaped(leader)
            group.lock.withLock {
                if exited, owns { killpg(leader, SIGKILL) }
                group.reaped = true
            }
            var raw: Int32 = 0
            while waitpid(leader, &raw, 0) < 0 && errno == EINTR {}
            self?.finish(raw)
        }
        reaper.name = "agneta.reaper.\(leader)"
        reaper.start()
    }

    /// Blocks until `pid` has exited, without reaping it. True once it has; false if that can't be known.
    static func waitForExitUnreaped(_ pid: pid_t) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT),
            data: 0, udata: nil)
        var event = kevent()
        while true {
            let count = kevent(queue, &change, 1, &event, 1, nil)
            if count < 0 { if errno == EINTR { continue }; return errno == ESRCH }
            if count == 0 { continue }
            // Exited before the watch began: still a zombie, since only this reaper reaps it.
            if event.flags & UInt16(EV_ERROR) != 0 { return event.data == Int(ESRCH) }
            return event.fflags & UInt32(NOTE_EXIT) != 0
        }
    }

    private func finish(_ raw: Int32) {
        lock.lock()
        status = raw
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: raw) }
    }

    public var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return status != nil
    }

    /// The raw wait status once the process has exited.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Signals the process group, but only while its leader is unreaped: after that the number may belong to
    /// another program (the reaper has already ended what the group left behind).
    public func signalGroup(_ signal: Int32) {
        group.lock.withLock { if !group.reaped { if ownsGroup { killpg(pid, signal) } else { kill(pid, signal) } } }
    }

    /// Signals the whole process group: TERM, then KILL after `grace`. Returns once the leader has exited.
    public func stop(grace: Duration = .seconds(3)) async {
        try? stdin.close()
        guard !hasExited else { return } // its group was ended when it exited
        signalGroup(SIGTERM)
        let deadline = ContinuousClock.now + grace
        while !hasExited && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Still running after the grace: KILL the group. If the leader exited meanwhile, the reaper has already ended
        // what it left behind, and the group number is no longer ours to signal.
        signalGroup(SIGKILL)
        _ = await waitForExit()
    }
}
