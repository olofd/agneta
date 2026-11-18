// The app's side of engines: where each comes from on this Mac (the bundle, the user's Claude Code and Codex,
// downloads), downloading and checking them, and each kind of provider's default. It builds the EngineCatalog that
// the runtime, the router and every window read. Each engine is described once, in `EngineSource.all`: adding one is
// an adapter in AgnetaKit, its row in ProviderEngines, and an entry there.
import AgnetaKit
import Foundation
import Observation

/// How one engine gets onto this Mac.
@MainActor struct EngineSource: Identifiable {
    /// The user's own program an engine runs through: Settings offers a choice when they have more than one.
    struct UserProgram {
        /// Its settings key (`cli.<key>`).
        let key: String
        let title: String
        let missing: String
        let locate: @Sendable () -> [InstalledCLI]
    }

    /// Why an engine isn't ready.
    enum Missing: Error {
        /// What it downloads isn't here (or is downloading, or failed): its download says which.
        case download
        /// It can't run here, and why, in words the user can act on.
        case unavailable(String)
    }

    let id: String
    let name: String
    var program: UserProgram?
    /// What it downloads before it can run, if anything.
    var download: (EngineLibrary) -> EngineLibrary.Download? = { _ in nil }
    /// The engine once its pieces are here, or what's missing.
    var make: (EngineLibrary) -> Result<any EngineAdapter, Missing>
    /// Where it comes from, for Settings → Engines.
    var origin: (EngineLibrary) -> String

    /// Every engine, in the order Settings shows them.
    static let all: [EngineSource] = [
        EngineSource(id: "goose", name: "Goose", make: { .success(GooseAdapter(executable: $0.bundled("goose-acp"))) },
                     origin: { "Built in · \($0.lockedVersion("goose"))" }),
        EngineSource(id: "opencode", name: "OpenCode",
                     download: { $0.download(lock: "opencode", name: "opencode", executable: "opencode", title: "OpenCode") },
                     make: { library in
                         guard let program = library.verified("opencode") else { return .failure(.download) }
                         return .success(OpenCodeAdapter(executable: program))
                     },
                     origin: { "OpenCode \($0.lockedVersion("opencode")) · \($0.downloadOrigin("opencode"))" }),
        EngineSource(id: "claude-code", name: "Claude Code",
                     program: UserProgram(key: "claude", title: "Claude Code install", missing: "Install the Claude app or Claude Code to use it.",
                                          locate: { CLILocator.claudeCode() }),
                     download: { $0.download(lock: "runtimes", name: "claude-agent-acp", executable: "claude-agent-acp", title: "Claude Code's adapter") },
                     make: { library in
                         guard let cli = library.program("claude") else { return .failure(.unavailable("Install the Claude app or Claude Code")) }
                         return library.verified("claude-code").map { .success(ClaudeCodeAdapter(executable: $0, cli: cli)) } ?? .failure(.download)
                     },
                     origin: { "Your Claude Code, through claude-agent-acp \($0.lockedVersion("runtimes", entry: "claude-agent-acp"))" }),
        EngineSource(id: "codex", name: "Codex",
                     program: UserProgram(key: "codex", title: "Codex install", missing: "Install Codex to use it.", locate: { CLILocator.codex() }),
                     // A development build bundles Node and codex-acp; a release downloads them (`codex-runtime.lock`).
                     download: { $0.codexBundled ? nil : $0.download(lock: "codex-runtime", name: "codex-runtime", executable: "node", title: "Codex's runtime") },
                     make: { library in
                         guard let cli = library.program("codex") else { return .failure(.unavailable("Install Codex \(CLILocator.codexMinimum) or later")) }
                         guard let (node, script) = library.codexRuntime else { return .failure(.download) }
                         return .success(CodexAdapter(node: node, script: script, cli: cli))
                     },
                     origin: { "Your Codex, through codex-acp on Node.js · \($0.codexBundled ? "built in" : $0.downloadOrigin("codex"))" }),
    ]
}

/// What an engine needs, downloading or failed: the panel and Settings show it with its progress.
struct EngineDownload: Equatable {
    var engine: String
    var title: String
    var received: Int64 = 0
    var total: Int64?
    var problem: String?
    var fraction: Double? { total.map { $0 > 0 ? min(Double(received) / Double($0), 1) : 0 } }
    var amount: String {
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        return total.map { "\(done) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? done
    }
}

/// Where the app's own pieces are: the programs it bundles, its resources, and the locks pinning what it downloads.
/// The app's bundle in use; a folder of a test's making in tests.
struct Bundled: Sendable {
    let programs: URL
    let resources: URL

