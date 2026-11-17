// Headless development host: Agneta's runtime and WebSocket server without the
// app UI, keeping its records in --home like the app does. Pairing requests are
// approved for every account and logged (the app asks the user instead). Not shipped.
// Usage: agnetad --goose <path> --home <dir> [--port 47331] [--env KEY=VALUE]...
import AgnetaKit
import Foundation

var goose = "", home = "", port: UInt16 = 47331
var env: [String: String] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    let value = args.isEmpty ? "" : args.removeFirst()
    switch flag {
    case "--goose": goose = value
    case "--home": home = value
    case "--port": port = UInt16(value) ?? port
    case "--env":
        let pair = value.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { env[pair[0]] = pair[1] }
    default: FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8)); exit(2)
    }
}
func log(_ text: String) { print("[agnetad] \(text)"); fflush(stdout) }

guard !goose.isEmpty, !home.isEmpty else {
    FileHandle.standardError.write(Data("Usage: agnetad --goose <path> --home <dir> [--port <port>] [--env KEY=VALUE]...\n".utf8))
    exit(2)
}
let root = URL(filePath: home, directoryHint: .isDirectory)
// Match the desktop host: app workspaces live beside the protected data root.
let workspaces = root.deletingLastPathComponent().appending(path: root.lastPathComponent + " Workspaces", directoryHint: .isDirectory)
let shellTool = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "agneta-shell")
let modelPorts = env["OPENAI_BASE_URL"].flatMap { URL(string: $0)?.port }.map { [$0] } ?? []
// --env GOOSE_PROVIDER=openai|anthropic, GOOSE_MODEL, OPENAI_API_KEY / ANTHROPIC_API_KEY, OPENAI_BASE_URL.
let provider = ProviderSetup(kind: env["GOOSE_PROVIDER"] == "anthropic" ? .anthropic : .openAI, model: env["GOOSE_MODEL"],
                             apiKey: env["OPENAI_API_KEY"] ?? env["ANTHROPIC_API_KEY"], baseURL: env["OPENAI_BASE_URL"])
let engine = GooseAdapter(executable: URL(filePath: goose))
let runtime = try await AgnetaRuntime(.init(store: AgnetaStore(root: root), engines: [engine], shellTool: shellTool,
                                           appWorkspaces: workspaces, engineLoopbackPorts: modelPorts)) { request in
    let who = request.peer.map { "\($0.identifier ?? "unsigned") team \($0.team ?? "none") valid \($0.valid) pid \($0.pid)" } ?? "unidentified"
    log("pairing request from \(request.app) [\(who)]\(request.code.map { ", code \($0)" } ?? ""): approved for dev")
    return Router.PairingAnswer(accounts: ["dev"], remember: true)
}
await runtime.serve(account: "dev", label: "Development account", setup: AccountSetup(engine: "goose", provider: provider), runner: .brokered,
                    kind: nil, billing: "unknown", paused: false)
await runtime.observe { event in
    if case .router(.sessionEnded(let id, let ending)) = event { log("task \(id) ended: \(ending.rawValue)") }
}
let router = runtime.router, supervisor = runtime.supervisor

let server = try WebSocketServer(port: port)
try await server.start()
log("listening on ws://127.0.0.1:\(port)/acp")

signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let stopSources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
for source in stopSources {
    source.setEventHandler {
        log("stopping")
        server.stop()
        Task { await runtime.stopAll(); exit(0) }
    }
    source.resume()
}
for await connection in server.connections {
    log("app connected from port \(connection.remotePort.map(String.init) ?? "?")")
    Task {
        await router.serve(connection)
        log("app disconnected; \(await router.sessionCount) sessions, \(await supervisor.processCount) engines left")
    }
}
