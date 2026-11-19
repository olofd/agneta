// Engine probe: drives goose-acp directly over ACP and prints what happens.
// Not shipped. Usage:
//   agneta-probe --goose <path> --home <dir> --cwd <dir> [--env KEY=VALUE]... [--mcp <url> --mcp-token <t>]
//                [--system <text>] [--builtins] [--sandbox <profile>] [--raw] --prompt <text> [--prompt <text>]...
import AgnetaKit
import Foundation

struct Options {
    var goose = ""
    var home = ""
    var cwd = ""
    var env: [String: String] = [:]
    var prompts: [String] = []
    var mcp: String?
    var mcpToken: String?
    var system: String?
    var builtins = false
    var sandbox: String?
    var raw = false
    var confine: [Int]?
    var paths: [String] = []
    var writable: [String] = []
}

func parse() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value() -> String { args.isEmpty ? "" : args.removeFirst() }
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--goose": options.goose = value()
        case "--home": options.home = value()
        case "--cwd": options.cwd = value()
        case "--env":
            let pair = value().split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { options.env[pair[0]] = pair[1] }
        case "--pass-env":
            // Copies a variable from this process's environment, so secrets never appear in arguments.
            let name = value()
            if let secret = ProcessInfo.processInfo.environment[name] { options.env[name] = secret }
        case "--prompt": options.prompts.append(value())
        case "--mcp": options.mcp = value()
        case "--mcp-token": options.mcpToken = value()
        case "--system": options.system = value()
        case "--builtins": options.builtins = true
        case "--sandbox": options.sandbox = value()
        case "--raw": options.raw = true
        case "--path": options.paths.append(value())
        case "--writable": options.writable.append(value())
        case "--confine": options.confine = value().split(separator: ",").compactMap { Int($0) }
        default: FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8)); exit(2)
        }
    }
    return options
}

func line(_ text: String) { print(text); fflush(stdout) }

func compact(_ value: JSONValue?) -> String {
    guard let value, let data = try? JSONCoding.encode(value) else { return "null" }
    let text = String(decoding: data, as: UTF8.self)
    return text.count > 400 ? String(text.prefix(400)) + "…" : text
}

