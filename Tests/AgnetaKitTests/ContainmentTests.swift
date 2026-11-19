// The containment acceptance test (docs/CONTAINMENT.md): what an engine can read, write, launch and reach, on this
// Mac's macOS. A probe stands in for the engine and is started by the real supervisor, under the exact engine profile
// a `workspace` session gets; it tries each thing, writes what happened, then answers `initialize` like an engine.
// Run on every supported macOS major version (CI); the result names the version it ran on.
import Darwin
import Foundation
import Testing

@testable import AgnetaKit

/// An engine that is a shell script: everything else as PlainAdapter.
struct ProbeAdapter: EngineAdapter {
    let script: String
    let plain = PlainAdapter()
    var id: String { "probe" }
    var displayName: String { "Probe" }
    var capabilities: EngineCapabilities { plain.capabilities }
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        EngineLaunch(
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": context.home.path(percentEncoded: false)],
            writable: [], readable: [], stateRoot: context.home)
    }
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?)
        -> JSONValue
    { plain.newSession(cwd: cwd, servers: servers, policy: policy, title: title, instructions: instructions) }
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        plain.loadSession(engineSession, cwd: cwd, servers: servers, policy: policy)
    }
    func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }
    func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? { nil }
    func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) { (false, nil) }
    func activeRun(in update: JSONValue) -> String?? { nil }
    func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) { (nil, nil, nil) }
    func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    func importedSession(_ result: JSONValue) -> String? { nil }
    func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? { nil }
}

/// A loopback TCP listener that accepts and holds connections, for checking which ports a sandbox reaches.
final class Listener {
    let socket: Int32
    let port: Int
    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        socket = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }
    deinit { close(socket) }
}

@Suite(.serialized) struct ContainmentTests {
    @Test func anEngineReachesOnlyWhatItsPolicyAllows() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-containment-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "work", directoryHint: .isDirectory),
            readable = root.appending(path: "reference", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        for folder in [workspace, readable, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "in".write(to: workspace.appending(path: "in.txt"), atomically: true, encoding: .utf8)
        try "ref".write(to: readable.appending(path: "ref.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: outside.appending(path: "tool"))
        let mcp = try Listener(), other = try Listener()
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }

        // Each check prints `name=yes` when it got through, `name=no` when it didn't, and for the network
        // `name=denied` when the sandbox refused (as opposed to the network being unreachable).
        let script = """
            r="$HOME/results.txt"; : > "$r"
            check() { name=$1; shift; if "$@" >/dev/null 2>&1; then echo "$name=yes" >> "$r"; else echo "$name=no" >> "$r"; fi; }
            net() { name=$1; shift; out=$("$@" 2>&1); case "$out" in *"not permitted"*) echo "$name=denied" >> "$r";; *) echo "$name=allowed" >> "$r";; esac; }
            # nc names the error only with -v: "Operation not permitted" is the sandbox, anything else the network.
            check read-workspace cat '\(path(workspace))/in.txt'
            check write-workspace touch '\(path(workspace))/new.txt'
            check read-readable cat '\(path(readable))/ref.txt'
            check write-readable touch '\(path(readable))/new.txt'
            check read-outside cat '\(path(outside))/secret.txt'
            check write-outside touch '\(path(outside))/new.txt'
            check run-outside '\(path(outside))/tool' hi
            check read-ssh ls '\(home).ssh'
            check read-preferences ls '\(home)Library/Preferences'
            check read-documents ls '\(home)Documents'
            check signal-outside kill -0 \(getpid())
            check launch-services sh -c '/usr/bin/lsappinfo info -only pid Finder | grep -q pid'
            net app-port nc -v -z -G 2 127.0.0.1 \(mcp.port)
            net other-port nc -v -z -G 2 127.0.0.1 \(other.port)
            net remote-80 nc -v -z -G 3 1.1.1.1 80
            net remote-443 nc -v -z -G 3 1.1.1.1 443
            IFS= read -r line
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"agentInfo":{"name":"probe"}}}\\n' "$id"
            exec cat > /dev/null
            """
        let probe = ProbeAdapter(script: script)
        let supervisor = EngineSupervisor(
            .init(shellTool: BuiltTools.shell, root: root.appending(path: "agneta")),
            accounts: ["a": ProviderSetup(kind: .openAI, apiKey: "k")])
        let context = PolicyContext(
            userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [root.appending(path: "agneta")])
        let policy = try SessionPolicy.parse(
            ["tools": "workspace", "readable": [.string(path(readable))]], cwd: path(workspace), context: context)
        let lease = try await supervisor.open(
            account: "a", engine: probe, policy: policy, mcpPorts: [mcp.port], key: nil,
            session: EngineSessionSpec(policy: policy, servers: [], instructions: nil))
        let results = try String(
            contentsOf: EngineHomes.home(root: root.appending(path: "agneta"), key: lease.key).appending(
                path: "results.txt"), encoding: .utf8)
        await supervisor.stopAll()
        let got = Dictionary(
            uniqueKeysWithValues: results.split(separator: "\n").map {
                $0.split(separator: "=", maxSplits: 1).map(String.init)
            }.map { ($0[0], $0[1]) })
        let expected = [
            "read-workspace": "yes", "write-workspace": "yes", "read-readable": "yes", "write-readable": "no",
            "read-outside": "no", "write-outside": "no", "run-outside": "no",
            "read-ssh": "no", "read-preferences": "no", "read-documents": "no",
            "signal-outside": "no", "launch-services": "no",
            "app-port": "allowed", "other-port": "denied", "remote-80": "denied", "remote-443": "allowed"
        ]
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        for (check, want) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(got[check] == want, "\(check) on macOS \(version): \(got[check] ?? "missing"), expected \(want)")
        }
        print("containment on macOS \(version): \(expected.count) checks")
    }
}
