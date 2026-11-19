// OpenCode's per-session configuration, as Agneta generates it (Engine/OpenCodeAdapter.swift).
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct OpenCodeAdapterTests {
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [])
    func policy(_ value: JSONValue) throws -> SessionPolicy {
        try SessionPolicy.parse(
            value, cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context)
    }
    let appServer: JSONValue = [
        "type": "http", "name": "app", "url": "http://127.0.0.1:47471/mcp",
        "headers": [["name": "Authorization", "value": "Bearer secret"]]
    ]

    func rules(_ config: JSONValue) -> [String] {
        (config["permissions"]?.arrayValue ?? []).map {
            "\($0["action"]?.stringValue ?? "?"):\($0["effect"]?.stringValue ?? "?")"
        }
    }

    @Test func appOnlySessionsReachOnlyTheAppsTools() throws {
        let spec = EngineSessionSpec(
            policy: try policy(["tools": "app-only", "approval": "never-ask"]), servers: [appServer],
            instructions: "Be the app's agent.")
        let config = OpenCodeAdapter.configuration(
            provider: ProviderSetup(kind: .anthropic, model: "claude-x", apiKey: "k"), session: spec, shell: nil)
        #expect(rules(config) == ["*:deny", "app_*:allow"])
        #expect(config["mcp"]?["servers"]?["app"]?["codemode"]?.boolValue == false)
        #expect(config["mcp"]?["servers"]?["app"]?["headers"]?["Authorization"]?.stringValue == "Bearer secret")
        #expect(config["agents"]?["agneta"]?["system"]?.stringValue == "Be the app's agent.")
        #expect(config["model"]?.stringValue == "anthropic/claude-x" && config["providers"] == nil)
        for off in ["snapshots", "lsp", "formatter"] { #expect(config[off]?.boolValue == false) }
        #expect(config["update"]?.stringValue == "disable" && config["share"]?.stringValue == "disabled")
    }

    @Test func workspaceSessionsAskTheAppWhenItWantsTo() throws {
        let spec = EngineSessionSpec(
            policy: try policy(["tools": "workspace", "approval": "ask-app"]), servers: [appServer], instructions: nil)
        let config = OpenCodeAdapter.configuration(
            provider: ProviderSetup(kind: .openAI, apiKey: "k"), session: spec, shell: URL(filePath: "/x/agneta-shell"))
        #expect(
            rules(config) == ["*:deny", "app_*:ask", "read:allow", "glob:allow", "grep:allow", "edit:ask", "shell:ask"])
        #expect(config["shell"]?.stringValue == "/x/agneta-shell")
    }

    @Test func aBaseURLBecomesAnOpenAICompatibleProvider() {
        let config = OpenCodeAdapter.configuration(
            provider: ProviderSetup(kind: .openAI, model: "gpt-4o", apiKey: "fake", baseURL: "http://127.0.0.1:1/v1"),
            session: nil, shell: nil)
        #expect(config["model"]?.stringValue == "agneta/gpt-4o")
        #expect(config["providers"]?["agneta"]?["package"]?.stringValue == "@ai-sdk/openai-compatible")
        #expect(config["providers"]?["agneta"]?["settings"]?["baseURL"]?.stringValue == "http://127.0.0.1:1/v1")
    }

    @Test func plansStayOnGoose() throws {
        let adapter = OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false"))
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-oc-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: RPCError.self) {
            _ = try adapter.launch(
                EngineLaunchContext(
                    home: home, provider: ProviderSetup(kind: .chatGPT), shell: nil, session: nil, loopbackPorts: []))
        }
        let launch = try adapter.launch(
            EngineLaunchContext(
                home: home, provider: ProviderSetup(kind: .anthropic, apiKey: "sk-ant-x"), shell: nil, session: nil,
                loopbackPorts: []))
        #expect(launch.arguments == ["acp"])
        #expect(
            launch.environment["ANTHROPIC_API_KEY"] == "sk-ant-x"
                && launch.environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(launch.environment["XDG_CONFIG_HOME"]?.hasPrefix(home.path(percentEncoded: false)) == true)
        #expect(adapter.capabilities.processPerSession && adapter.capabilities.steer && !adapter.capabilities.fork)
    }
}
