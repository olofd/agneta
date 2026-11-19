// Developer access, in one place: what it widens and what it keeps out. It's the always-free path for demanding apps,
// whose agents Agneta must never make weaker than plain Claude Code (docs/APP_PROTOCOL.md): the engine's own tools run
// natively, as in a terminal, with the internet, the home folder readable, the user's own toolchains and loopback
// servers. Writes still stay in the session's folders and the app's own build caches: never the user's, where a planted
// entry would run later as the user, outside any sandbox (a `.pyc` in python's cache, a `build.rs` in cargo's
// registry). Credentials, other apps' data and Agneta's own data stay out. A session gets it only with a grant that
// allows it.
import Foundation

public enum DeveloperAccess {
    /// Never readable or writable under developer access, though inside the home folder: credentials, histories,
    /// browsers, mail and messages, and other apps' private storage. Missing paths cost nothing.
    public static func secrets(home: URL) -> [URL] {
        let files = [
            ".ssh", ".gnupg", ".aws", ".azure", ".config/gcloud", ".kube", ".docker/config.json", ".netrc", ".git-credentials",
            ".config/gh", ".config/hub", ".npmrc", ".yarnrc", ".pypirc", ".gem/credentials", ".cargo/credentials.toml",
            ".cargo/credentials", ".terraform.d/credentials.tfrc.json", ".vault-token", ".claude.json", ".claude", ".codex",
            ".zsh_history", ".bash_history", ".zsh_sessions", ".python_history", ".node_repl_history", ".lesshst",
            "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
            "Library/Containers", "Library/Group Containers", "Library/Accounts", "Library/Calendars",
            "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
            "Library/Application Support/Firefox", "Library/Application Support/Microsoft Edge", "Library/Application Support/Arc",
            "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC",
            "Library/Application Support/1Password", "Library/Application Support/Claude", "Library/Application Support/Code/User/globalStorage",
            "Library/LaunchAgents",
            // Other agents' and tools' sign-ins and histories.
            ".config/goose", ".local/share/goose", ".config/opencode", ".local/share/opencode", ".gemini", ".cursor",
            ".config/github-copilot", ".config/configstore", ".config/op", ".password-store", ".config/rclone", ".s3cfg",
            ".pgpass", ".my.cnf", ".m2/settings.xml", ".fly", ".config/heroku",
        ]
        return files.map { home.appending(path: $0) }
    }

    /// Every copy of Agneta's own data (each build's, in Application Support, Caches, Logs and Preferences, and every
    /// app's workspace beside it), as sandbox regular expressions: never reachable under developer access, apart from
    /// the session's own folders inside it.
    public static func agnetaData(home: URL) -> [String] {
        let library = NSRegularExpression.escapedPattern(for: home.realFileURL.appending(path: "Library").path(percentEncoded: false))
        return ["^\(library)/(Application Support|Caches|Preferences|HTTPStorages|WebKit)/com\\.objectivecoder\\.agneta",
                "^\(library)/Logs/Agneta"]
    }

    static func isAgnetaData(_ url: URL, home: URL) -> Bool {
        let path = url.realFileURL.path(percentEncoded: false)
        return agnetaData(home: home).contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }

    /// The app's own build caches, in `caches` (one folder per app, kept across its sessions so its builds stay warm):
    /// where cargo, pip, uv, npm, yarn, bun, go, gradle, deno and clang keep theirs, by the variables each reads (Agneta
    /// writes nothing there itself: the folder is the sessions'). The user's own toolchains (`~/.rustup`,
    /// `~/.cargo/bin`) stay read-only and are found on PATH; the user's `~/.cargo/config.toml` isn't read. Python's
    /// bytecode isn't moved here: it would mirror source paths that a later session of the app may have denied.
    public static func cacheEnvironment(caches: URL) -> [String: String] {
        let folders = ["CARGO_HOME": "cargo", "PIP_CACHE_DIR": "pip", "UV_CACHE_DIR": "uv", "npm_config_cache": "npm",
                       "YARN_CACHE_FOLDER": "yarn", "BUN_INSTALL_CACHE_DIR": "bun", "GOCACHE": "go/build", "GOMODCACHE": "go/mod",
                       "GRADLE_USER_HOME": "gradle", "DENO_DIR": "deno", "CLANG_MODULE_CACHE_PATH": "clang",
                       "XDG_CACHE_HOME": "xdg", "HOMEBREW_CACHE": "homebrew"]
        return folders.mapValues { caches.appending(path: $0, directoryHint: .isDirectory).path(percentEncoded: false) }
    }


    /// Where the user's own toolchains keep their programs, before the system's, as a terminal's PATH would have them.
    public static func path(home: URL) -> String {
        let user = [".cargo/bin", ".local/bin", ".volta/bin", ".bun/bin", ".deno/bin", ".pyenv/shims", ".rbenv/shims", ".nvm/current/bin",
                    ".nix-profile/bin", "go/bin"].map { home.appending(path: $0).path(percentEncoded: false) }
        let system = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] + SandboxProfile.xcodeTools + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return (user + system).filter { FileManager.default.fileExists(atPath: $0) }.joined(separator: ":")
    }

    /// What commands need to find the user's toolchains, and the app's own caches to build with.
    public static func environment(home: URL, caches: URL) -> [String: String] {
        var environment = cacheEnvironment(caches: caches)
        environment["PATH"] = path(home: home)
        if let sdk = SandboxProfile.sdkRoot { environment["SDKROOT"] = sdk }
        let rustup = home.appending(path: ".rustup")
        if FileManager.default.fileExists(atPath: rustup.path(percentEncoded: false)) { environment["RUSTUP_HOME"] = rustup.path(percentEncoded: false) }
        return environment
    }

    /// Widens a profile for developer access: the home folder readable, the app's caches writable, the secrets and
    /// Agneta's own data out, with the folders the process itself needs inside them allowed back (read-only where
    /// it only reads them), any TCP host, and loopback servers. The profile's own `denied` stays denied inside them.
    public static func widen(_ profile: inout SandboxProfile, home: URL, agnetaRoots: [URL], caches: URL) {
        let home = home.realFileURL
        let secrets = secrets(home: home)
        profile.readable.append(home)
        profile.writable.append(caches)
        let blocked = secrets + agnetaRoots.map(\.realFileURL)
        // What the process needs inside a blocked folder comes back: its own home and the session's folders
        // read-write, its programs and sign-in read-only.
        func isBlocked(_ url: URL) -> Bool { blocked.contains { url.realFileURL.isInside($0) } || isAgnetaData(url, home: home) }
        let needed = profile.writable.filter(isBlocked)
        let neededReads = (profile.readable + profile.readOnly).filter { url in url != home && isBlocked(url) && !needed.contains(url) }
        profile.outerDenied += blocked.filter { secret in !needed.contains { $0.realFileURL == secret } && !neededReads.contains { $0.realFileURL == secret } }
        profile.deniedPatterns += agnetaData(home: home)
        profile.outerExceptions += needed
        profile.readExceptions += neededReads
        profile.anyRemote = true
        profile.ownLoopbackServer = true
        profile.allLoopback = true
        profile.developer = true
    }
}
