// A provider's default model and reasoning effort (Settings → Providers). Each engine offers its own as ACP config
// options, found by category (`model`, `thought_level`; docs/APP_PROTOCOL.md, Model and thinking), so defaults are
// applied the same way on every engine: right after `session/new`, before the app sees the session, and only where
// the engine lists the value. The app can still choose its own afterwards. What an engine offered is reported
// (`settingsSeen`), as the engine set it before any default, so Settings can list real choices and name the engine's own; `probeSettings` asks an engine without sending a prompt.
import Foundation

extension Router {
    /// The categories a provider's defaults set, in the order they're set: a model's change can change the efforts
    /// on offer, so the model goes first.
    static let defaultCategories = ["model", "thought_level"]

    /// Sets an account's defaults; nil (or empty) leaves that setting to the engine.
    public func setDefaults(account: String, model: String?, effort: String?) {
        var wanted: [String: String] = [:]
        if let model, !model.isEmpty { wanted["model"] = model }
        if let effort, !effort.isEmpty { wanted["thought_level"] = effort }
        settingDefaults[account] = wanted.isEmpty ? nil : wanted
    }

    /// Every value an option offers, grouped or not.
    static func choices(_ option: JSONValue) -> [String] {
        (option["options"]?.arrayValue ?? []).flatMap { item -> [String] in
            if let value = item["value"]?.stringValue { return [value] }
            return (item["options"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue }
        }
    }

    /// A new session with its account's defaults applied, as the engine reports it after: each default the engine
    /// lists and isn't already current is set with `session/set_config_option`. One the engine refuses is left.
    func withDefaults(_ result: JSONValue, account: String, lease: EngineLease, engineSession: String) async -> JSONValue {
        guard let wanted = settingDefaults[account], var options = result["configOptions"]?.arrayValue else { return result }
        var updated = result
        for category in Self.defaultCategories {
            guard let value = wanted[category],
                  let option = options.first(where: { $0["category"]?.stringValue == category }),
                  let configID = option["id"]?.stringValue,
                  option["currentValue"]?.stringValue != value, Self.choices(option).contains(value) else { continue }
            let params: JSONValue = ["sessionId": .string(engineSession), "configId": .string(configID), "value": .string(value)]
            guard let answer = try? await lease.peer.request("session/set_config_option", params) else { continue }
            if let reported = answer["configOptions"], let list = reported.arrayValue {
                options = list
                updated = updated.setting("configOptions", to: reported)
            }
        }
        return updated
    }

    /// What `engine` offers on `account` (its config options), asked by opening a session with no tools and closing
    /// it: no prompt is sent, so nothing is spent. Reported as `settingsSeen` too.
    public func probeSettings(account: String, engine id: String) async throws -> JSONValue {
        guard accounts[account] != nil else { throw RPCError(code: RPCError.invalidParams, message: "Unknown provider") }
        guard let adapter = catalog.adapter(id) else { throw RPCError(code: RPCError.invalidParams, message: "That engine isn't here") }
        // An empty folder of Agneta's own to open the session in; nothing is written there.
        let root = context.appWorkspaces ?? FileManager.default.temporaryDirectory
        let folder = root.appending(path: ".agneta-settings-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var policy = SessionPolicy.fallback(workspace: folder.realFileURL)
        policy.tools = .appOnly
        let plan = Plan(account: account, engine: adapter, policy: policy, servers: [], instructions: nil)
        let lease: EngineLease
        switch await launch(plan, key: nil) {
        case .success(let started): lease = started
        case .failure(let error): throw error
        }
        beginOpening(lease.key)
        defer { endOpening(lease.key) }
        do {
            let result = try await lease.peer.request("session/new", adapter.newSession(cwd: policy.workspace, servers: [], policy: policy, title: nil, instructions: nil))
            if let session = result["sessionId"] {
                _ = try? await lease.peer.request("session/close", ["sessionId": session])
            }
            await engines.release(lease)
            let options = result["configOptions"] ?? .array([])
            onEvent(.settingsSeen(account: account, engine: id, options: options))
            return options
        } catch {
            await engines.release(lease)
            throw engineFailure(error, account: account, otherwise: "The engine stopped")
        }
    }
}
