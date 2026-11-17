// What a sign-in shows while it runs, and how it fails. The sign-ins themselves
// are the user's own tools' (Claude Code's and Codex's login), run on a hidden
// terminal; Agneta shows each step in its own window.
import Foundation

/// Which pages a sign-in may show or open: only its provider's, over HTTPS. The URLs come from the provider's own
/// program's output; a page elsewhere (a lookalike domain, anything printed by mistake) is never offered.
public enum SignInPage {
    public static let anthropic = ["claude.ai", "claude.com", "anthropic.com"]
    public static let openAI = ["openai.com", "chatgpt.com"]

    /// Whether `url` is an HTTPS page on one of `domains` or a subdomain of one (`evilclaude.ai` isn't `claude.ai`).
    public static func belongs(_ url: URL, to domains: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What the UI shows while a sign-in runs.
public enum SignInStep: Sendable, Equatable {
    /// Open this page in the user's browser (Agneta opens it; the UI offers to open it again).
    case openBrowser(URL)
    /// The provider's own program already opened this page; the UI only offers to open it again.
    case browserOpened(URL)
    /// Show this code and page; the user confirms the code there.
    case confirmCode(code: String, page: URL, expiresIn: Int)
    /// Ask the user to paste a code the provider's page showed them; answer through the sign-in's code source.
    case pasteCode(String)
    case waiting(String)
    case signedIn(String)
}

/// Where a sign-in gets a code the user pastes into Agneta (nil when they cancel).
public typealias SignInCodeSource = @Sendable () async -> String?

public enum SignInError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case timedOut
    case denied(String)
    case provider(String)

    public var description: String {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in took too long. Try again."
        case .denied(let why): "Sign-in was declined: \(why)"
        case .provider(let why): "The provider refused sign-in: \(why)"
        }
    }
}

public typealias SignInProgress = @Sendable (SignInStep) -> Void
