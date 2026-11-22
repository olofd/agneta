import AppKit
import Foundation

public enum AgnetaPresence: Sendable, Equatable {
    case running
    case notInstalled
    case onDiskImage
    case notRunning(version: String?, placement: Placement)
    case blocked
    case unknown
    public enum Placement: Sendable { case applications, elsewhere }
}
public struct GuideQuestion: Sendable, Equatable {
    public enum Kind: Sendable { case install, open, update, setup }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let confirm: String
    public let cancel: String
}
public typealias Guide = @MainActor (GuideQuestion) async -> Bool
public struct ConnectProgress: Sendable, Equatable {
    public enum Step: Sendable {
        case looking, installing, opening, slow, connecting, needsProvider, pairing, connected, outdated
    }
    public let step: Step
    public let title: String
    public let code: String?
}

/// Native app discovery and explicit user-approved opening. Tests can replace this without launching applications.
@MainActor public protocol AgnetaEnvironment: Sendable {
    func lookup(_ build: AgnetaBuild) async -> AgnetaPresence
    func open(_ build: AgnetaBuild) async -> Bool
    func openInstallPage(_ build: AgnetaBuild) async -> Bool
}

/// Uses LaunchServices and the Applications folders. No shell, Apple Events, subprocesses, or Automation permission.
@MainActor public struct MacEnvironment: AgnetaEnvironment {
    public init() {}
    private func candidates(_ build: AgnetaBuild) -> [URL] {
        var candidates: [URL] = []
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: build.openURL) { candidates.append(handler) }
        candidates += [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        .map { $0.appendingPathComponent("\(build.name).app", isDirectory: true) }
        return candidates.filter { Bundle(url: $0)?.bundleIdentifier == build.bundleIdentifier }
    }
    private func onImage(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return true }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        return url.path.hasPrefix("/Volumes/") && readOnly
    }
    public func lookup(_ build: AgnetaBuild) async -> AgnetaPresence {
        let candidates = candidates(build)
        if let installed = candidates.first(where: { !onImage($0) }) {
            let version = Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let parent = installed.deletingLastPathComponent().standardizedFileURL
            let applications = [
                URL(fileURLWithPath: "/Applications"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            ]
            return .notRunning(version: version, placement: applications.contains(parent) ? .applications : .elsewhere)
        }
        return candidates.isEmpty ? .notInstalled : .onDiskImage
    }
    public func open(_ build: AgnetaBuild) async -> Bool {
        guard !Task.isCancelled, let installed = candidates(build).first(where: { !onImage($0) }) else { return false }
        // Open the verified bundle, rather than allowing an unrelated app to claim the URL scheme.
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration()) {
                application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
    public func openInstallPage(_ build: AgnetaBuild) async -> Bool {
        guard !Task.isCancelled else { return false }
        var url = build.installURL
        if build == .release {
            var translated: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
            #if arch(arm64)
                let architecture = "arm64"
            #else
                let architecture = rosetta ? "arm64" : "x86_64"
            #endif
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.fragment = architecture
            url = components.url!
        }
        return NSWorkspace.shared.open(url)
    }
}

/// Numeric version comparison. Development builds (`dev`, `0.0.0`) are never too old. Unknown versions return nil.
public func compareVersions(_ version: String?, _ needed: String?) -> ComparisonResult? {
    func parts(_ string: String?) -> [Int]? {
        guard let string else { return nil }
        let base = string.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let pieces = base.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    if version == "dev" || version == "0.0.0" { return .orderedSame }
    guard let left = parts(version), let right = parts(needed) else { return nil }
    for (a, b) in zip(left, right) { if a < b { return .orderedAscending }; if a > b { return .orderedDescending } }
    return .orderedSame
}
