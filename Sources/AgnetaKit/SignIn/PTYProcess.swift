// Runs a program on a pseudo-terminal, for sign-ins that only exist as
// interactive terminal commands (Claude Code's own login). The user never
// sees the terminal: Agneta reads its output and shows the steps natively.
import Darwin
import Foundation

public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    private let master: Int32
    private let lock = NSLock()
    private var exitStatus: Int32?
    public let output: AsyncStream<String>

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ChildProcessError.pipeFailed(errno: errno) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, Int32(target)) }
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals); sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var cArgs = ([executable] + arguments).map { strdup($0) } + [nil]
        var cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, &cArgs, &cEnv)
        close(slave)
        guard result == 0 else { close(master); throw ChildProcessError.spawnFailed(path: executable, errno: result) }
        pid = child
        self.master = master
        let (stream, sink) = AsyncStream<String>.makeStream()
        output = stream
        let fd = master, leader = child
        let reader = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                sink.yield(String(decoding: buffer[0..<count], as: UTF8.self))
            }
            var raw: Int32 = 0
            while waitpid(leader, &raw, 0) < 0 && errno == EINTR {}
            self?.lock.withLock { self?.exitStatus = raw }
            sink.finish()
        }
        reader.start()
    }

    /// Types text into the terminal, e.g. a code the user pasted into Agneta.
    public func send(_ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
    }

    public var status: Int32? { lock.withLock { exitStatus } }

    public func stop() {
        // The login runs in its own session (setsid), so its process group is its own.
        killpg(pid, SIGTERM)
        kill(pid, SIGTERM)
        // Two seconds later the number may belong to someone else: kill only if it's still the same process
        // (its start time), as crash recovery identifies engines.
        let group = pid
        let started = EngineReaper.startTime(of: group)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if let started, EngineReaper.startTime(of: group) == started { killpg(group, SIGKILL) }
        }
    }

    deinit { close(master) }
}

extension String {
    /// Terminal output without ANSI escape sequences.
    var withoutANSI: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-Za-z]", with: "", options: .regularExpression)
    }
}
