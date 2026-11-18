// The maintainers' stand-in client app: pairs with Agneta over
// ws://127.0.0.1:<port>/acp, opens a session with a policy and an MCP server,
// prompts, and prints the stream. Built twice: as a plain tool, and as a
// sandboxed app bundle with Mac App Store entitlements (scripts/dev/testclient-app).
// It shows the protocol end to end and is not a client library: a real app keeps
// its token in the Keychain and handles reconnects (docs/APP_PROTOCOL.md).
// Usage: agneta-testclient [--port 47331] [--cwd <dir>] [--mcp <url> --mcp-token <t>] [--tools app-only|read|workspace] --prompt <text>...
// To reuse an earlier pairing, set AGNETA_TOKEN in the environment. It's never an argument: any local
// process can read another's arguments.
import AppKit
import Foundation

var port = 47331, cwd = "", mcp: String?, mcpToken: String?, tools = "app-only", prompts: [String] = [], token: String?, account: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    let value = args.isEmpty ? "" : args.removeFirst()
    switch flag {
    case "--port": port = Int(value) ?? port
    case "--cwd": cwd = value
    case "--mcp": mcp = value
    case "--mcp-token": mcpToken = value
    case "--tools": tools = value
    case "--prompt": prompts.append(value)
    case "--account": account = value
    default: break // Xcode/LaunchServices may add arguments to app launches.
    }
}
if let saved = ProcessInfo.processInfo.environment["AGNETA_TOKEN"], !saved.isEmpty { token = saved }

nonisolated(unsafe) var transcript: [String] = []
func say(_ text: String) { print("[client] \(text)"); fflush(stdout); transcript.append(text) }

/// Launched from Agneta's menu, it's a sandboxed app: it runs an app event loop and shows what happens in dialogs.
/// From a terminal, it only prints.
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

/// The pairing code's dialog, while Agneta waits for the user. Only the main thread touches it.
nonisolated(unsafe) var codeAlert: NSAlert?

/// Shows the code to compare with Agneta's approval window, until the user has answered there.
@MainActor func showCode(_ code: String) {
    let alert = NSAlert()
    alert.icon = NSImage(systemSymbolName: "number.square", accessibilityDescription: nil)
    alert.messageText = "Check this code in Agneta"
    alert.informativeText = "Agneta Test Client's code is \(code.prefix(3)) \(code.suffix(3)). Allow it in Agneta only if Agneta shows the same code."
    alert.addButton(withTitle: "OK")
    codeAlert = alert
    NSApp.activate(ignoringOtherApps: true)
    // Modal, but the connection keeps going: Swift's main-actor work runs in the modal loop too, and hideCode()
    // ends it once Agneta has the answer.
    alert.runModal()
    codeAlert = nil
}

@MainActor func hideCode() {
    guard codeAlert != nil else { return }
    codeAlert = nil
    NSApp.abortModal()
}

/// Shows the result (sandboxed) and quits.
@MainActor func finish(_ status: Int32) -> Never {
    if sandboxed {
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: status == 0 ? "checkmark.circle" : "exclamationmark.triangle", accessibilityDescription: nil)
        alert.messageText = status == 0 ? "Test task finished" : "Test task failed"
        let reply = transcript.filter { $0.hasPrefix("text: ") }.map { String($0.dropFirst(6)) }.joined()
        alert.informativeText = (reply.isEmpty ? "" : "Reply: \(reply)\n\n") + transcript.filter { !$0.hasPrefix("text: ") }.suffix(6).joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    exit(status)
}

