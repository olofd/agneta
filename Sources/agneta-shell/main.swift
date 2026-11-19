// The shell Agneta gives engines it runs. Two ways in, one way out: each command goes to Agneta's tool broker,
// which runs it under the session's strict sandbox, and its output and exit status come back. No logic of its own,
// so it works inside the engine's sandbox with nothing but its socket.
//   agneta-shell -c <command>   GOOSE_SHELL, OpenCode's shell, and Claude Code's CLAUDE_CODE_SHELL_PREFIX: streams
//                               output and exits with the command's status.
//   agneta-shell --mcp          a stdio MCP server with one `shell` tool, for engines whose own shell can't be
//                               replaced (Codex): each call runs one command and returns its output and status.
//   agneta-shell --hold         the broker's, not an engine's: leads a command's process group while anything in it
//                               runs, so what the command left running in the background lives on (as in a terminal)
//                               and the group's number can't be reused until it's empty; then it leaves. Its stdin is
//                               Agneta's: when Agneta goes, it ends the group.
import Darwin
import Foundation

func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("agneta-shell: \(message)\n".utf8))
    exit(status)
}

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment

/// Runs one command through the broker, handing each output chunk to `output` ("o" stdout, "e" stderr); returns the
/// exit status, or nil when Agneta closed the command. `onConnect` gets the connection, whose shutdown cancels it:
/// the broker ends the command and all it started when its client goes.
func runBrokered(_ command: String, cwd: String, onConnect: (Int32) -> Void = { _ in }, output: (Character, Data) -> Void) -> Int32? {
    // The token from the engine's own file (Agneta's way: an environment can be read by other processes), or given directly.
    let token = env["AGNETA_BROKER_TOKEN_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? env["AGNETA_BROKER_TOKEN"]
    guard let path = env["AGNETA_BROKER_SOCKET"], let token, !token.isEmpty else {
        output("e", Data("agneta-shell: no broker configured\n".utf8))
        return 126
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0 else {
        output("e", Data("agneta-shell: can't reach Agneta (\(String(cString: strerror(errno))))\n".utf8))
        return 126
    }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    onConnect(fd)
    guard let request = try? JSONSerialization.data(withJSONObject: ["token": token, "cwd": cwd, "command": command]) else { return 126 }
    let line = request + Data("\n".utf8)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            let payload = String(text.dropFirst(2))
            switch text.first {
            case "o", "e": if let data = Data(base64Encoded: payload) { output(text.first!, data) }
            case "x": return Int32(payload) ?? 1
            default: break
            }
        }
    }
}

// MARK: -c

if args.count >= 3, args[1] == "-c" {
    let status = runBrokered(args[2], cwd: FileManager.default.currentDirectoryPath) { stream, data in
        (stream == "o" ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }
    guard let status else { fail("Agneta closed the command", 125) }
    exit(status)
}

// MARK: --hold

if args.count >= 2, args[1] == "--hold" {
    let group = getpgrp()
    /// The processes in this group besides the holder itself.
    func others() -> Int {
        var pids = [pid_t](repeating: 0, count: 4096)
        // It returns how many processes it listed, not bytes (measured on macOS 26).
        let count = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return 0 }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 != getpid() && $0 > 0 }.count
    }
    // Agneta writes one byte once the command is in this group, and keeps the pipe open for as long as Agneta runs.
    // The end of input before it: the command never started. After it: Agneta has gone, so all of the group ends too.
    var go: UInt8 = 0
    guard read(0, &go, 1) == 1 else { exit(0) }
    while others() > 0 {
        var watch = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&watch, 1, 1000) > 0 else { continue }
        var byte: UInt8 = 0
        if read(0, &byte, 1) <= 0 { killpg(group, SIGKILL); exit(0) }
    }
    exit(0)
}

// MARK: --mcp