    static var app: Bundled {
        Bundled(programs: Bundle.main.bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory),
                resources: Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory))
    }

    /// A lock this build carries (`opencode.lock`), if it does.
    func lock(_ name: String) -> URL? {
        let url = resources.appending(path: "\(name).lock")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

@MainActor @Observable
final class EngineLibrary {
    /// What an engine downloads, pinned by a lock the app carries, installed under Runtimes/.
    struct Download {
        let installer: RuntimeInstaller
        let name: String, executable: String, title: String
        var asset: RuntimeInstaller.Asset? { try? installer.asset(name) }
    }

    let sources = EngineSource.all
    /// The engines this Agneta has and each provider's default: one snapshot, which the router, the supervisor and
    /// every window read (EngineCatalog). Rebuilt by `refresh` whenever any of it changes.
    private(set) var catalog = EngineCatalog()
    /// What engines are downloading, or failed to, by engine.
    private(set) var downloads: [String: EngineDownload] = [:]
    /// The user's own installs of each program engines run through (`UserProgram.key`), newest first. Looked up at
    /// launch and when Settings opens (each install's `--version` runs), never while drawing.
    private(set) var installs: [String: [InstalledCLI]] = [:]

    private let runtimes: URL
    private let bundled: Bundled
    private let log: OperationalLog
    /// Where choices are saved (the runtime's database), once it's open.
    private var database: AgnetaDatabase?
    /// The kinds of provider connected: a default engine of theirs that isn't here downloads.
    var kindsInUse: @MainActor () -> Set<AccountKind> = { [] }
    /// The default engine the user chose per kind of provider (Settings → Engines).
    private var defaults = ProviderEngines()
    /// The install chosen per program, by path.
    private var chosenPrograms: [String: String] = [:]
    /// Downloaded programs, as checked against their pins (nil: not installed, or no longer what the pin says).
    private var checked: [String: URL?] = [:]
    /// Failed downloads the user put away: not started again by themselves until a task asks for one, it's chosen as
    /// a default, or Try Again.
    private var putAway: Set<String> = []
    /// When the catalog last followed a download's progress (twice a second at most).
    private var progressShown: [String: Date] = [:]
    /// Catalogs on their way to the runtime, newest kept, delivered in order.
    private var sink: AsyncStream<EngineCatalog>.Continuation?
    /// The showcase's engines: every one, as if installed. Nil in use.
    private var sample: [any EngineAdapter]?

    init(runtimes: URL, log: OperationalLog, bundled: Bundled = .app) {
        self.runtimes = runtimes
        self.bundled = bundled
        self.log = log
    }

    // MARK: Starting

    /// Serves a runtime: reads the saved choices, finds the user's installs, checks the downloads, and from then on
    /// hands it every catalog, in order.
    func start(_ runtime: AgnetaRuntime) async {
        database = runtime.database
        for kind in AccountKind.allCases {
            if let engine = try? runtime.database.setting(ProviderEngines.settingKey(kind)) { defaults.selected[kind] = engine }
        }
        for source in sources {
            if let key = source.program?.key, let path = try? runtime.database.setting("cli.\(key)") { chosenPrograms[key] = path }
        }
        // Both before the first catalog (until then nothing is known to be here, and a download not yet checked would
        // look missing and start again), and at once: finding the user's installs runs their `--version`, checking the
        // downloads hashes them.
        async let found = lookUpInstalls()
        async let checked = checkDownloads()
        (installs, self.checked) = await (found, checked)
        let (catalogs, sink) = AsyncStream<EngineCatalog>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.sink?.finish()
        self.sink = sink
        _Concurrency.Task { for await catalog in catalogs { await runtime.setCatalog(catalog) } }
        refresh()
    }

    /// Reset: forgets everything; `start` begins again.
    func reset() {
        sink?.finish()
        sink = nil
        database = nil
        downloads = [:]
        checked = [:]
        putAway = []
        defaults = ProviderEngines()
        chosenPrograms = [:]
    }

    /// Checks every downloaded engine against its pin, off the main thread and all at once: hashing Node's runtime
    /// takes most of a second.
    private func checkDownloads() async -> [String: URL?] {
        let downloads = sources.compactMap { source in source.download(self).map { (source.id, $0) } }
        return await withTaskGroup(of: (String, URL?).self) { group in
            for (id, download) in downloads {
                group.addTask(priority: .userInitiated) { (id, download.installer.verified(download.name, executable: download.executable)) }
            }
            var checked: [String: URL?] = [:]
            for await (id, program) in group { checked[id] = .some(program) }
            return checked
        }
    }

    // MARK: The catalog

    /// Builds the catalog from what's here and hands it on. A provider in use whose default engine isn't here yet
    /// starts downloading it (not after a failed download: Try Again does that).
    func refresh() {
        catalog = makeCatalog()
        sink?.yield(catalog)
        for kind in kindsInUse() {
            if let engine = catalog.defaultEngine(for: kind), case .downloadable? = catalog.entries[engine]?.state, !putAway.contains(engine) {
                download(engine, reason: "default")
            }
        }
    }

    private func makeCatalog() -> EngineCatalog {
        if let sample { return EngineCatalog(ready: sample, defaults: defaults) }
        let entries = sources.compactMap { source -> EngineCatalog.Entry? in
            switch source.make(self) {
            case .success(let adapter):
                return EngineCatalog.Entry(ready: adapter)
            case .failure(.unavailable(let reason)):
                return EngineCatalog.Entry(id: source.id, name: source.name, state: .unavailable(reason))
            case .failure(.download):
                // Not pinned in this build: not an engine this build has.
                return downloadState(source).map { EngineCatalog.Entry(id: source.id, name: source.name, state: $0) }
            }
        }
        return EngineCatalog(entries, defaults: defaults)
    }

    /// A downloaded engine that isn't here: downloading, failed, or waiting until it's needed.
    private func downloadState(_ source: EngineSource) -> EngineCatalog.State? {
        if let download = downloads[source.id] {
            if let problem = download.problem { return .failed(problem) }
            return .downloading(received: download.received, total: download.total)
        }
        return source.download(self)?.asset.map { .downloadable(size: $0.size.map(Int64.init)) }
    }

    // MARK: What the windows ask

    /// Every engine in the catalog, in Settings' order.
    var all: [EngineCatalog.Entry] { sources.compactMap { catalog.entries[$0.id] } }

    /// The engines a kind of provider can run on here (now or after a download), most preferred first.
    func engines(for kind: AccountKind) -> [EngineCatalog.Entry] {
        ProviderEngines.supported(by: kind).compactMap { id in catalog.usable(id) ? catalog.entries[id] : nil }
    }

    /// The engine a kind of provider's tasks run on by default now; nil when none can run here (a ChatGPT plan without
    /// Codex). While the chosen default's download has failed, another that's ready.
    func engine(for kind: AccountKind) -> String? { catalog.defaultEngine(for: kind) }

    /// The default the user chose for a kind of provider (Settings → Engines' picker), else the one in use.
    func chosenEngine(for kind: AccountKind) -> String? {
        defaults.selected[kind].flatMap { ProviderEngines.supported(by: kind).contains($0) && catalog.usable($0) ? $0 : nil } ?? engine(for: kind)
    }

    /// An engine's name ("Codex").
    func name(_ engine: String?) -> String {
        guard let engine else { return "no engine" }
        return catalog.entries[engine]?.name ?? sources.first { $0.id == engine }?.name ?? engine
    }

    /// An engine's label in a provider's default picker: its name, marked when it's the one recommended for that
    /// provider, and with what it downloads first.
    func choice(_ engine: EngineCatalog.Entry, for kind: AccountKind) -> String {
        let notes = [ProviderEngines.supported(by: kind).first == engine.id ? "recommended" : nil, downloadNote(for: engine.id)].compactMap { $0 }
        return notes.isEmpty ? engine.name : "\(engine.name) (\(notes.joined(separator: ", ")))"
    }

    /// What using this engine would download first, e.g. "downloads 108 MB"; nil when it's here already.
    func downloadNote(for engine: String) -> String? {
        guard case .downloadable(let size)? = catalog.entries[engine]?.state else { return nil }
        return size.map { "downloads \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "downloads first"
    }

    /// Every engine ticked is "all", which includes engines Agneta adds later; otherwise only those ticked.
    func allowance(_ engines: Set<String>) -> EngineAllowance {
        engines.isSuperset(of: catalog.entries.keys) ? .all : .only(engines)
    }

    /// The engine ids an allowance stands for, for checkboxes.
    func ids(_ allowance: EngineAllowance) -> Set<String> {
        switch allowance {
        case .all: Set(catalog.entries.keys)
        case .only(let some): some
        }
    }

    /// Why a provider can't run anything with these engines now, or nil when it can: none of the engines it supports is
    /// ticked, or none of those is on this Mac (with what to install). Allowing it anyway is fine: it runs once it can.
    func cantRun(_ account: AccountRecord, engines: Set<String>) -> String? {
        guard Access.engines(for: account.kind, allowed: allowance(engines), catalog: catalog).isEmpty else { return nil }
        let ticked = ProviderEngines.supported(by: account.kind).filter(engines.contains)
        if ticked.isEmpty { return "\(account.label) can't run on any engine ticked here" }
        if ticked.count == 1, case .unavailable(let reason)? = catalog.entries[ticked[0]]?.state {
            return "Needs \(name(ticked[0])): \(reason.prefix(1).lowercased() + reason.dropFirst())"
        }
        return "Needs \(ticked.map(name).joined(separator: " or ")), which isn't on this Mac"
    }

    // MARK: Choosing

    /// Sets a kind of provider's default engine. New tasks that don't ask for an engine run on it; running ones keep
    /// theirs. One that isn't here yet starts downloading, and tasks hear it's downloading until it's done.
    func select(_ engine: String, for kind: AccountKind) {
        guard ProviderEngines.supported(by: kind).contains(engine), catalog.usable(engine) else { return }
        defaults.selected[kind] = engine
        try? database?.set(engine, for: ProviderEngines.settingKey(kind))
        log.log("engine-selected", ["provider": .string(kind.rawValue), "engine": .string(engine)])
        if case .failed? = catalog.entries[engine]?.state { download(engine, reason: "selected") }
        refresh()
    }

    /// The install of a program engines run through: the one chosen in Settings, else the newest; only ones new
    /// enough for Agneta.
    func program(_ key: String) -> InstalledCLI? {
        let usable = (installs[key] ?? []).filter(\.supported)
        return usable.first { $0.id == chosenPrograms[key] } ?? usable.first
    }

    /// New engines use this install from now on; running ones keep theirs.
    func choose(_ key: String, install: InstalledCLI) {
        chosenPrograms[key] = install.id
        try? database?.set(install.id, for: "cli.\(key)")
        log.log("cli-chosen", ["cli": .string(key), "version": install.version.map(JSONValue.string) ?? .null, "source": .string(install.source)])
        refresh()
    }

    /// Looks for the user's installs again (Settings opening): one installed or removed meanwhile counts.
    func refreshInstalls() {
        _Concurrency.Task {
            let found = await lookUpInstalls()
            guard found != installs else { return }
            installs = found
            refresh()
        }
    }

    /// Off the main thread and the task pool: each install's `--version` may take up to 5 s.
    private func lookUpInstalls() async -> [String: [InstalledCLI]] {
        let programs = sources.compactMap(\.program).map { ($0.key, $0.locate) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Dictionary(uniqueKeysWithValues: programs.map { ($0.0, $0.1()) }))
            }
        }
    }

    // MARK: Downloading

    /// Downloads, checks and installs what an engine needs in the background; the catalog follows each step, so apps
    /// and windows see it downloading, then ready (or failed). Downloads asked for meanwhile share this one.
    func download(_ engine: String, reason: String) {
        guard let download = sources.first(where: { $0.id == engine })?.download(self), let asset = download.asset else { return }
        if reason != "default" { putAway.remove(engine) }
        // One already going is joined (RuntimeInstaller shares it); one that failed starts again.
        guard downloads[engine].map({ $0.problem != nil }) ?? true else { return }
        downloads[engine] = EngineDownload(engine: engine, title: download.title, total: asset.size.map(Int64.init))
        log.log("engine-download", ["engine": .string(engine), "version": .string(asset.version), "reason": .string(reason)])
        refresh()
        let started = Date()
        _Concurrency.Task {
            do {
                let program = try await download.installer.install(download.name, executable: download.executable, received: { received, total in
                    _Concurrency.Task { @MainActor [weak self] in self?.progressed(engine, received: received, total: total) }
                })
                log.log("engine-downloaded", ["engine": .string(engine), "seconds": .int(Int64(Date().timeIntervalSince(started)))])
                downloads[engine] = nil
                checked[engine] = .some(program) // just checked by the install
            } catch {
                log.error("engine-download-failed", ["engine": .string(engine), "reason": .string("\(error)")])
                downloads[engine]?.problem = "\(download.title) couldn't be downloaded: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    /// Installs what an engine downloads now, and waits for it: a Claude plan's sign-in needs Claude Code's adapter
    /// before it can finish. Shares a download already going.
    func install(_ engine: String, progress: SignInProgress? = nil) async throws -> URL {
        guard let download = sources.first(where: { $0.id == engine })?.download(self) else {
            throw SignInError.provider("\(name(engine)) isn't pinned in this build")
        }
        let program = try await download.installer.install(download.name, executable: download.executable, progress: progress)
        checked[engine] = .some(program)
        refresh()
        return program
    }

    /// Puts a failed download away (its card's close button); the engine downloads again when it's next needed.
    func putAway(_ engine: String) {
        guard downloads[engine]?.problem != nil else { return }
        putAway.insert(engine)
        downloads[engine] = nil
        refresh()
    }

    /// Bytes arriving: the panel and Settings follow in steps of half a percent, apps (through the catalog) twice a
    /// second at most.
    private func progressed(_ engine: String, received: Int64, total: Int64?) {
        guard var state = downloads[engine], state.problem == nil else { return }
        let step = max((total ?? state.total ?? 0) / 200, 256 * 1024)
        guard received - state.received >= step || received == (total ?? -1) else { return }
        state.received = received
        if let total { state.total = total }
        downloads[engine] = state
        guard Date().timeIntervalSince(progressShown[engine] ?? .distantPast) > 0.5 else { return }
        progressShown[engine] = Date()
        refresh()
    }

    // MARK: Where things are

    func bundled(_ program: String) -> URL { bundled.programs.appending(path: program) }

    /// A download pinned by a lock the app carries, if this build carries it.
    func download(lock: String, name: String, executable: String, title: String) -> Download? {
        bundled.lock(lock).map {
            Download(installer: RuntimeInstaller(lockFile: $0, runtimes: runtimes), name: name, executable: executable, title: title)
        }
    }

    /// A downloaded engine's program, once it's installed and still what its pin says: checked at launch and by each
    /// install, never trusted from the file being there.
    func verified(_ engine: String) -> URL? { checked[engine] ?? nil }

    /// Node and codex-acp inside the bundle (a development build).
    var codexBundled: Bool { FileManager.default.isExecutableFile(atPath: bundled("node").path(percentEncoded: false)) }
    /// Node and codex-acp: bundled, or downloaded and checked.
    var codexRuntime: (node: URL, script: URL)? {
        if codexBundled { return (bundled("node"), bundled.resources.appending(path: "codex-acp/dist/index.js")) }
        guard let node = verified("codex") else { return nil }
        return (node, node.deletingLastPathComponent().appending(path: "codex-acp/dist/index.js"))
    }

    /// A version from a lock the app carries (`goose.lock`: its `version`; `runtimes.lock`: an entry's).
    func lockedVersion(_ lock: String, entry: String? = nil) -> String {
        guard let url = bundled.lock(lock), let data = try? Data(contentsOf: url),
              let value = try? JSONCoding.decode(data) else { return "–" }
        return (entry.map { value[$0]?["version"] } ?? value["version"])??.stringValue ?? "–"
    }

    /// "downloaded", or what it downloads when first used.
    func downloadOrigin(_ engine: String) -> String {
        switch catalog.entries[engine]?.state {
        case .ready?: "downloaded"
        case .downloadable?: "\(downloadNote(for: engine) ?? "downloads") when first used"
        default: "downloads when first used"
        }
    }

    // MARK: Design review

    /// Every engine, as if installed, with a download going and one failed, for the showcase.
    func useSample() {
        let none = URL(filePath: "/usr/bin/false")
        sample = [GooseAdapter(executable: none), OpenCodeAdapter(executable: none),
                  ClaudeCodeAdapter(executable: none, cli: InstalledCLI(path: none, version: "2.1.0", source: "path")),
                  CodexAdapter(node: none, script: none, cli: InstalledCLI(path: none, version: "0.166.0", source: "path"))]
        downloads = ["opencode": EngineDownload(engine: "opencode", title: "OpenCode", received: 52_400_000, total: 113_407_057),
                     "codex": EngineDownload(engine: "codex", title: "Codex's runtime",
                                             problem: "Codex's runtime couldn't be downloaded: The Internet connection appears to be offline.")]
        catalog = makeCatalog()
    }
}
