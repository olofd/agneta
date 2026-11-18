// The menu bar panel. One status sentence first; running tasks next (they
// change), accounts last (they don't). Every row reacts to the pointer; rows
// open the matching Settings pane; decisions open windows.
import AgnetaKit
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    var dismiss: () -> Void = {}
    /// Its size changed, so the panel around it can follow.
    var resized: () -> Void = {}
    @State private var confirmStop: AppModel.Task?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    if let problem = model.attentionMessage { attention(problem) }
                    if let update = updateMessage { notice(update) }
                    ForEach(model.library.downloads.values.sorted { $0.engine < $1.engine }, id: \.engine) { download in downloadCard(download) }
                    if !model.tasks.isEmpty { tasksCard }
                    accountsCard
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in resized() }
        .confirmationDialog(confirmStop.map { "Stop “\($0.title)”?" } ?? "", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } })) {
            Button("Stop Task", role: .destructive) { if let task = confirmStop { model.stop(task) }; confirmStop = nil }
            Button("Keep Running", role: .cancel) { confirmStop = nil }
        } message: {
            if let task = confirmStop { Text("It has run for \(task.started.elapsed). \(task.stopWarning ?? "The app keeps the work so far.")") }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            MarkTile(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.status).font(.system(size: 15, weight: .semibold)).contentTransition(.opacity)
                Text(model.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Run a Test Task") { model.runTestTask() }.disabled(model.testClientURL == nil || model.accounts.isEmpty)
                Divider()
                // Always here: a build that doesn't update itself says why instead of leaving the item missing.
                Button("Check for Updates…") { open { model.updates.enabled ? model.updates.check() : WindowPresenter.shared.explainNoUpdates(model) } }
                    .disabled(model.updates.enabled && !model.updates.canCheck)
                Button("Settings…") { open { WindowPresenter.shared.showSettings(model) } }.keyboardShortcut(",")
                Button("About Agneta") { open { WindowPresenter.shared.showSettings(model, section: .about) } }
                Divider()
                Button("Quit Agneta") { open { WindowPresenter.shared.quit(model) } }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.button).menuIndicator(.hidden).glassButton().buttonBorderShape(.circle).fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 2)
    }

    // MARK: Attention

    private func attention(_ message: (title: String, detail: String, action: String, run: () -> Void)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20)).foregroundStyle(Palette.attention)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.title).font(.system(size: 13, weight: .semibold))
                Text(message.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(message.action, action: message.run).glassButton(prominent: true).tint(Palette.accent).controlSize(.small)
        }
        .padding(12)
        .frostedCard(tint: Palette.attention)
    }

    // MARK: Updates

    /// An update a scheduled check found, or one that waits for the running tasks to end.
    private var updateMessage: (title: String, detail: String, action: String, run: () -> Void)? {
        let updates = model.updates
        if let version = updates.waitingToInstall {
            let count = model.tasks.count
            return ("Agneta \(version) is ready", count == 1 ? "It installs when the running task ends." : "It installs when the \(count) running tasks end.",
                    "Install Now", { open { WindowPresenter.shared.installUpdate(model) } })
        }
        if let version = updates.available {
            return ("Agneta \(version) is available", "Running tasks finish before it installs.", "Update…", { open { updates.check() } })
        }
        return nil
    }

    private func notice(_ message: (title: String, detail: String, action: String, run: () -> Void)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.title).font(.system(size: 13, weight: .semibold))
                Text(message.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(message.action, action: message.run).glassButton(prominent: true).tint(Palette.accent).controlSize(.small)
        }
        .padding(12)
        .frostedCard(tint: Palette.accent)
    }

    // MARK: Downloads

    /// What an engine needs, downloading (with its progress) or failed (with Try Again), whatever started it.
    private func downloadCard(_ download: EngineDownload) -> some View {
        let failed = download.problem != nil
        return HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "arrow.down.circle.fill").font(.system(size: 20))
                .foregroundStyle(failed ? Palette.attention : Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(failed ? "\(download.title) couldn't be downloaded" : "Downloading \(download.title)").font(.system(size: 13, weight: .semibold))
                if failed {
                    Text("Check your connection, then try again.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    if let fraction = download.fraction { ProgressView(value: fraction).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                    Text(download.amount).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 6)
            if failed {
                Button("Try Again") { model.library.download(download.engine, reason: "retry") }.glassButton(prominent: true).tint(Palette.accent).controlSize(.small)
                Button { model.library.putAway(download.engine) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Hide; it downloads again when it's needed")
                    .accessibilityLabel("Hide")
            }
        }
        .padding(12)
        .frostedCard(tint: failed ? Palette.attention : Palette.accent)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tasks

    private var tasksCard: some View {
        VStack(spacing: 2) {
            SectionTitle(text: "Now").padding(.top, 8)
            ForEach(model.tasks) { task in
                TaskRow(task: task, account: model.account(task.account), stop: { requestStop(task) }) {
                    open { WindowPresenter.shared.showSettings(model, section: .activity) }
                }
            }
        }
        .padding(4).padding(.bottom, 2)
        .frostedCard()
    }

    /// Closes the panel, then opens a window, like a menu does.
    private func open(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        _Concurrency.Task { @MainActor in action() }
    }

    private func requestStop(_ task: AppModel.Task) {
        // Short tasks stop at once; long ones ask once.
        if Date().timeIntervalSince(task.started) > 120 { confirmStop = task } else { model.stop(task) }
    }

    // MARK: Providers

    private var accountsCard: some View {
        VStack(spacing: 2) {
            SectionTitle(text: "Providers").padding(.top, 8)
            if model.accounts.isEmpty {
                VStack(spacing: 10) {
                    Text("Connect the AI account you already pay for, and the apps you allow can use it.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Connect a Provider…") { open { WindowPresenter.shared.showWelcome(model) } }.glassButton(prominent: true).tint(Palette.accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            ForEach(model.accounts) { account in
                AccountRow(account: account, engine: model.library.name(model.library.engine(for: account.kind)), needsSignIn: model.needsSignIn.contains(account.id),
                           limitedUntil: model.limited[account.id], planUsage: model.planUsage[account.id]) {
                    open { WindowPresenter.shared.showSettings(model, section: .providers) }
                }
            }
        }
        .padding(4).padding(.bottom, 2)
        .frostedCard()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { open { WindowPresenter.shared.showSettings(model) } } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button { open { WindowPresenter.shared.showSettings(model, section: .activity) } } label: { Label("Activity", systemImage: "clock") }
        }
        .glassButton().controlSize(.regular).labelStyle(.titleAndIcon)
    }
}

struct TaskRow: View {
    var task: AppModel.Task
    var account: AccountRecord?
    var stop: () -> Void
    var open: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: open) {
                HStack(spacing: 11) {
                    AppIcon(name: task.app, identifier: task.appIdentifier, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            HStack(spacing: 5) {
                                if let account { ProviderIcon(kind: account.kind, size: 12, framed: false) }
                                Text(detail).lineLimit(1)
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if task.running && !task.stopping { LiveDot() }
                }
                .padding(.vertical, 7).padding(.leading, 8).padding(.trailing, 4)
            }
            .buttonStyle(RowButtonStyle())
            CircleIconButton(symbol: "stop.fill", label: "Stop \(task.title)", size: 26, action: stop)
                .disabled(task.stopping).padding(.trailing, 6)
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let who = account?.label ?? task.account
        if task.stopping { return "\(task.app) · \(who) · stopping…" }
        return "\(task.app) · \(who) · \(task.running ? task.started.elapsed : "ready")"
    }
}

struct AccountRow: View {
    var account: AccountRecord
    /// The engine it runs on, by name.
    var engine: String
    var needsSignIn: Bool
    /// Set when a provider limit stopped a task: the reset time, or nil inside when unknown.
    var limitedUntil: Date?? = nil
    /// The plan's own usage, when its engine reports it.
    var planUsage: String? = nil
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                ProviderIcon(kind: account.kind, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label).font(.system(size: 13, weight: .semibold))
                    Text("\(planUsage ?? account.kind.plan) · \(engine)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if needsSignIn {
                    StatusPill(text: "Sign in again", color: Palette.attention)
                } else if account.paused {
                    StatusPill(text: "Paused", color: .secondary)
                } else if let limitedUntil, limitedUntil.map({ $0 > Date() }) ?? true {
                    StatusPill(text: limitedUntil.map { "Limit · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "Limit reached", color: Palette.attention)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("\(account.label), \(account.kind.plan), runs on \(engine)\(needsSignIn ? ", needs sign-in" : "")")
    }
}
