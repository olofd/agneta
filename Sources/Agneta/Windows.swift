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
    /// A dialog's corner radius, the same as a macOS window with a toolbar: the close button and the action buttons
    /// are placed for it.
    static let dialogCorner: CGFloat = 26
    private var windows: [String: NSWindow] = [:]

    /// A borderless-looking glass dialog, or a standard window for Settings.
    /// `onClose` runs when the window closes for any reason (its close button, Command-W, or code).
    private func show<Content: View>(_ key: String, title: String, size: NSSize, glass: Bool = true, resizable: Bool = false,
                                     onClose: (@MainActor () -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if Self.replacesWelcome(key) { closeWelcome() }
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
        // A dialog lays itself out under its (transparent) title bar, so it ignores the title bar's safe area.
        let host = NSHostingView(rootView: content().frame(width: glass ? size.width : nil, height: glass ? size.height : nil)
            .ignoresSafeArea(edges: glass ? .all : []).environment(\.onDialogGlass, glass).showcaseKey())
        if glass { host.sizingOptions = [] }
        if glass {
            window.titleVisibility = .hidden
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            // An empty toolbar gives the title bar a toolbar's height, so macOS places the close button for a window
            // with a toolbar's large corners, where Settings has it (measured: 19 points in from both edges; without
            // it, and with the compact style, 12 and 13: crowding the corner). Not moved by hand.
            let toolbar = NSToolbar(identifier: "dialog")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = GlassBackground.make(content: host, cornerRadius: Self.dialogCorner, surface: .dialog)
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

    /// Windows that do the first-run window's job, and say who asked: an app's "Connect Your AI" (it names the app),
    /// its approval window (with a Connect row for each provider it needs), and a sign-in. With one of them up, Welcome
    /// would be a second window saying nearly the same, so it closes (an app waiting on a fresh install opens them).
    nonisolated static func replacesWelcome(_ key: String) -> Bool { ["setup", "approval", "signin"].contains(key) }

    func showWelcome(_ model: AppModel) { show("welcome", title: "Welcome to Agneta", size: NSSize(width: 460, height: 520)) { WelcomeView(model: model) } }
    func closeWelcome() { close("welcome") }
    /// An app asked Agneta to help connect a provider: the add-provider window, naming it. A repeat brings it forward.
    func showSetup(_ model: AppModel, app: String, kind: AccountKind?) {
        show("setup", title: "Connect Your AI", size: NSSize(width: 460, height: kind == nil ? 500 : 440)) { SetupView(model: model, app: app, kind: kind) }
    }
    func closeSetup() { close("setup") }
    /// Closing the window cancels the sign-in it shows (one left running would hold its sign-in callback port).
    func showSignIn(_ model: AppModel, attempt: UUID) {
        closeSetup()
        show("signin", title: "Sign In", size: NSSize(width: 420, height: 340), onClose: { model.signIn.windowClosed(attempt) }) { SignInView(model: model) }
    }
    func closeSignIn() { close("signin") }
    /// Closing the window is Don't Allow for the request it shows; the next waiting request then appears.
    func showApproval(_ model: AppModel, request: UUID) {
        // Tall enough for what this request shows and no taller: measured from the busiest one (three providers,
        // three folders, an unverified app's code, the mode choice) at 750 points.
        let height: CGFloat = {
            guard let request = model.approvals.current else { return 750 }
            let rows = model.accounts.filter { request.kinds?.contains($0.kind) ?? true }.count
                + (request.kinds ?? []).filter { kind in !model.accounts.contains { $0.kind == kind } }.count
            let providers = CGFloat(rows == 0 ? 3 : rows) // no provider yet: about as tall as three
            let folders = CGFloat(min(request.folders.count, 3) + (request.folders.count > 3 ? 1 : 0))
            var height = 750 + 47 * (providers - 3) + 20 * (folders - 3)
            if request.namedEngines { height += 22 }
            if request.verified { height -= 55 }
            if request.tools != .workspace { height -= 85 }
            if request.replaces { height += 26 }
            return min(max(height, 520), (NSScreen.main?.visibleFrame.height ?? 900) - 60)
        }()
        show("approval", title: "Allow an App", size: NSSize(width: 480, height: height), onClose: { model.approvals.settle(request, with: nil) }) { ApprovalView(model: model) }
        windows["approval"]?.level = .floating
    }
    func closeApproval() { close("approval") }
    /// The approval window stops floating, so a sign-in or Settings opened from it comes in front of it.
    func lowerApproval() { windows["approval"]?.level = .normal }
    /// `defaults` opens Settings on a provider's model and effort sheet.
    func showSettings(_ model: AppModel, section: SettingsView.Pane = .providers, defaults: AccountRecord? = nil) {
        model.library.refreshInstalls()
        close("settings")
        show("settings", title: "Agneta Settings", size: NSSize(width: 780, height: 540), glass: false, resizable: true) {
            SettingsView(model: model, section: section, opening: defaults)
        }
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
            // As far in as the corners are round, on the sides and the bottom: no button reaches into a corner's curve.
            actions.padding(.horizontal, WindowPresenter.dialogCorner).padding(.bottom, WindowPresenter.dialogCorner)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: First run

struct WelcomeView: View {
    var model: AppModel

    var body: some View {
        DialogLayout(title: "Bring your AI to your apps",
                     message: "Sign in with the plan you already pay for. Agneta keeps it safe, and lets the apps you allow use it, with you in control.") {
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
                .buttonStyle(.link).foregroundStyle(Palette.accent).font(.system(size: 12.5)).padding(.top, 14)
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
        if let signIn = model.signIn.state {
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
                            Button("Continue", action: submit).glassButton(prominent: true).tint(Palette.fill).controlSize(.large).disabled(code.isEmpty)
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 30)
                    } else if !signIn.finished {
                        // Claude Code's adapter downloading first: how far along, as the panel shows it.
                        if signIn.kind == .claude, let download = model.library.downloads["claude-code"], download.problem == nil {
                            VStack(spacing: 6) {
                                if let fraction = download.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                                Text(download.amount).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .tint(Palette.fill)
                            .frame(width: 240)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            } actions: {
                // Like every dialog's: the buttons share the width, so they line up with the dialog's edges.
                HStack(spacing: 8) {
                    if let page = signIn.page, !signIn.finished, signIn.failed == nil {
                        Button { NSWorkspace.shared.open(page) } label: { Text("Open the Page Again").frame(maxWidth: .infinity) }.glassButton()
                    }
                    if signIn.finished || signIn.failed != nil {
                        Button { model.signIn.cancel() } label: { Text("Done").frame(maxWidth: .infinity) }
                            .glassButton(prominent: true).tint(Palette.fill).keyboardShortcut(.defaultAction)
                    } else {
                        Button { model.signIn.cancel() } label: { Text("Cancel").frame(maxWidth: .infinity) }.glassButton().keyboardShortcut(.cancelAction)
                    }
                }
                .controlSize(.large)
            }
            .animation(.easeOut(duration: 0.2), value: signIn.finished)
        }
    }

    private func submit() {
        guard !code.isEmpty else { return }
        model.signIn.submit(code)
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
        VStack(alignment: .leading, spacing: 5) {
            Label(toolsLine, systemImage: tools == .appOnly ? "puzzlepiece.extension" : tools == .read ? "doc.text.magnifyingglass" : "hammer")
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            // A few folders by name; the rest counted, all of them in the tooltip.
            ForEach(folders.prefix(3), id: \.self) { folder in
                Label(Self.display(folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }
            if folders.count > 3 {
                Label("and \(folders.count - 3) more", systemImage: "ellipsis")
                    .help(folders.dropFirst(3).map(Self.display).joined(separator: "\n"))
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var toolsLine: String {
        let reach = folders.isEmpty ? "its own workspace in Agneta" : (folders.count == 1 ? "this folder" : "these folders") + " and its own workspace"
        return switch tools {
        case .appOnly: "Only \(app)'s own tools, in \(reach)"
        case .read: "Read files in \(reach)"
        case .workspace: "Read, change and run commands in \(reach)"
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
    @State private var showsAdvanced = false

    var body: some View {
        if let approval = model.approvals.current {
            DialogLayout(title: "Let \(approval.app) use your AI?",
                         message: "Its tasks count against your plan or API credit. You can watch and stop them, and remove access, at any time.") {
                HStack(spacing: 14) {
                    AppIcon(name: approval.app, identifier: approval.verified ? approval.identifier : nil, size: 56)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                    MarkTile(size: 56)
                }
            } content: {
                VStack(spacing: 14) {
                    if shown(approval).isEmpty && missing(approval).isEmpty || model.accounts.isEmpty {
                        NoProviderYet(model: model, app: approval.app, kinds: approval.kinds)
                    } else {
                        providers(approval)
                    }
                    access(approval)
                    if approval.replaces {
                        Label("Always Allow replaces the access \(approval.app) was given before", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 34)
                    }
                    identity(approval)
                }
                .padding(.bottom, 8)
            } actions: {
                HStack(spacing: 8) {
                    // The labels fill the width so the glass bezels do too.
                    Button { model.approvals.answer(remember: nil, for: approval.id) } label: { Text("Don't Allow").frame(maxWidth: .infinity) }
                        .glassButton().keyboardShortcut(.cancelAction)
                    // Once: for this connection only, nothing kept. Return chooses it, and only for a verified app.
                    // The highlighted button is the one Return chooses, as macOS has it: Allow Once for a verified app,
                    // none for one Agneta can't verify, so nothing draws the eye to letting it in.
                    // A provider that can't run yet (Codex not installed) may still be allowed: it runs once it can.
                    let nothing = approval.allowed.isEmpty
                    Button { model.approvals.answer(remember: false, for: approval.id) } label: { Text("Allow Once").frame(maxWidth: .infinity) }
                        .glassButton(prominent: approval.verified)
                        .defaultAction(when: approval.verified)
                        .disabled(nothing)
                    Button { model.approvals.answer(remember: true, for: approval.id) } label: { Text("Always Allow").frame(maxWidth: .infinity) }
                        .glassButton()
                        .disabled(nothing)
                }
                .controlSize(.large)
            }
        }
    }
}


extension ApprovalView {
    /// The providers to allow, one row each.
    /// The providers on offer: those of the kinds the app asked for, or all of them.
    func shown(_ approval: Approvals.Request) -> [AccountRecord] {
        model.accounts.filter { approval.kinds?.contains($0.kind) ?? true }
    }

    /// The kinds the app asked for that aren't connected: each gets a row to connect it here.
    func missing(_ approval: Approvals.Request) -> [AccountKind] {
        (approval.kinds ?? []).filter { kind in !model.accounts.contains { $0.kind == kind } }
    }

    /// Why a provider can't be given as asked (contained, but none of its engines here can keep it so), or nil.
    func cantMeet(_ account: AccountRecord, _ approval: Approvals.Request) -> String? {
        approval.sandboxFixed ? model.library.sandboxUnavailable(.contained, providers: [account], engines: approval.engines) : nil
    }

    func providers(_ approval: Approvals.Request) -> some View {
        VStack(spacing: 2) {
            ForEach(shown(approval)) { account in
                let on = approval.allowed.contains(account.id)
                let reason = cantMeet(account, approval)
                Button {
                    if on { model.approvals.current?.allowed.remove(account.id) } else { model.approvals.current?.allowed.insert(account.id) }
                } label: {
                    HStack(spacing: 11) {
                        ProviderIcon(kind: account.kind, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.label).font(.system(size: 13, weight: .semibold))
                            // What it needs before it can run, where something's missing; its plan otherwise.
                            if let reason {
                                Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.attention).lineLimit(3)
                            } else if on, let reason = model.library.cantRun(account, engines: approval.engines) {
                                Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.attention).lineLimit(2)
                            } else {
                                Text(account.kind.plan).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                            .foregroundStyle(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .buttonStyle(RowButtonStyle())
                .disabled(reason != nil && !on)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            // A kind the app asked for that isn't connected: connect it here; it's ticked once it is.
            ForEach(missing(approval), id: \.self) { kind in
                HStack(spacing: 11) {
                    ProviderIcon(kind: kind, size: 28).opacity(0.6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.offerName).font(.system(size: 13, weight: .semibold))
                        Text("Not connected yet").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        WindowPresenter.shared.lowerApproval()
                        if kind.subscription != nil { model.startSignIn(kind) } else { WindowPresenter.shared.showSettings(model, section: .providers) }
                    }
                    .glassButton().controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
        .padding(5)
        .frostedCard(cornerRadius: 18)
        .padding(.horizontal, 28)
    }

    /// What the app may do, in one card: its tools and folders, how its tasks run, and (rarely needed) which engines.
    func access(_ approval: Approvals.Request) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Access").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                // Which engines the app may pick from: all of them, unless someone who knows wants otherwise. A
                // popover, so the dialog keeps its size.
                if !model.accounts.isEmpty {
                    Button(approval.namedEngines || model.library.allowance(approval.engines) == .all
                           ? "Engines…" : (approval.engines.count == 1 ? "1 engine…" : "\(approval.engines.count) engines…")) { showsAdvanced = true }
                        .buttonStyle(.link).foregroundStyle(Palette.accent).font(.system(size: 11.5))
                        .popover(isPresented: $showsAdvanced, arrowEdge: .bottom) {
                            EngineAccessList(model: model, allowed: approval.allowed,
                                             engines: Binding(get: { model.approvals.current?.engines ?? [] }, set: { model.approvals.current?.engines = $0 }),
                                             sandbox: approval.sandbox)
                                .padding(16).frame(width: 320)
                        }
                }
            }
            ApprovalScope(app: approval.app, tools: approval.tools, folders: approval.folders)
            // The engines, by name, when the app named them.
            if approval.namedEngines {
                Label(approval.engines.isEmpty ? "No engine" : model.library.all.filter { approval.engines.contains($0.id) }.map(\.name).joined(separator: ", "),
                      systemImage: "cpu").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if approval.tools == .workspace {
                Divider().opacity(0.5)
                if approval.sandboxFixed {
                    // The app asked for contained, and no more, so no more is offered.
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Tasks run contained", systemImage: "lock.shield").font(.system(size: 12.5, weight: .medium))
                        Text("Only the folders above, and commands have no internet. \(approval.app) asked for no more.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    SandboxPicker(model: model, accounts: approval.allowed, engines: approval.engines,
                                  sandbox: Binding(get: { model.approvals.current?.sandbox ?? .default }, set: { model.approvals.current?.sandbox = $0 }))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frostedCard(cornerRadius: 16)
        .padding(.horizontal, 28)
    }

    /// Who's asking: verified, or a code to compare, on one row.
    @ViewBuilder func identity(_ approval: Approvals.Request) -> some View {
        if approval.verified, let identifier = approval.identifier {
            Label("Verified app · \(identifier)", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.running)
                .font(.system(size: 12, weight: .medium))
        } else {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agneta can't verify this app").font(.system(size: 12, weight: .semibold))
                    Text("Allow it only if \(approval.app) shows this code.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(approval.code.isEmpty ? "–" : "\(approval.code.prefix(3)) \(approval.code.suffix(3))")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced)).tracking(1.5)
                    .accessibilityLabel("Code \(approval.code.map(String.init).joined(separator: " "))")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frostedCard(tint: Palette.attention.opacity(0.08), cornerRadius: 16)
            .padding(.horizontal, 28)
        }
    }
}

/// An app asks for access before any provider is connected: connect one here (the request waits), and it's ticked.
struct NoProviderYet: View {
    var model: AppModel
    var app: String
    /// The kinds the app asked for, or nil for any.
    var kinds: [AccountKind]? = nil
    /// Inside the approval window, which steps back while a sign-in or Settings is in front.
    var inApproval = true
    /// The line above the choices; the setup window says it in its own message instead.
    var showsIntro = true

    var body: some View {
        VStack(spacing: 10) {
            if showsIntro {
                Text(intro)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            GlassGroup(spacing: 8) {
                VStack(spacing: 8) {
                    if wants(.chatGPT) {
                        ProviderButton(kind: .chatGPT, title: "Continue with ChatGPT", detail: "Your ChatGPT plan, through Codex") { connect(.chatGPT) }
                    }
                    if wants(.claude) {
                        ProviderButton(kind: .claude, title: "Continue with Claude", detail: "Your Claude plan, through Claude Code") { connect(.claude) }
                    }
                }
            }
            if wants(.anthropicKey) || wants(.openAIKey) {
                Button(kinds?.allSatisfy { $0.subscription == nil } == true ? "Add an API key" : "Use an API key instead") { connect(.openAIKey) }
                    .buttonStyle(.link).foregroundStyle(Palette.accent).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 30)
    }

    private func wants(_ kind: AccountKind) -> Bool { kinds?.contains(kind) ?? true }

    private var intro: String {
        if let kinds, kinds.count == 1 { return "\(app) asks for your \(kinds[0].offerName). Connect it, and \(app) can use it." }
        return "Connect the AI you already pay for, and \(app) can use it."
    }

    /// A plan signs in; an API key is entered in Settings → Providers.
    private func connect(_ kind: AccountKind) {
        if inApproval { WindowPresenter.shared.lowerApproval() }
        if kind.subscription != nil { model.startSignIn(kind) } else { WindowPresenter.shared.showSettings(model, section: .providers) }
    }
}

/// An app asked Agneta to help connect a provider (`agneta/setup`): the first-run window's choice, naming the app,
/// narrowed to the kind it asked for. It closes when a provider is connected, which the app hears as `catalogChanged`.
struct SetupView: View {
    var model: AppModel
    var app: String
    var kind: AccountKind?

    var body: some View {
        DialogLayout(title: "Connect your AI for \(app)",
                     message: kind.map { "\(app) asks for your \($0.offerName). Connect it, and \(app) can ask to use it through Agneta." }
                        ?? "\(app) uses Agneta to work with the AI you already pay for. Connect a provider, and \(app) can ask to use it.") {
            HStack(spacing: 14) {
                AppIcon(name: app, identifier: nil, size: 56)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                MarkTile(size: 56)
            }
        } content: {
            NoProviderYet(model: model, app: app, kinds: kind.map { [$0] }, inApproval: false, showsIntro: false)
            if kind != nil {
                Button("Other providers…") { WindowPresenter.shared.showSettings(model, section: .providers) }
                    .buttonStyle(.link).foregroundStyle(Palette.accent).font(.system(size: 12)).padding(.top, 8)
            }
        } actions: {
            Button { WindowPresenter.shared.closeSetup() } label: { Text("Not Now").frame(maxWidth: .infinity) }
                .glassButton().keyboardShortcut(.cancelAction).controlSize(.large)
        }
    }
}

/// The engines an app may use, ticked (Advanced, in the approval window and Settings → Apps). The app picks one per
/// task among these and what its provider supports; a provider left with none is pointed out.
struct EngineAccessList: View {
    var model: AppModel
    /// The providers the app may use, for the warning.
    var allowed: Set<String>
    @Binding var engines: Set<String>
    /// The app's mode: an engine that can't provide it on one of its providers says so.
    var sandbox: Sandbox = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The app chooses an engine for each task from the ones ticked here.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(model.library.all, id: \.id) { engine in
                Toggle(isOn: Binding(get: { engines.contains(engine.id) }, set: { on in
                    if on { engines.insert(engine.id) } else { engines.remove(engine.id) }
                })) {
                    HStack(spacing: 6) {
                        Text(engine.name).font(.system(size: 12.5))
                        if let note = Self.note(engine, model) { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary) }
                        if let note = model.library.sandboxNote(engine.id, level: .contained, providers: model.accounts.filter { allowed.contains($0.id) }), sandbox == .contained {
                            Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox).tint(Palette.fill)
            }
            ForEach(model.accounts.filter { allowed.contains($0.id) }) { account in
                if let reason = model.library.cantRun(account, engines: engines) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Palette.attention)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func note(_ engine: EngineCatalog.Entry, _ model: AppModel) -> String? {
        switch engine.state {
        case .ready: nil
        case .downloading: "downloading"
        case .downloadable: model.library.downloadNote(for: engine.id)
        case .failed: "download failed"
        case .unavailable(let reason): reason
        }
    }
}

/// How far an app's tasks may reach, the same two modes for every engine: full power to start with, Contained when the
/// user wants it. A mode none of the app's providers and engines can provide is shown but not selectable, with why.
struct SandboxPicker: View {
    var model: AppModel
    var accounts: Set<String>
    var engines: Set<String>
    @Binding var sandbox: Sandbox

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Tasks run with", selection: $sandbox) {
                ForEach([Sandbox.developer, .contained], id: \.self) { level in
                    Text(level.title).tag(level)
                        .selectionDisabled(model.library.sandboxUnavailable(level, providers: model.accounts.filter { accounts.contains($0.id) }, engines: engines) != nil)
                }
            }
            .pickerStyle(.segmented)
            Text(model.library.sandboxUnavailable(.contained, providers: model.accounts.filter { accounts.contains($0.id) }, engines: engines)
                 ?? (sandbox == .developer
                     ? "Like Terminal: the internet, your home folder and your developer tools. Known password and key stores stay out."
                     : "Only the folders above, and commands have no internet."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What one app may use, changed in place (Settings → Apps): its providers, its mode, and its engines under Advanced.
struct AppAccess: View {
    var model: AppModel
    var grant: Router.Grant

    private var accounts: Set<String> { Set(grant.accounts) }
    private var engines: Set<String> {
        switch grant.engines {
        case .all: Set(model.library.catalog.entries.keys)
        case .only(let some): some
        }
    }

    /// The user's folders it was granted, without its own workspace (which ApprovalScope names in words).
    private var folders: [URL] {
        grant.folders.map { URL(filePath: $0, directoryHint: .isDirectory) }.filter { $0.lastPathComponent != grant.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // What it may do, as the approval window showed it.
            ApprovalScope(app: grant.app, tools: grant.tools, folders: folders).padding(.bottom, 4)
            ForEach(model.accounts) { account in
                Toggle(isOn: Binding(get: { accounts.contains(account.id) }, set: { on in
                    var changed = accounts
                    if on { changed.insert(account.id) } else { changed.remove(account.id) }
                    model.setAccess(grant, accounts: changed, engines: engines, sandbox: grant.sandbox)
                })) {
                    Text(account.label).font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox).tint(Palette.fill)
                // An app keeps at least one provider: Remove Access takes them all.
                .disabled(accounts == [account.id])
            }
            // The choice is only an app's with workspace tools; one with fewer is always contained, and says so.
            if grant.tools == .workspace {
                SandboxPicker(model: model, accounts: accounts, engines: engines,
                              sandbox: Binding(get: { grant.sandbox }, set: { model.setAccess(grant, accounts: accounts, engines: engines, sandbox: $0) }))
                    .padding(.top, 4)
            } else {
                Text("Contained: this app doesn't edit files or run commands, so it can't have developer access.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 4)
            }
            Text("Limits").font(.system(size: 12, weight: .semibold)).padding(.top, 6)
            AppLimitsEditor(model: model, grant: grant)
            DisclosureGroup("Engines") {
                EngineAccessList(model: model, allowed: accounts,
                                 engines: Binding(get: { engines }, set: { model.setAccess(grant, accounts: accounts, engines: $0, sandbox: grant.sandbox) }),
                                 sandbox: grant.ceiling)
                    .padding(.top, 4)
            }
            .font(.system(size: 12))
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
        case general = "General", providers = "Providers", engines = "Engines", apps = "Apps", activity = "Activity", privacy = "Privacy", advanced = "Advanced", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .providers: "person.crop.circle"
            case .engines: "cpu"
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
    /// A provider whose model and effort sheet opens with the window.
    var opening: AccountRecord? = nil
    @State private var keyKind: AccountKind = .anthropicKey
    @State private var key = ""
    @State private var keyError: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    /// The provider whose default model and effort are being chosen.
    @State private var defaultsFor: AccountRecord?

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
                case .providers: providersPane
                case .engines: enginesPane
                case .apps: appsPane
                case .activity: activityPane
                case .privacy: privacyPane
                case .advanced: advancedPane
                case .about: about
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.rawValue)
            .sheet(item: $defaultsFor) { DefaultsSheet(model: model, account: $0) }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { if let opening { defaultsFor = opening } }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Open Agneta at login", isOn: $openAtLogin).tint(Palette.fill)
                .onChange(of: openAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { openAtLogin = !on }
                }
        }
        Section {
            if model.updates.enabled {
                Toggle("Check for updates automatically", isOn: Binding(get: { model.updates.checksAutomatically }, set: { model.updates.checksAutomatically = $0 })).tint(Palette.fill)
                Toggle("Download and install automatically", isOn: Binding(get: { model.updates.downloadsAutomatically }, set: { model.updates.downloadsAutomatically = $0 })).tint(Palette.fill)
                    .disabled(!model.updates.checksAutomatically)
                Button("Check Now") { model.updates.check() }.disabled(!model.updates.canCheck)
            } else {
                LabeledContent("Status") { Text(model.updates.unavailableReason).foregroundStyle(.secondary) }
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

    /// The user's providers: each plan they signed in to and each API key, one account each.
    @ViewBuilder private var providersPane: some View {
        Section {
            ForEach(model.accounts) { account in
                HStack(spacing: 12) {
                    ProviderIcon(kind: account.kind, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label).font(.system(size: 13, weight: .semibold))
                        Text([account.kind.plan, account.email].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if let engine = model.library.engine(for: account.kind), let download = model.library.downloads[engine] {
                            DownloadStatus(download: download) { model.library.download(download.engine, reason: "retry") }.padding(.top, 3)
                        }
                    }
                    Spacer()
                    if account.paused { StatusPill(text: "Paused", color: .secondary) }
                    // Its provider's default engine (Settings → Engines), for reference.
                    let engine = model.library.name(model.library.engine(for: account.kind))
                    Text(engine).font(.system(size: 12)).foregroundStyle(.secondary)
                        .help("Tasks run on \(engine) unless the app picks another; the default is set in Engines")
                    Menu {
                        Button("Rename…") { askRename(account) }
                        Button(account.paused ? "Resume" : "Pause") { model.setPaused(account, !account.paused) }
                        Button("Model and Effort…") { defaultsFor = account }
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
            if model.accounts.isEmpty { Text("No providers yet.").foregroundStyle(.secondary) }
        } header: {
            Text("Connected")
        } footer: {
            HStack {
                Spacer()
                Menu("Add Provider") {
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
            Text("Add an API key")
        } footer: {
            Text("Pay as you go on your provider account. Keys stay in your Keychain and reach Agneta's engine only while a task runs.")
        }
    }

    private func askRename(_ account: AccountRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename \(account.label)"
        alert.informativeText = "Apps show this name when they list your providers."
        let field = NSTextField(string: account.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.rename(account, to: field.stringValue) }
    }

    private func confirmSignOut(_ account: AccountRecord) {
        let alert = NSAlert()
        alert.messageText = "Sign out of \(account.label)?"
        alert.informativeText = "Running tasks on it stop, and Agneta forgets its sign-in on this Mac. Your \(account.kind.provider) account itself isn't changed."
        // Cancel is the Return default; the destructive choice takes a click.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign Out")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { model.signOut(account) }
    }

    /// Engines: each kind of provider's default (tasks that don't pick an engine run on it), and what each engine is,
    /// where it comes from and which providers it can serve (ProviderEngines).
    @ViewBuilder private var enginesPane: some View {
        Section {
            ForEach(AccountKind.allCases, id: \.self) { kind in
                let options = model.library.engines(for: kind)
                if options.count > 1 {
                    Picker(Self.providerName(kind), selection: Binding(get: { model.library.chosenEngine(for: kind) ?? "" }, set: { model.library.select($0, for: kind) })) {
                        ForEach(options, id: \.id) { engine in Text(model.library.choice(engine, for: kind)).tag(engine.id) }
                    }
                } else {
                    LabeledContent(Self.providerName(kind)) {
                        Text(model.library.engine(for: kind).map { model.library.name($0) } ?? (kind == .chatGPT ? "Needs Codex" : "Needs Claude Code")).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Default engine for each provider")
        } footer: {
            Text("Apps choose the engine for each task; these are used when they don't. A ChatGPT plan works only with Codex; a Claude plan with Claude Code, or Goose running that Claude Code. Through Goose, Claude Code uses all its own tools and your claude.ai connectors, as in Terminal: what an app's tasks may do isn't limited there, apart from the folders they can reach.")
        }
        Section {
            // Each engine as its source describes it (EngineSource.all), with the install it runs through, if any.
            ForEach(model.library.sources) { source in
                engineRow(source)
                if let program = source.program { programPicker(program) }
            }
        } header: {
            Text("Engines")
        } footer: {
            Text("Goose is built in. OpenCode and Codex's runtime download the first time they're needed, pinned and checked. Claude Code and Codex are your own installs; when you have more than one, choose which.")
        }
    }

    /// One engine: its name, where it comes from, which providers it serves, its download if one is going, and any
    /// extra controls (the install it uses).
    @ViewBuilder private func engineRow(_ source: EngineSource) -> some View {
        let id = source.id
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name).font(.system(size: 13, weight: .semibold))
            Text(source.origin(model.library)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Serves " + AccountKind.allCases.filter { ProviderEngines.supported(by: $0).contains(id) }.map { Self.providerName($0) }.joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            if let download = model.library.downloads[id] {
                DownloadStatus(download: download) { model.library.download(id, reason: "retry") }.padding(.top, 3)
            } else if case .unavailable(let reason)? = model.library.catalog.entries[id]?.state {
                Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.attention)
            }
        }
        .padding(.vertical, 2)
    }

    static func providerName(_ kind: AccountKind) -> String {
        switch kind {
        case .chatGPT: "ChatGPT plan"
        case .claude: "Claude plan"
        case .openAIKey: "OpenAI API key"
        case .anthropicKey: "Anthropic API key"
        }
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
                        Text(([grant.verified ? "Verified" : "Not verified", grant.accounts.map { model.label(ofAccount: $0) }.joined(separator: ", ")]
                              + grant.limits.parts).joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove Access") { model.removeAccess(grant.id) }
                }
                .padding(.vertical, 3)
                AppAccess(model: model, grant: grant).padding(.leading, 44)
            }
        } header: {
            Text("Apps that can use Agneta")
        } footer: {
            Text("An app may use the providers ticked for it, and chooses an engine for each task from those under Engines. Its limits are yours to set: it's told when one is reached.")
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
                        Text("\(task.app) · \(model.label(ofAccount: task.account)) · \(task.sandbox.title) · \(task.started.elapsed)" + (task.cost.map { String(format: " · about $%.2f at API prices", $0) } ?? ""))
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
            LabeledContent("Providers and app access", value: "On this Mac only")
            LabeledContent("Sign-ins and API keys", value: "Your Keychain and private folders")
            LabeledContent("Task history", value: "App, title, times and usage")
            LabeledContent("Conversations", value: "Kept by the engine to resume tasks")
        } header: {
            Text("What Agneta keeps")
        } footer: {
            Text("Agneta sends nothing to its makers. What apps ask goes only to the provider each task runs on, under that provider's terms.")
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
                    Text("Signs out of every provider, removes app access, history, logs and downloads, and starts over.")
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
            })).tint(Palette.fill)
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
            LabeledContent("Running at once", value: "8 tasks, 3 per provider")
            LabeledContent("Waiting", value: "Up to 32 tasks")
        } header: {
            Text("Limits")
        } footer: {
            Text("More tasks wait their turn; one busy provider never holds up another.")
        }
    }

    /// Which of the user's installs an engine runs through, when they have more than one.
    @ViewBuilder private func programPicker(_ program: EngineSource.UserProgram) -> some View {
        let installs = model.library.installs[program.key] ?? []
        if installs.isEmpty {
            LabeledContent(program.title) { Text(program.missing).foregroundStyle(.secondary) }
        } else if installs.count == 1 {
            LabeledContent(program.title, value: installs[0].label)
        } else {
            Picker(program.title, selection: Binding(get: { model.library.program(program.key)?.id ?? "" },
                                                     set: { id in if let install = installs.first(where: { $0.id == id }) { model.library.choose(program.key, install: install) } })) {
                ForEach(installs) { install in Text(install.label).tag(install.id).selectionDisabled(!install.supported) }
            }
        }
    }

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear task history?"
        alert.informativeText = "Agneta forgets the tasks listed in Activity. Running tasks and your providers aren't affected."
        // Cancel is the Return default; the destructive choice takes a click.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear History")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { model.clearHistory() }
    }

    private func confirmReset() { model.confirmReset() }

    @ViewBuilder private var about: some View {
        Section {
            HStack(spacing: 16) {
                MarkTile(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agneta").font(.system(size: 18, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"), \(Bundle.main.object(forInfoDictionaryKey: "AgnetaCommit") as? String ?? "–"))" + (model.isDevelopment ? " · Development" : ""))
                        .foregroundStyle(.secondary)
                    Text("Open source under the Apache License 2.0. Your sign-ins and keys stay on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        Section {
            LabeledContent("Agent engines", value: "Goose \(model.library.lockedVersion("goose")); OpenCode \(model.library.lockedVersion("opencode")), downloaded when first needed")
            LabeledContent("Codex adapter", value: "codex-acp \(model.library.lockedVersion("codex", entry: "adapter")) on Node.js \(model.library.lockedVersion("codex", entry: "node"))")
            LabeledContent("Claude Code adapter", value: "claude-agent-acp \(model.library.lockedVersion("runtimes", entry: "claude-agent-acp")), downloaded on first use")
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
                // Two lines rather than cut short: the outcome and cost come last.
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
        if let outcome { parts.append(outcome) }
        if let cost = record.cost { parts.append(String(format: "about $%.2f", cost)) }
        return parts.joined(separator: " · ")
    }

    /// Nil for a task that finished, the usual case.
    private var outcome: String? {
        switch record.outcome {
        case .finished, nil: nil
        case .stopped: "Stopped"
        case .failed: "Didn't finish"
        case .interrupted: "Stopped when Agneta quit"
        }
    }
}

/// A provider's default model and effort for new tasks, picked from what its engine offers (AppModel.Defaults). The
/// choices are the engine's own, remembered from the last session it opened; with none yet, it's asked once without a
/// prompt. "The engine's default" leaves the choice to the engine.
struct DefaultsSheet: View {
    var model: AppModel
    var account: AccountRecord
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = AppModel.Defaults()
    @State private var loading = false
    @State private var problem: String?

    private var engine: String? { model.library.engine(for: account.kind) }
    private var engineName: String { model.library.name(engine) }
    private var options: [JSONValue] {
        _ = model.optionsChanged
        return engine.map { model.options(account: account.id, engine: $0) } ?? []
    }

    /// An option's values and names, grouped or not; the chosen value stays listed even if the engine no longer offers it.
    private func choices(_ category: String, keeping chosen: String?) -> [(value: String, name: String)] {
        let option = options.first { $0["category"]?.stringValue == category }
        var list: [(value: String, name: String)] = (option?["options"]?.arrayValue ?? []).flatMap { item -> [(value: String, name: String)] in
            if let value = item["value"]?.stringValue { return [(value, item["name"]?.stringValue ?? value)] }
            return (item["options"]?.arrayValue ?? []).compactMap { inner in inner["value"]?.stringValue.map { ($0, inner["name"]?.stringValue ?? $0) } }
        }
        if let chosen, !list.contains(where: { $0.value == chosen }) { list.append((chosen, chosen)) }
        return list
    }

    /// "Codex's default", with the engine's own choice where it reported one: "Codex's default (Frontier)".
    private func engineDefault(_ category: String, in list: [(value: String, name: String)]) -> String {
        let current = options.first { $0["category"]?.stringValue == category }?["currentValue"]?.stringValue
        guard let name = list.first(where: { $0.value == current })?.name else { return "\(engineName)'s default" }
        return "\(engineName)'s default (\(name))"
    }

    var body: some View {
        let models = choices("model", keeping: chosen.model), efforts = choices("thought_level", keeping: chosen.effort)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model and effort for \(account.label)").font(.system(size: 15, weight: .semibold))
                Text("New tasks on \(account.label) start with these, unless the app picks its own.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if models.isEmpty && efforts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Agneta hasn't seen what \(engineName) offers on this provider yet. It can ask now; nothing is sent to the model.")
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(loading ? "Asking \(engineName)…" : "Show the Choices", action: load).disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Palette.attention) }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Model").gridColumnAlignment(.trailing)
                        Picker("Model", selection: $chosen.model) {
                            Text(engineDefault("model", in: models)).tag(String?.none)
                            ForEach(models, id: \.value) { Text($0.name).tag(String?.some($0.value)) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Effort")
                        Picker("Effort", selection: $chosen.effort) {
                            Text(engineDefault("thought_level", in: efforts)).tag(String?.none)
                            ForEach(efforts, id: \.value) { Text($0.name).tag(String?.some($0.value)) }
                        }
                        .labelsHidden()
                        .disabled(efforts.isEmpty)
                    }
                }
                .font(.system(size: 13))
                if efforts.isEmpty { Text("\(engineName) doesn't offer a choice of effort here.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setDefaults(account, chosen); dismiss() }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .tint(Palette.fill)
        .onAppear { chosen = model.defaults(of: account) }
    }

    private func load() {
        loading = true
        problem = nil
        _Concurrency.Task {
            problem = await model.loadOptions(account)
            loading = false
        }
    }
}
