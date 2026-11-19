// Signing plan accounts out of the engines that keep their sign-ins (Sign Out, Reset). Claude Code and Codex each keep
// an account's sign-in in the login Keychain, keyed by the account's folder, and only their own logout removes it:
// deleting the folder leaves the item behind. Without a usable install, or when its logout fails, the item stays, and
// the caller is told which, so it never claims a sign-in is gone when it may not be.
import Foundation

public enum PlanSignOut {
    /// A plan sign-in that may still be in the login Keychain.
    public struct Leftover: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// No supported install of the program was found, so its logout couldn't run.
            case noProgram
            /// Its logout ran and didn't succeed.
            case logoutFailed
        }

        public var kind: AccountKind
        /// The account's folder the sign-in is keyed by.
        public var home: URL
        public var reason: Reason

        public init(kind: AccountKind, home: URL, reason: Reason) {
            self.kind = kind
            self.home = home
            self.reason = reason
        }

        /// The program whose logout removes it.
        public var program: String { kind == .claude ? "Claude Code" : "Codex" }

        /// The item's name in Keychain Access.
        public var keychainItem: String { kind == .claude ? "Claude Code-credentials" : "Codex Auth" }
    }

    /// Runs each account folder's logout: Claude Code's for a folder with `claude/`, Codex's for one with `codex/`.
    /// Returns every sign-in that may remain, with why.
    public static func signOut(homes: [URL], claudeCode: URL?, codex: URL?) async -> [Leftover] {
        var leftovers: [Leftover] = []
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        for home in homes {
            let claude = home.appending(path: "claude", directoryHint: .isDirectory)
            if exists(claude) {
                if let claudeCode {
                    if await !ClaudeCodeSignIn(cli: claudeCode, configDirectory: claude).signOut() {
                        leftovers.append(Leftover(kind: .claude, home: home, reason: .logoutFailed))
                    }
                } else {
                    leftovers.append(Leftover(kind: .claude, home: home, reason: .noProgram))
                }
            }
            let codexHome = CodexAdapter.codexHome(account: home)
            if exists(codexHome) {
                if let codex {
                    if await !CodexSignIn(cli: codex, codexHome: codexHome).signOut() {
                        leftovers.append(Leftover(kind: .chatGPT, home: home, reason: .logoutFailed))
                    }
                } else {
                    leftovers.append(Leftover(kind: .chatGPT, home: home, reason: .noProgram))
                }
            }
        }
        return leftovers
    }

    /// What to tell the user about sign-ins that may remain: why, and how to remove them themselves. Nil when none.
    public static func explanation(_ leftovers: [Leftover]) -> String? {
        guard !leftovers.isEmpty else { return nil }
        var lines: [String] = []
        for program in ["Claude Code", "Codex"] {
            let mine = leftovers.filter { $0.program == program }
            guard let first = mine.first else { continue }
            let count = mine.count == 1 ? "1 sign-in" : "\(mine.count) sign-ins"
            let why =
                mine.allSatisfy { $0.reason == .noProgram }
                ? "no supported \(program) was found to sign out with"
                : "\(program)'s logout didn't succeed"
            lines.append(
                "\(count) on \(program) may still be in your login Keychain (\(why)). To remove "
                    + "\(mine.count == 1 ? "it" : "them"), open Keychain Access, search for “\(first.keychainItem)” and delete the "
                    + "items Agneta made (if you use \(program) yourself, its own item has the same name: signing in again "
                    + "recreates it).")
        }
        return lines.joined(separator: "\n\n")
    }
}