guard args.count >= 2, args[1] == "--mcp" else { fail("usage: agneta-shell -c <command> | --mcp", 2) }
/// Whether this session may run commands: an engine's MCP server is configured per account, its sessions are not.
let enabled = env["AGNETA_SHELL"] == "1"
/// The session's workspace, where a command runs unless it names a folder inside it.
let workspace = env["AGNETA_SHELL_CWD"] ?? FileManager.default.currentDirectoryPath
/// A command's output beyond this is cut, keeping its start and end: a model reads the rest from a file.
let outputLimit = 100_000

/// Calls run at once, each on its own thread (Codex runs tool calls in parallel), so replies are written one at a time.
enum Wire {
    static let lock = NSLock()
    static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        lock.withLock { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    }
    static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
/// The calls running now, by request id, with their broker connections: a cancel shuts one down, and gets no reply.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: Int32] = [:]
    private var cancelled: Set<String> = []
    func connected(_ id: String, _ fd: Int32) {
        let cancel = lock.withLock { open[id] = fd; return cancelled.contains(id) }
        if cancel { shutdown(fd, SHUT_RDWR) }
    }
    func cancel(_ id: String) {
        lock.withLock {
            cancelled.insert(id)
            if let fd = open[id] { shutdown(fd, SHUT_RDWR) }
        }
    }
    /// Ends the call; true when it was cancelled.
    func finish(_ id: String) -> Bool {
        lock.withLock {
            open[id] = nil
            return cancelled.remove(id) != nil
        }
    }
}
let calls = Calls()
func key(_ id: Any) -> String { "\(id)" }

let tool: [String: Any] = [
    "name": "shell",
    "description": "Run a shell command (bash) in the session's workspace and return its output and exit status. Commands run in Agneta's sandbox for this session: the workspace and the session's folders, no network unless the session allows it. Use it for builds, tests, scripts and inspecting files.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "The command, run with bash -c"],
            "workdir": ["type": "string", "description": "The folder to run it in, inside the workspace (default: the workspace)"],
        ],
        "required": ["command"],
    ],
]

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        guard let id else { continue }
        Wire.reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "agneta", "version": "1"]])
    case "tools/list":
        guard let id else { continue }
        Wire.reply(id, ["tools": enabled ? [tool] : []])
    case "tools/call":
        guard let id else { continue }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard enabled, params["name"] as? String == "shell", let command = arguments["command"] as? String else {
            Wire.reply(id, ["content": [["type": "text", "text": "Unknown tool or missing command"]], "isError": true])
            continue
        }
        var folder = workspace
        if let workdir = arguments["workdir"] as? String, !workdir.isEmpty {
            folder = workdir.hasPrefix("/") ? workdir : URL(filePath: workspace, directoryHint: .isDirectory).appending(path: workdir).path(percentEncoded: false)
        }
        let name = key(id), cwd = folder
        nonisolated(unsafe) let requestId = id
        Thread {
            var out = Data(), err = Data()
            let status = runBrokered(command, cwd: cwd, onConnect: { calls.connected(name, $0) }) { stream, data in
                if stream == "o" { out.append(data) } else { err.append(data) }
            }
            guard !calls.finish(name) else { return }
            func clipped(_ data: Data) -> String {
                let text = String(decoding: data, as: UTF8.self)
                guard text.count > outputLimit else { return text }
                return String(text.prefix(outputLimit / 2)) + "\n… (\(text.count - outputLimit) characters cut) …\n" + String(text.suffix(outputLimit / 2))
            }
            var text = clipped(out)
            if !err.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + clipped(err) }
            text += "\n[exit \(status.map(String.init) ?? "closed")]"
            Wire.reply(requestId, ["content": [["type": "text", "text": text]], "isError": status != 0])
        }.start()
    case "notifications/cancelled":
        if let request = params["requestId"] { calls.cancel(key(request)) }
    case "ping":
        if let id { Wire.reply(id, [:]) }
    default:
        // Other notifications (initialized) need no answer; an unknown request gets "method not found".
        if let id { Wire.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
    }
}
