// Windows for decisions: first run, sign-in, app approval, Settings, Quit.
// Dialog windows are Liquid Glass (NSGlassEffectView on macOS 26, a visual
// effect view before) hosting SwiftUI, so the model can open them from
// anywhere (a pairing request arrives while no Agneta window exists).
import AgnetaKit
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]

    /// A borderless-looking glass dialog, or a standard window for Settings.
    /// `onClose` runs when the window closes for any reason (its close button, Command-W, or code).
    private func show<Content: View>(_ key: String, title: String, size: NSSize, glass: Bool = true, resizable: Bool = false,
                                     onClose: (@MainActor () -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        // Only dialogs hide their title bar. A standard window (Settings, task details) keeps it, so on macOS 26 the
        // content scrolling under the title fades beneath it instead of running into the title's text.
        window.titlebarAppearsTransparent = glass
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = glass
        // Dialogs have a fixed size; Settings sizes itself.
        let host = NSHostingView(rootView: content().frame(width: glass ? size.width : nil, height: glass ? size.height : nil).environment(\.onDialogGlass, glass))
        if glass { host.sizingOptions = [] }
        if glass {
            window.titleVisibility = .hidden
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = GlassBackground.make(content: host, cornerRadius: 26, surface: .dialog)
        } else {
            window.contentView = host
        }
        window.center()
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.windows.removeValue(forKey: key)
                onClose?()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(_ key: String) { windows[key]?.close() }
    func window(_ key: String) -> NSWindow? { windows[key] }
    func register(_ key: String, _ window: NSWindow) { windows[key] = window }

    func showWelcome(_ model: AppModel) { show("welcome", title: "Welcome to Agneta", size: NSSize(width: 460, height: 520)) { WelcomeView(model: model) } }
    func closeWelcome() { close("welcome") }
    /// Closing the window cancels the sign-in it shows (one left running would hold its sign-in callback port).
    func showSignIn(_ model: AppModel, attempt: UUID) {
        closeWelcome()
        show("signin", title: "Sign In", size: NSSize(width: 420, height: 340), onClose: { model.signInWindowClosed(attempt) }) { SignInView(model: model) }
    }
    func closeSignIn() { close("signin") }
    /// Closing the window is Don't Allow for the request it shows; the next waiting request then appears.
    func showApproval(_ model: AppModel, request: UUID) {
        show("approval", title: "Allow an App", size: NSSize(width: 460, height: 600), onClose: { model.settleApproval(request, with: nil) }) { ApprovalView(model: model) }
        windows["approval"]?.level = .floating
    }
    func closeApproval() { close("approval") }
    func showSettings(_ model: AppModel, section: SettingsView.Pane = .accounts) {
        model.refreshInstalls()
        close("settings")
        show("settings", title: "Agneta Settings", size: NSSize(width: 780, height: 540), glass: false, resizable: true) { SettingsView(model: model, section: section) }
    }

    func showDetails(_ model: AppModel, task: String, title: String) {
        close("details-\(task)")
        show("details-\(task)", title: title, size: NSSize(width: 520, height: 600), glass: false, resizable: true) {
            TaskDetailsView(model: model, task: task, title: title)
        }
    }

    func quit(_ model: AppModel) {
        guard confirmStopping(model.tasks, verb: "quit", button: "Stop and Quit") else { return }
        // The app delegate stops everything (applicationShouldTerminate), as for every other way of quitting.
        NSApp.terminate(nil)
    }

    /// Check for Updates in a build that has no updater: says why, and how this kind of build gets newer.
    func explainNoUpdates(_ model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "This build doesn't update itself"
        alert.informativeText = model.isDevelopment
            ? "Agneta Dev is built from source. To get the latest, pull and run scripts/dev/build-app again. Releases from GitHub or Homebrew update themselves."
            : model.updates.unavailableReason
        alert.addButton(withTitle: "OK")
        if model.isDevelopment { alert.addButton(withTitle: "Open Releases") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: "https://github.com/olofd/agneta/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installs the update that waits for the running tasks, after asking to stop them. Sparkle then quits Agneta
    /// (which stops the engines) and opens the new version.
    func installUpdate(_ model: AppModel) {
        guard confirmStopping(model.tasks, verb: "install the update", button: "Stop and Install") else { return }
        model.updates.installNow()
    }

    /// Asks before stopping running tasks; true when there are none or the user agreed.
    private func confirmStopping(_ running: [AppModel.Task], verb: String, button: String) -> Bool {
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "Stop 1 task and \(verb)?" : "Stop \(running.count) tasks and \(verb)?"
        alert.informativeText = running.map { "• \($0.title) (\($0.app))" }.joined(separator: "\n")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: Shared dialog layout

/// The common shape of Agneta's dialogs: a hero, a title, a sentence, content, actions.
struct DialogLayout<Hero: View, Content: View, Actions: View>: View {
    var title: String
    var message: String?
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.top, 34)
            Text(title).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center).padding(.top, 16).padding(.horizontal, 28)
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 36).padding(.top, 7)
            }
            content.padding(.top, 20)
            Spacer(minLength: 16)
            actions.padding(.horizontal, 24).padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: First run

struct WelcomeView: View {
    var model: AppModel

    var body: some View {
        DialogLayout(title: "Bring your AI to your apps",
                     message: "Sign in with the account you already pay for. Agneta keeps it safe, and lets the apps you allow use it, with you in control.") {
            MarkTile(size: 72)
        } content: {
            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    ProviderButton(kind: .chatGPT, title: "Continue with ChatGPT", detail: "Your ChatGPT plan, through Codex") { model.startSignIn(.chatGPT) }
                    ProviderButton(kind: .claude, title: "Continue with Claude", detail: "Your Claude plan, through Claude Code") { model.startSignIn(.claude) }
                }
            }
            .padding(.horizontal, 30)
            Button("Use an API key instead") { WindowPresenter.shared.showSettings(model) }
                .buttonStyle(.link).font(.system(size: 12.5)).padding(.top, 14)
        } actions: {
            HStack(spacing: 6) {
                Image(nsImage: Mark.image(size: 13)).renderingMode(.template)
                Text("Agneta lives in the menu bar, beside the clock.")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A large provider choice: logo, name, one line; glass with hover.
struct ProviderButton: View {
    var kind: AccountKind
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ProviderIcon(kind: kind, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .offset(x: hovered ? 2 : 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0)))
        .frostedCard(cornerRadius: 18)
        .scaleEffect(hovered ? 1.01 : 1)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
    }
}

// MARK: Sign-in

struct SignInView: View {
    var model: AppModel
    @State private var code = ""

    var body: some View {
        if let signIn = model.signIn {
            DialogLayout(title: signIn.finished ? "You're signed in" : "Sign in to \(signIn.kind.provider)",
                         message: signIn.failed == nil ? signIn.text : nil) {
                ZStack(alignment: .bottomTrailing) {
                    ProviderIcon(kind: signIn.kind, size: 64)
                    if signIn.finished {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white, Palette.running)
                            .offset(x: 6, y: 6).transition(.scale.combined(with: .opacity))
                    }
                }
            } content: {
                VStack(spacing: 12) {
                    if let failed = signIn.failed {
                        Label(failed, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Palette.attention)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    } else if signIn.needsCode {
                        HStack(spacing: 8) {
                            TextField("Paste the code from Claude", text: $code)
                                .textFieldStyle(.plain).font(.system(size: 14))
                                .padding(.horizontal, 14).frame(height: 38)
                                .frostedCard(cornerRadius: 19)
                                .onSubmit(submit)
                            Button("Continue", action: submit).glassButton(prominent: true).tint(Palette.accent).controlSize(.large).disabled(code.isEmpty)
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 30)
                    } else if !signIn.finished {
                        ProgressView().controlSize(.small)
                    }
                }
            } actions: {
                HStack {
                    if let page = signIn.page, !signIn.finished, signIn.failed == nil {
                        Button("Open the Page Again") { NSWorkspace.shared.open(page) }.glassButton()
                    }
                    Spacer()
                    if signIn.finished || signIn.failed != nil {
                        Button("Done") { model.cancelSignIn() }.glassButton(prominent: true).tint(Palette.accent).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel") { model.cancelSignIn() }.glassButton().keyboardShortcut(.cancelAction)
                    }
                }
                .controlSize(.large)
            }
            .animation(.easeOut(duration: 0.2), value: signIn.finished)
        }
    }

    private func submit() {
        guard !code.isEmpty else { return }
        model.submitCode(code)
        code = ""
    }
}

// MARK: App approval

/// What the app asks to do, in plain words: its built-in tools and the folders they reach.
struct ApprovalScope: View {
    var app: String
    var tools: SessionPolicy.Tools
    var folders: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(toolsLine, systemImage: tools == .appOnly ? "puzzlepiece.extension" : tools == .read ? "doc.text.magnifyingglass" : "hammer")
            ForEach(folders, id: \.self) { folder in
                Label(Self.display(folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var toolsLine: String {
        let reach = folders.isEmpty ? "its own workspace in Agneta" : (folders.count == 1 ? "this folder" : "these folders") + " and its own workspace"
        return switch tools {
        case .appOnly: "Only \(app)'s own tools, in \(reach)"
        case .read: "Read files in \(reach)"
        case .workspace: "Read, change and run commands in \(reach), without network"
        }
    }

    static func display(_ folder: URL) -> String {
        func trimmed(_ path: String) -> String { path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path }
        let home = trimmed(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
        let path = trimmed(folder.path(percentEncoded: false))
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct ApprovalView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let approval = model.approval {
            DialogLayout(title: "Let \(approval.app) use your AI?",
                         message: "\(approval.app) can start AI tasks that count against your plan limits or API credit. You see and can stop every task, and can remove access at any time.") {
                HStack(spacing: 14) {
                    AppIcon(name: approval.app, identifier: approval.verified ? approval.identifier : nil, size: 64)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(.tertiary)
                    MarkTile(size: 64)
                }
            } content: {
                VStack(spacing: 12) {
                    VStack(spacing: 2) {
                        ForEach(approval.choices) { account in
                            let on = approval.allowed.contains(account.id)
                            Button {
                                if on { model.approval?.allowed.remove(account.id) } else { model.approval?.allowed.insert(account.id) }
                            } label: {
                                HStack(spacing: 11) {
                                    ProviderIcon(kind: account.kind, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(account.label).font(.system(size: 13, weight: .semibold))
                                        Text("\(account.kind.plan) · \(model.engineName(approval.engines[account.id] ?? account.engine, for: account))")
                                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                                        .foregroundStyle(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityAddTraits(on ? .isSelected : [])
                            // Which engine this app's tasks on the account run on, where there's a choice; the
                            // account's own is preselected.
                            if on, model.engines(for: account).count > 1 {
                                Picker("Runs on", selection: Binding(get: { approval.engines[account.id] ?? account.engine },
                                                                     set: { model.approval?.engines[account.id] = $0 })) {
                                    ForEach(model.engines(for: account), id: \.id) { engine in Text(model.engineChoice(engine, for: account)).tag(engine.id) }
                                }
                                .font(.system(size: 11.5)).controlSize(.small).fixedSize()
                                .padding(.leading, 49).padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(5)
                    .frostedCard(cornerRadius: 18)
                    .padding(.horizontal, 28)

                    ApprovalScope(app: approval.app, tools: approval.tools, folders: approval.folders)
                        .padding(.horizontal, 32)

                    if approval.verified, let identifier = approval.identifier {
                        Label("Verified app · \(identifier)", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.running)
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        VStack(spacing: 6) {
                            Label("Agneta can't verify this app", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                                .font(.system(size: 12, weight: .semibold))
                            Text("Allow it only if \(approval.app) shows this code:").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(approval.code.isEmpty ? "–" : "\(approval.code.prefix(3)) \(approval.code.suffix(3))")
                                .font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(2)
                                .accessibilityLabel("Code \(approval.code.map(String.init).joined(separator: " "))")
                        }
                    }
                }
            } actions: {
                HStack(spacing: 8) {
                    // The labels fill the width so the glass bezels do too.
                    Button { model.answerApproval(remember: nil) } label: { Text("Don't Allow").frame(maxWidth: .infinity) }
                        .glassButton().keyboardShortcut(.cancelAction)
                    // Once: for this connection only, nothing kept. Return chooses it, and only for a verified app.
                    Button { model.answerApproval(remember: false) } label: { Text("Allow Once").frame(maxWidth: .infinity) }
                        .glassButton()
                        .defaultAction(when: approval.verified)
                        .disabled(approval.allowed.isEmpty)
                    Button { model.answerApproval(remember: true) } label: { Text("Always Allow").frame(maxWidth: .infinity) }
                        .glassButton(prominent: true).tint(Palette.accent)
                        .disabled(approval.allowed.isEmpty)
                }
                .controlSize(.large)
            }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    /// What the app bundles or downloads, as THIRD_PARTY.md lists it; the texts are in Resources/Licenses.
    static let licenses: [(String, String)] = [
        ("Goose", "Apache 2.0"), ("OpenCode", "MIT"), ("codex-acp", "Apache 2.0"), ("Node.js", "MIT"), ("GRDB.swift", "MIT"), ("Sparkle", "MIT"),
        ("claude-agent-acp", "Apache 2.0"), ("codex-acp's npm packages", "MIT, ISC, BSD-3-Clause, Apache 2.0"),
    ]

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", accounts = "Accounts", apps = "Apps", activity = "Activity", privacy = "Privacy", advanced = "Advanced", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .accounts: "person.crop.circle"
            case .apps: "square.grid.2x2"
            case .activity: "clock"
            case .privacy: "hand.raised"
            case .advanced: "wrench.and.screwdriver"
            case .about: "info.circle"
            }
        }
    }

    var model: AppModel
    @State var section: Pane
    @State private var keyKind: AccountKind = .anthropicKey
    @State private var key = ""
    @State private var keyError: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { section }, set: { if let value = $0 { section = value } })) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190)
        } detail: {
            Form {
                switch section {
                case .general: general
                case .accounts: accountsPane
                case .apps: appsPane
                case .activity: activityPane
                case .privacy: privacyPane
                case .advanced: advancedPane
                case .about: about
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Open Agneta at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { openAtLogin = !on }
                }
        }
        Section {
            if model.updates.enabled {
                Toggle("Check for updates automatically", isOn: Binding(get: { model.updates.checksAutomatically }, set: { model.updates.checksAutomatically = $0 }))
                Toggle("Download and install automatically", isOn: Binding(get: { model.updates.downloadsAutomatically }, set: { model.updates.downloadsAutomatically = $0 }))
                    .disabled(!model.updates.checksAutomatically)
                Button("Check Now") { model.updates.check() }.disabled(!model.updates.canCheck)
            } else {
                LabeledContent("Updates") { Text(model.updates.unavailableReason).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Updates")
        } footer: {
            if model.updates.enabled { Text("Updates come from Agneta's GitHub releases and install only when no task is running.") }
        }
        Section {
            LabeledContent("Apps connect at") { Text(verbatim: "ws://127.0.0.1:\(model.port)/acp").textSelection(.enabled).foregroundStyle(.secondary) }
        } footer: {
            Text("Only apps on this Mac can connect, and each one asks you first.")
        }
    }

    @ViewBuilder private var accountsPane: some View {
        Section {
            ForEach(model.accounts) { account in
                HStack(spacing: 12) {
                    ProviderIcon(kind: account.kind, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label).font(.system(size: 13, weight: .semibold))
                        Text([account.kind.plan, account.email].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if let download = model.engineDownload, download.account == account.id {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(download.text) }.font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if let problem = model.engineDownloadProblem, problem.account == account.id {
                            Text(problem.text).font(.system(size: 12)).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if account.paused { StatusPill(text: "Paused", color: .secondary) }
                    // The engine, in plain sight: a picker when the account has a choice, else just its name.
                    if model.engines(for: account).count > 1 {
                        Picker("Engine", selection: Binding(get: { account.engine }, set: { model.setEngine(account, $0) })) {
                            ForEach(model.engines(for: account), id: \.id) { engine in
                                let notes = [engine.id == model.defaultEngine(for: account.kind) ? "recommended" : nil, model.downloadNote(for: engine.id)].compactMap { $0 }
                                Text(notes.isEmpty ? engine.displayName : "\(engine.displayName) (\(notes.joined(separator: ", ")))").tag(engine.id)
                            }
                        }
                        .labelsHidden().fixedSize().disabled(model.engineDownload != nil)
                        .help("The engine this account's tasks run on")
                    } else {
                        Text(model.engineName(of: account)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Rename…") { askRename(account) }
                        Button(account.paused ? "Resume" : "Pause") { model.setPaused(account, !account.paused) }
                        Button("Default Model…") { askDefaultModel(account) }
                        Divider()
                        Button("Sign Out…", role: .destructive) { confirmSignOut(account) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(account.label)")
                }
                .padding(.vertical, 3)
            }
            if model.accounts.isEmpty { Text("No accounts yet.").foregroundStyle(.secondary) }
        } footer: {
            HStack {
                Spacer()
                Menu("Add Account") {
                    Button("ChatGPT…") { model.startSignIn(.chatGPT) }
                    Button("Claude…") { model.startSignIn(.claude) }
                }
                .fixedSize()
            }
        }
        Section {
            Picker("Provider", selection: $keyKind) {
                Text("Anthropic (Claude)").tag(AccountKind.anthropicKey)
                Text("OpenAI").tag(AccountKind.openAIKey)
            }

            HStack {
                SecureField("API key", text: $key)
                Button("Add") {
                    let kind = keyKind, value = key
                    key = ""
                    Task { do { try await model.addAPIKey(kind, key: value); keyError = nil } catch { keyError = "Couldn't store the key in the Keychain." } }
                }
                .disabled(key.count < 20)
            }
            if let keyError { Text(keyError).foregroundStyle(Palette.attention) }
        } header: {
            Text("API key")
        } footer: {
            Text("Pay as you go on your provider account. Keys stay in your Keychain and reach Agneta's engine only while a task runs.")
        }
    }

    private func askRename(_ account: AccountRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename \(account.label)"
        alert.informativeText = "Apps show this name when you choose an account."
        let field = NSTextField(string: account.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.rename(account, to: field.stringValue) }
    }

    private func askDefaultModel(_ account: AccountRecord) {
        let alert = NSAlert()
        alert.messageText = "Default model for \(account.label)"
        alert.informativeText = "New tasks start with this model unless the app picks one. Leave it empty for \(account.kind.provider)'s default."
        let field = NSTextField(string: account.model ?? "")
        field.placeholderString = "\(account.kind.provider)'s default"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.setDefaultModel(account, field.stringValue) }
    }

    private func confirmSignOut(_ account: AccountRecord) {
        let alert = NSAlert()
        alert.messageText = "Sign out of \(account.label)?"
        alert.informativeText = "Running tasks on this account stop, and Agneta forgets its sign-in on this Mac. Your \(account.kind.provider) account itself isn't changed."
        // Cancel is the Return default; the destructive choice takes a click.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign Out")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { model.signOut(account) }
    }

    @ViewBuilder private var appsPane: some View {
        Section {
            if model.grants.isEmpty {
                Text("No apps yet. When an app asks to use Agneta, you decide here what it may use.").foregroundStyle(.secondary)
            }
            ForEach(model.grants.values.sorted { $0.created < $1.created }, id: \.id) { grant in
                HStack(spacing: 12) {
                    AppIcon(name: grant.app, identifier: grant.verified ? grant.identifier : nil, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(grant.app).font(.system(size: 13, weight: .semibold))
                        Text((grant.verified ? "Verified · " : "Not verified · ") + grant.accounts.map { model.label(ofAccount: $0) }.joined(separator: ", "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove Access") { model.removeAccess(grant.id) }
                }
                .padding(.vertical, 3)
                // The engine this app's tasks run on, per account it may use.
                ForEach(model.accounts.filter { grant.accounts.contains($0.id) }) { account in
                    if model.engines(for: account).count > 1 {
                        Picker("With \(account.label)", selection: Binding(get: { model.engine(of: account, for: grant) },
                                                                                    set: { model.setEngine($0, for: account, in: grant) })) {
                            ForEach(model.engines(for: account), id: \.id) { engine in Text(model.engineChoice(engine, for: account)).tag(engine.id) }
                        }
                        .padding(.leading, 44)
                    } else {
                        LabeledContent("With \(account.label)") { Text(model.engineName(of: account)).foregroundStyle(.secondary) }
                            .padding(.leading, 44)
                    }
                }
            }
        } header: {
            Text("Apps that can use Agneta")
        }
    }

    @ViewBuilder private var activityPane: some View {
        Section {
            if model.tasks.isEmpty { Text("Nothing is running.").foregroundStyle(.secondary) }
            ForEach(model.tasks) { task in
                HStack(spacing: 12) {
                    AppIcon(name: task.app, identifier: task.appIdentifier, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).font(.system(size: 13, weight: .semibold))
                        Text("\(task.app) · \(model.label(ofAccount: task.account)) · \(task.started.elapsed)" + (task.cost.map { String(format: " · about $%.2f at API prices", $0) } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if task.running { LiveDot() }
                    Button("Details") { WindowPresenter.shared.showDetails(model, task: task.id, title: task.title) }
                    Button("Stop") { model.stop(task) }.disabled(task.stopping)
                }
                .padding(.vertical, 3)
            }
        } header: {
            Text("Running now")
        }
        Section {
            if model.history.isEmpty {
                Text(model.historyDays == 0 ? "Agneta doesn't keep task history." : "Finished tasks appear here for \(Self.retentionText(model.historyDays)).")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history) { record in
                HistoryRow(record: record, account: model.label(ofAccount: record.account)) {
                    WindowPresenter.shared.showDetails(model, task: record.id, title: record.title)
                }
            }
        } header: {
            Text("Earlier")
        } footer: {
            if model.recovered.engines + model.recovered.tasks > 0 {
                Text(model.recovered.tasks == 1 ? "1 task was running when Agneta last quit unexpectedly; it was stopped." :
                        "\(model.recovered.tasks) tasks were running when Agneta last quit unexpectedly; they were stopped.")
            }
        }
    }

    static func retentionText(_ days: Int) -> String {
        switch days {
        case 7: "a week"
        case 1: "a day"
        default: "\(days) days"
        }
    }

    @ViewBuilder private var privacyPane: some View {
        Section {
            LabeledContent("Accounts and app access", value: "On this Mac only")
            LabeledContent("Sign-ins and API keys", value: "Your Keychain and private folders")
            LabeledContent("Task history", value: "App, title, times and usage")
            LabeledContent("Conversations", value: "Kept by the engine to resume tasks")
        } header: {
            Text("What Agneta keeps")
        } footer: {
            Text("Agneta sends nothing to its makers. What apps ask goes only to the AI account you chose, under that provider's terms.")
        }
        Section {
            Picker("Keep task history", selection: Binding(get: { model.historyDays }, set: { model.setHistoryDays($0) })) {
                Text("A week").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Don't keep").tag(0)
            }
            HStack {
                Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataFolder]) }
                Spacer()
                Button("Clear History…") { confirmClearHistory() }.disabled(model.history.isEmpty)
            }
        } header: {
            Text("History")
        }
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reset Agneta").font(.system(size: 13, weight: .semibold))
                    Text("Signs out of every account, removes app access, history, logs and downloads, and starts over.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset Agneta…", role: .destructive) { confirmReset() }.disabled(model.resetting)
            }
            if let problem = model.resetProblem {
                HStack {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                    Spacer()
                    Button("Try Again") { model.retryReset() }
                }
            }
        }
    }

    @ViewBuilder private var advancedPane: some View {
        Section {
            Toggle("Allow diagnostic tools", isOn: Binding(get: { model.diagnosticsToken != nil }, set: { on in
                if on { Task { await model.allowDiagnostics() } } else { model.stopDiagnostics() }
            }))
            if let token = model.diagnosticsToken {
                LabeledContent("Address") { Text(verbatim: model.diagnosticsURL).textSelection(.enabled).foregroundStyle(.secondary) }
                LabeledContent("Token") { Text(verbatim: token).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                HStack {
                    Button("Copy Setup for Claude Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude mcp add --transport http agneta-diagnostics \(model.diagnosticsURL) --header \"Authorization: Bearer \(token)\"", forType: .string)
                    }
                    Spacer()
                    Button("New Token") { Task { await model.allowDiagnostics() } }
                }
            }
            if let problem = model.diagnosticsProblem { Text(problem).foregroundStyle(Palette.attention) }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Tools you give this token, such as Claude Code, can read every task's trace on this Mac: prompts, tool calls and results included. Turn it off or make a new token to stop them.")
        }
        Section {
            cliPicker("Claude Code", name: "claude", installs: model.claudeCodeInstalls, missing: "Install the Claude app or Claude Code to use it.")
            cliPicker("Codex", name: "codex", installs: model.codexInstalls, missing: "Install Codex to use it.")
        } header: {
            Text("Your installed tools")
        } footer: {
            Text("Agneta uses your own Claude Code and Codex. When you have more than one, choose which.")
        }
        Section {
            LabeledContent("Running at once", value: "8 tasks, 3 per account")
            LabeledContent("Waiting", value: "Up to 32 tasks")
        } header: {
            Text("Limits")
        } footer: {
            Text("More tasks wait their turn; one busy account never holds up another.")
        }
    }

    @ViewBuilder private func cliPicker(_ title: String, name: String, installs: [InstalledCLI], missing: String) -> some View {
        if installs.isEmpty {
            LabeledContent(title) { Text(missing).foregroundStyle(.secondary) }
        } else if installs.count == 1 {
            LabeledContent(title, value: installs[0].label)
        } else {
            Picker(title, selection: Binding(get: { model.chosen(name, from: installs)?.id ?? "" },
                                             set: { id in if let install = installs.first(where: { $0.id == id }) { model.choose(name, install: install) } })) {
                ForEach(installs) { install in Text(install.label).tag(install.id).selectionDisabled(!install.supported) }
            }
        }
    }

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear task history?"
        alert.informativeText = "Agneta forgets the tasks listed in Activity. Running tasks and your accounts aren't affected."
        // Cancel is the Return default; the destructive choice takes a click.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear History")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { model.clearHistory() }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Agneta?"
        alert.informativeText = """
            Running tasks stop. Agneta deletes, on this Mac: your account sign-ins and API keys, every app's access, task history, logs, downloaded components and preferences.

            It doesn't cancel subscriptions or delete anything your AI providers keep. Apps will ask to connect again.
            """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset Agneta")
        alert.buttons.last?.hasDestructiveAction = true
        // Cancel is the default (Return); resetting takes a deliberate click.
        if alert.runModal() == .alertSecondButtonReturn { Task { await model.resetAgneta() } }
    }

    /// A version from a bundled lock file (`goose.lock`: top-level `version`; `runtimes.lock`: per runtime).
    private func lockedVersion(_ file: String, runtime: String? = nil) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "lock"), let data = try? Data(contentsOf: url),
              let lock = try? JSONCoding.decode(data) else { return "–" }
        return (runtime.map { lock[$0]?["version"] } ?? lock["version"])??.stringValue ?? "–"
    }

    @ViewBuilder private var about: some View {
        Section {
            HStack(spacing: 16) {
                MarkTile(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agneta").font(.system(size: 18, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"), \(Bundle.main.object(forInfoDictionaryKey: "AgnetaCommit") as? String ?? "–"))" + (model.isDevelopment ? " · Development" : ""))
                        .foregroundStyle(.secondary)
                    Text("Open source under the Apache License 2.0. Your AI accounts stay on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        Section {
            LabeledContent("Agent engines", value: "Goose \(lockedVersion("goose")); OpenCode \(lockedVersion("opencode")), downloaded when an account uses it")
            LabeledContent("Codex adapter", value: "codex-acp \(lockedVersion("codex", runtime: "adapter")) on Node.js \(lockedVersion("codex", runtime: "node"))")
            LabeledContent("Claude Code adapter", value: "claude-agent-acp \(lockedVersion("runtimes", runtime: "claude-agent-acp")), downloaded on first use")
            LabeledContent("Apps connect at", value: "127.0.0.1:\(model.port)")
        } header: {
            Text("Components")
        }
        Section {
            ForEach(Self.licenses, id: \.0) { name, license in LabeledContent(name, value: license) }
            if let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil) {
                Button("Show License Texts") { NSWorkspace.shared.open(folder) }
            }
        } header: {
            Text("Open-source licenses")
        } footer: {
            Text("Claude Code and Codex are your own installs, under their makers' terms; Agneta runs them unchanged and never bundles them. The claude-agent-acp adapter is downloaded from its GitHub release on first use. Provider names and logos belong to their owners.")
        }
    }
}

/// One finished task in Activity.
struct HistoryRow: View {
    var record: TaskRecord
    var account: String
    var details: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(name: record.app, identifier: record.appIdentifier, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(record.started.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.tertiary)
            Button("Details", action: details)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [record.app, account]
        if let ended = record.ended { parts.append(Duration.seconds(max(ended.timeIntervalSince(record.started), 1)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))) }
        parts.append(outcome)
        if let cost = record.cost { parts.append(String(format: "about $%.2f", cost)) }
        return parts.joined(separator: " · ")
    }

    private var outcome: String {
        switch record.outcome {
        case .finished, nil: "Finished"
        case .stopped: "Stopped"
        case .failed: "Didn't finish"
        case .interrupted: "Stopped when Agneta quit"
        }
    }
}