final class Client: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    var nextID = 1
    var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    let lock = NSLock()

    init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        receive()
    }

    func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                say("connection closed: \(error.localizedDescription)")
                self.lock.withLock { self.waiting.values.forEach { $0.resume(throwing: error) }; self.waiting.removeAll() }
            case .success(let message):
                if case .string(let text) = message, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    self.handle(object, raw: Data(text.utf8))
                }
                self.receive()
            }
        }
    }

    func handle(_ message: [String: Any], raw: Data) {
        if let id = message["id"] as? Int, message["method"] == nil {
            let continuation = lock.withLock { waiting.removeValue(forKey: id) }
            continuation?.resume(returning: raw)
            return
        }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "agneta/pairingCode", let code = params["code"] as? String {
            // Agneta couldn't verify this app: show the code the user compares with Agneta's window.
            say("pairing code: \(code)")
            if sandboxed { DispatchQueue.main.async { showCode(code) } }
        } else if method == "session/update", let update = params["update"] as? [String: Any] {
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk": say("text: \((update["content"] as? [String: Any])?["text"] ?? "")")
            case "tool_call": say("tool: \(update["title"] ?? "")")
            case "tool_call_update": if let status = update["status"] as? String { say("tool \(status)") }
            default: break
            }
        } else if let id = message["id"], method == "session/request_permission" {
            // The policy can ask the app; this test client allows once.
            say("permission asked for: \((params["toolCall"] as? [String: Any])?["title"] ?? "a tool")")
            send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": "allow_once"]]])
        }
    }

    func send(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { say("couldn't send: \(error.localizedDescription)") }
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let raw = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            lock.withLock { waiting[id] = continuation }
            task.send(.string(String(decoding: body, as: UTF8.self))) { [self] error in
                // A request that wasn't sent fails now, instead of waiting for an answer that won't come.
                guard let error, let waiter = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
                waiter.resume(throwing: error)
            }
        }
        let reply = (try JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        if let error = reply["error"] as? [String: Any] {
            let detail = error["data"].map { " (\($0))" } ?? ""
            throw NSError(domain: "acp", code: error["code"] as? Int ?? 0, userInfo: [NSLocalizedDescriptionKey: (error["message"] as? String ?? "error") + detail])
        }
        return reply["result"] as? [String: Any] ?? [:]
    }
}

/// The whole exchange: pair, initialize, open a session, prompt. Returns the exit status.
@MainActor func run() async -> Int32 {
do {
    let client = Client(url: URL(string: "ws://127.0.0.1:\(port)/acp")!)
    if token == nil {
        // The scope the user approves: the tools this run uses, in the folder it was given (or none: its own workspace).
        var scope: [String: Any] = ["tools": tools]
        if !cwd.isEmpty { scope["folders"] = [cwd] }
        let paired: [String: Any]
        do { paired = try await client.request("agneta/pair", ["name": "Agneta Test Client", "scope": scope]); hideCode() } catch { hideCode(); throw error }
        token = paired["token"] as? String ?? ""
        say("paired; accounts \(paired["accounts"] ?? [])")
    }
    let initialized = try await client.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": token ?? ""]]])
    say("initialized: \((initialized["agentInfo"] as? [String: Any])?["title"] ?? "?")")
    if cwd.isEmpty {
        // Without a folder of its own choosing, the app works in the workspace Agneta gave it.
        cwd = ((initialized["_meta"] as? [String: Any])?["agneta"] as? [String: Any])?["workspace"] as? String ?? ""
    }
    var servers: [[String: Any]] = []
    if let mcp {
        servers.append(["type": "http", "name": "app", "url": mcp, "headers": mcpToken.map { [["name": "Authorization", "value": "Bearer \($0)"]] } ?? []])
    }
    let session = try await client.request("session/new", [
        "cwd": cwd, "mcpServers": servers,
        "_meta": ["agneta/policy@1": ["tools": tools, "network": "none", "approval": "ask-app"], "agneta/task@1": ["title": "Test task"],
                  "agneta/instructions": ["text": "You are a test assistant."], "agneta": ["account": account ?? ""]],
    ])
    let sessionID = session["sessionId"] as? String ?? ""
    say("session \(sessionID)")
    for prompt in prompts {
        let result = try await client.request("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": prompt]]])
        say("turn ended: \(result["stopReason"] ?? "?")")
    }
    say("done")
    return 0
} catch {
    say("failed: \(error.localizedDescription)")
    return 1
}
}

say("starting (sandboxed: \(sandboxed))")
Task { @MainActor in finish(await run()) }
if sandboxed {
    // A real app event loop: without it the dialogs never get their clicks, and macOS shows a spinning cursor.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
} else {
    dispatchMain()
}