let options = parse()
var provider = options.env
var broker: ToolBroker?
let shellTool = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "agneta-shell")
if options.confine != nil && options.builtins {
    // Shell commands go through Agneta's broker and run under the strict tool profile.
    let workspace = URL(filePath: options.cwd, directoryHint: .isDirectory).realFileURL
    let toolProfile = SandboxProfile(kind: .tool, writable: [workspace], denied: []).render()
    let token = SecureRandom.token()
    let socket = FileManager.default.temporaryDirectory.appending(path: "agneta-\(getpid()).sock").path(percentEncoded: false)
    let service = ToolBroker(socketPath: socket) { offered, cwd in
        offered == token && cwd.isInside(workspace) ? .init(profile: toolProfile, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": workspace.path(percentEncoded: false), "LANG": "en_US.UTF-8"]) : nil
    }
    try service.start()
    broker = service
    provider["GOOSE_SHELL"] = shellTool.path(percentEncoded: false)
    provider["AGNETA_BROKER_SOCKET"] = socket
    provider["AGNETA_BROKER_TOKEN"] = token
}
let launch = GooseLaunch(
    executable: URL(filePath: options.goose),
    home: URL(filePath: options.home, directoryHint: .isDirectory),
    provider: provider,
    paths: options.paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
)
if options.env["CLAUDE_CONFIG_DIR"] != nil { try ClaudeCodeSignIn.linkKeychains(into: launch.home) }
var wrapper = options.sandbox.map { ["/usr/bin/sandbox-exec", "-f", $0] } ?? []
if let ports = options.confine {
    // Engine profile: writes only to its home and the workspace; loopback only to the given ports; 443 out.
    try launch.prepare()
    var profile = SandboxProfile(kind: .engine,
                                 writable: [launch.home, URL(filePath: options.cwd, directoryHint: .isDirectory)] + options.writable.map { URL(filePath: $0, directoryHint: .isDirectory) },
                                 denied: [],
                                 readable: [shellTool.deletingLastPathComponent(), URL(filePath: options.goose).deletingLastPathComponent()] + options.paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
                                    + (options.env["CLAUDE_CONFIG_DIR"] != nil ? [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains", directoryHint: .isDirectory)] : []),
                                 loopbackPorts: ports, remotePorts: [443])
    if let broker { profile.unixSockets = [URL(filePath: broker.socketPath)] }
    let file = launch.home.appending(path: "engine.sb")
    try profile.render().write(to: file, atomically: true, encoding: .utf8)
    wrapper = ["/usr/bin/sandbox-exec", "-f", file.path(percentEncoded: false)]
}
let started = ContinuousClock.now
let child = try launch.start(directory: URL(filePath: options.cwd, directoryHint: .isDirectory), wrapper: wrapper)
let (peer, lines) = RPCPeer.stdio(child)
let raw = options.raw

Task.detached {
    for try await chunk in LineStream.lines(from: child.stderr) {
        FileHandle.standardError.write(Data("[goose stderr] ".utf8) + chunk + Data("\n".utf8))
    }
}
await peer.handle(notifications: { method, params in
    if raw { line("← \(method) \(compact(params))"); return }
    let update = params?["update"]
    switch update?["sessionUpdate"]?.stringValue {
    case "agent_message_chunk": line("  text: \(update?["content"]?["text"]?.stringValue ?? compact(update?["content"]))")
    case "agent_thought_chunk": line("  thought: \(update?["content"]?["text"]?.stringValue ?? "")")
    case "tool_call": line("  tool_call: \(update?["title"]?.stringValue ?? "") \(compact(update?["rawInput"]))")
    case "tool_call_update": line("  tool_update: \(update?["status"]?.stringValue ?? "") \(compact(update?["content"]))")
    case "usage_update": line("  usage: \(compact(update))")
    case let kind?: line("  \(kind)")
    default: line("← \(method) \(compact(params))")
    }
})
await peer.handle(requests: { method, params in
    line("→ request from engine: \(method) \(compact(params))")
    if method == "session/request_permission" {
        let choices = params?["options"]?.arrayValue ?? []
        let allow = choices.first { $0["kind"]?.stringValue == "allow_once" } ?? choices.first
        return .success(["outcome": ["outcome": "selected", "optionId": allow?["optionId"] ?? "allow"]])
    }
    return .failure(RPCError(code: RPCError.methodNotFound, message: method))
})
Task { await peer.run(lines) }

do {
    let initialized = try await peer.request("initialize", [
        "protocolVersion": 1,
        "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        "clientInfo": ["name": "agneta-probe", "version": "0"],
    ])
    line("initialize (\(ContinuousClock.now - started)): \(compact(initialized))")

    var mcpServers: [JSONValue] = []
    var meta: [String: JSONValue] = [:]
    if let url = options.mcp {
        let server: JSONValue = [
            "type": "http", "name": "app", "url": .string(url),
            "headers": options.mcpToken.map { [["name": "Authorization", "value": .string("Bearer \($0)")]] } ?? [],
        ]
        mcpServers.append(server)
        if !options.builtins {
            // App-only tools: the app's MCP server is the session's only extension.
            meta["enabledExtensions"] = [["type": "mcp", "server": server]]
        }
    }
    var newParams: JSONValue = ["cwd": .string(options.cwd), "mcpServers": .array(mcpServers)]
    if !meta.isEmpty { newParams = newParams.setting("_meta", to: .object(meta)) }
    let session = try await peer.request("session/new", newParams)
    let sessionID = session["sessionId"] ?? .null
    line("session/new (\(ContinuousClock.now - started)): \(compact(session))")

    if let system = options.system {
        let result = try await peer.request("_goose/unstable/session/system-prompt/set", [
            "sessionId": sessionID, "mode": "set", "text": .string(system),
        ])
        line("system prompt: \(compact(result))")
    }

    for prompt in options.prompts {
        let promptStart = ContinuousClock.now
        line("prompt: \(prompt)")
        let result = try await peer.request("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": .string(prompt)]]])
        line("result (\(ContinuousClock.now - promptStart)): \(compact(result))")
    }
} catch {
    line("error: \(error)")
}
await child.stop()
broker?.stop()
line("stopped")
