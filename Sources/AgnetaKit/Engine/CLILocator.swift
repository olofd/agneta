// Finds the user's own Claude Code and Codex. Agneta doesn't install either:
// it uses what's on the Mac, and lets the user pick when there's more than one.
// Claude Code comes bundled with the Claude desktop app or as a CLI install.
import Foundation

public struct InstalledCLI: Sendable, Equatable, Identifiable {
    public var path: URL
    public var version: String?
    /// Where it came from: "claude-app", "path", "local", "override".
    public var source: String
    /// The oldest version Agneta works with, when there is one.
    public var minimum: String?
    public var id: String { path.path(percentEncoded: false) }

    public init(path: URL, version: String?, source: String, minimum: String? = nil) {
        self.path = path
        self.version = version
        self.source = source
        self.minimum = minimum
    }

    /// Meets the minimum version, if there is one. An install whose version couldn't be read doesn't.
    public var supported: Bool {
        guard let minimum else { return true }
        return version.map { $0.compare(minimum, options: .numeric) != .orderedAscending } ?? false
    }

    public var label: String {
        let origin = switch source {
        case "claude-app": "Claude app"
        case "override": "chosen"
        default: path.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), with: "~/")
        }
        let note = supported ? nil : "needs \(minimum ?? "") or later"
        return [version, origin, note].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum CLILocator {
    /// Every Claude Code on this Mac, newest first: the Claude desktop app's bundled copies, then CLI installs.
    public static func claudeCode(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledCLI] {
        var found: [InstalledCLI] = []
        let root = home.appending(path: "Library/Application Support/Claude/claude-code", directoryHint: .isDirectory)
        for version in (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [] {
            let versionFolder = root.appending(path: version, directoryHint: .isDirectory)
            for hash in (try? FileManager.default.contentsOfDirectory(atPath: versionFolder.path(percentEncoded: false))) ?? [] {
                let binary = versionFolder.appending(path: "\(hash)/claude.app/Contents/MacOS/claude")
                if isExecutable(binary) { found.append(InstalledCLI(path: binary, version: version, source: "claude-app")) }
            }
        }
        found += commandLine("claude", home: home, extra: [home.appending(path: ".claude/local/claude")])
        return newestFirst(found)
    }

    /// The oldest Codex whose app-server schema the pinned codex-acp speaks.
    public static let codexMinimum = "0.166"

    /// Every Codex on this Mac, newest first, each marked with whether it's new enough.
    public static func codex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledCLI] {
        newestFirst(commandLine("codex", home: home, extra: []).map { found in
            var install = found
            install.minimum = codexMinimum
            return install
        })
    }

    /// The usual install places, resolved to the real file, with the version each reports.
    static func commandLine(_ name: String, home: URL, extra: [URL]) -> [InstalledCLI] {
        let places = [home.appending(path: ".local/bin/\(name)"), URL(filePath: "/opt/homebrew/bin/\(name)"), URL(filePath: "/usr/local/bin/\(name)")] + extra
        var seen: Set<String> = []
        return places.compactMap { place in
            guard isExecutable(place) else { return nil }
            let real = place.resolvingSymlinksInPath()
            guard seen.insert(real.path(percentEncoded: false)).inserted else { return nil }
            let source = place.path(percentEncoded: false).hasPrefix(home.path(percentEncoded: false)) ? "local" : "path"
            return InstalledCLI(path: real, version: version(of: real), source: source)
        }
    }

    /// `<cli> --version`, the first version-like word ("2.1.325 (Claude Code)", "codex-cli 0.167.0").
    static func version(of binary: URL) -> String? {
        guard let child = try? ChildProcess(executable: binary.path(percentEncoded: false), arguments: ["--version"],
                                            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]) else { return nil }
        try? child.stdin.close()
        // stderr drained alongside (a full pipe would block the child), and at most 5 s in all.
        let stderr = child.stderr
        DispatchQueue.global().async { _ = stderr.readDataToEndOfFile() }
        let pid = child.pid
        let watchdog = DispatchWorkItem { killpg(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = child.stdout.readDataToEndOfFile()
        watchdog.cancel()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { $0.first?.isNumber == true }.map(String.init)
    }

    static func isExecutable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) }

    static func newestFirst(_ list: [InstalledCLI]) -> [InstalledCLI] {
        list.sorted { ($0.version ?? "0").compare($1.version ?? "0", options: .numeric) == .orderedDescending }
    }
}
