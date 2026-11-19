// The sandbox a task runs in: one ladder for every engine, decided in one place. Three inputs meet here:
// - the user's choice for the app (its grant: chosen at pairing and in Settings → Apps), which is the ceiling. Full
//   power is the default: "no restrictions in power of the agent if it's not requested by the user" (the maintainer);
// - the app's request, which may only be more restrictive: "an app should be able to select a more restrictive model if
//   it wishes than the user selected, but not the other way around";
// - what the engine can provide on that provider: one that can't contain its own tools (ProviderEngines.uncontained)
//   is never hidden or cut down, but a request it can't honour is refused, with the reason.
// The answer is the level the task gets, reported to the app as it is, or a refusal that says exactly why.
import Foundation

public enum Sandbox: String, Sendable, Codable, CaseIterable, Comparable {
    /// Agneta's contained sandbox: the session's folders only, no internet for commands, every command through the broker.
    case contained
    /// Developer access: as in a terminal, with the internet, the home folder (credentials and private data excepted)
    /// and the user's own toolchains (DeveloperAccess).
    case developer

    public static func < (a: Sandbox, b: Sandbox) -> Bool { a == .contained && b == .developer }

    /// A grant's mode until the user chooses less: full power.
    public static let `default` = Sandbox.developer

    /// The level's name as people see it.
    public var title: String { self == .contained ? "Contained" : "Developer access" }
}

public enum SandboxResolution {
    /// What a task gets: `profile` is the sandbox Agneta builds (developer access widens it only for workspace tools);
    /// `effective` is what the task can really do, which an engine that can't contain its tools raises to developer.
    public struct Outcome: Sendable, Equatable {
        public var profile: Sandbox
        public var effective: Sandbox
    }

    /// - Parameters:
    ///   - requested: the app's `sandbox`, or nil when it didn't ask.
    ///   - ceiling: the user's choice for the app (its grant).
    ///   - levels: what the engine can provide on that provider.
    ///   - tools: the policy's tools. Developer access means commands like a terminal's, so it applies to workspace
    ///     tools; a session that asked for fewer tools stays contained unless the engine can't be.
    ///   - why: why the engine can't contain its tools there, for the refusal.
    public static func resolve(
        requested: Sandbox?, ceiling: Sandbox, levels: [Sandbox], tools: SessionPolicy.Tools,
        provider: String, why: String?
    ) -> Result<Outcome, PolicyRejection> {
        let wanted = requested ?? (tools == .workspace ? ceiling : .contained)
        if wanted > ceiling {
            return .failure(
                PolicyRejection(
                    field: "sandbox",
                    reason:
                        "the user keeps this app's tasks contained (Settings → Apps in Agneta); an app can ask for less, not more"
                ))
        }
        if levels.contains(wanted) {
            return .success(Outcome(profile: tools == .workspace ? wanted : .contained, effective: wanted))
        }
        // Only an engine that can't contain its tools gets here, asked for contained: by the app, or because the user
        // chose it. Run it uncontained only when neither asked for a restriction.
        if requested == nil, ceiling == .developer, levels.contains(.developer) {
            return .success(Outcome(profile: .contained, effective: .developer))
        }
        return .failure(
            PolicyRejection(
                field: "sandbox",
                reason: (why ?? "this engine can't keep \(provider)'s tasks contained")
                    + "; choose another engine, or developer access"))
    }
}
