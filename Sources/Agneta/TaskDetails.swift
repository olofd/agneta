// A task's details from its trace (Settings → Activity → Details): turns, tools,
// model calls and Agneta's decisions, and Export Diagnostics for a bug report,
// with or without prompts and tool content.
import AgnetaKit
import AppKit
import SwiftUI

struct TaskDetailsView: View {
    var model: AppModel
    var task: String
    var title: String
    @State private var summary: TraceSummary?

    var body: some View {
        Form {
            if let summary {
                Section {
                    LabeledContent("App", value: summary.app ?? "Unknown")
                    LabeledContent("Account", value: [summary.account, summary.billing.map { $0 == "subscription" ? "plan" : "API key" }].compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("Tools", value: [summary.tools, summary.network.map { $0 == "none" ? "no network" : $0 }].compactMap { $0 }.joined(separator: " · "))
                    if let cost = summary.cost {
                        LabeledContent("Cost", value: String(format: "about $%.2f", cost) + (summary.billing == "subscription" ? " at API prices" : ""))
                    }
                }
                Section("Turns") {
                    if summary.turns.isEmpty { Text("No turns yet.").foregroundStyle(.secondary) }
                    ForEach(summary.turns, id: \.n) { turn in
                        LabeledContent {
                            Text("\(Self.seconds(turn.ms)) · \(turn.modelCalls) model \(turn.modelCalls == 1 ? "call" : "calls") · \(turn.input + turn.output) tokens")
                                .monospacedDigit()
                        } label: {
                            Text("Turn \(turn.n)") + Text(turn.stopReason == "end_turn" ? "" : "  \(Self.reason(turn.stopReason))").foregroundStyle(Palette.attention)
                        }
                        .help(turn.error ?? "First reply after \(Self.seconds(turn.msToFirstToken))")
                    }
                }
                Section("Tools") {
                    if summary.toolStats.isEmpty { Text("No tools used.").foregroundStyle(.secondary) }
                    ForEach(summary.toolStats, id: \.name) { tool in
                        LabeledContent(tool.name) {
                            Text("\(tool.calls)×\(tool.errors > 0 ? " · \(tool.errors) failed" : "") · \(Self.seconds(tool.totalMs))").monospacedDigit()
                        }
                    }
                }
                Section("Model") {
                    LabeledContent("Calls", value: "\(summary.modelCalls)\(summary.compactions > 0 ? " · \(summary.compactions) compactions" : "")")
                    LabeledContent("Tokens", value: "\(summary.input) in · \(summary.output) out · \(summary.cacheRead) from cache")
                }
                Section("Agneta") {
                    LabeledContent("Shell commands", value: "\(summary.shellCommands)\(summary.shellFailures > 0 ? " · \(summary.shellFailures) failed" : "")\(summary.shellRefused > 0 ? " · \(summary.shellRefused) refused" : "")")
                    LabeledContent("Permissions", value: summary.permissions.isEmpty ? "None asked" : summary.permissions.sorted { $0.key < $1.key }.map { "\(Self.decision($0.key)) \($0.value)" }.joined(separator: ", "))
                    ForEach(Array(summary.lifecycle.enumerated()), id: \.offset) { _, record in
                        if let line = Self.lifecycle(record) { Text(line).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Text("This task has no diagnostics. Its trace was removed with its history.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.traceFile(task)]) }
                Spacer()
                Button("Export Diagnostics…") { model.exportDiagnostics(task, title: title) }.buttonStyle(.borderedProminent)
            }
            .disabled(summary == nil)
            .padding(14)
            .background(.bar)
        }
        .frame(minWidth: 460, minHeight: 420)
        .task {
            // Traces can be large: read and add up off the main thread.
            let folder = model.store.tracesFolder, task = task
            summary = await Task.detached { Traces(folder: folder).records(task: task).map { TraceSummary(records: $0) } }.value
        }
    }

    static func seconds(_ ms: Double?) -> String {
        guard let ms else { return "–" }
        if ms < 1000 { return "\(Int(ms)) ms" }
        if ms < 60_000 { return String(format: "%.1f s", ms / 1000) }
        let seconds = Int((ms / 1000).rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
    }

    static func reason(_ stopReason: String) -> String {
        switch stopReason {
        case "cancelled": "stopped"
        case "error": "didn't finish"
        case "max_turn_requests": "turn limit"
        default: stopReason
        }
    }

    static func decision(_ value: String) -> String {
        switch value {
        case "asked-app": "asked the app"
        case "allowed-by-policy": "allowed by its rules"
        case "refused-by-policy": "refused by its rules"
        default: value
        }
    }

    static func lifecycle(_ record: JSONValue) -> String? {
        switch record["event"]?.stringValue {
        case "stop": "Stopped by \(record["by"]?.stringValue ?? "?")\(record["reason"]?.stringValue.map { " (\($0))" } ?? "")"
        case "limit": "Stopped at its \(record["limit"]?.stringValue ?? "?") limit"
        case "queued": "Waited for room"
        case "resumed": "Resumed"
        case "forked": "Started as a copy of an earlier task"
        case "steer": "Steered (\(record["delivery"]?.stringValue ?? "?"))"
        case "engine-exit": "The engine exited"
        case "dropped", "trace-truncated": "Some detail was left out to keep the trace small"
        default: nil
        }
    }
}

extension AppModel {
    func traceFile(_ task: String) -> URL { store.tracesFolder.appending(path: "\(task).jsonl") }

    /// Asks where to save, with a choice to leave out content, names and paths (on by default). The trace (up to
    /// 1 GB) is copied off the main thread, record by record.
    func exportDiagnostics(_ task: String, title: String) {
        let trace = traceFile(task)
        guard FileManager.default.fileExists(atPath: trace.path(percentEncoded: false)) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Agneta diagnostics – \(title).jsonl"
        let redact = NSButton(checkboxWithTitle: "Leave out content, names and paths", target: nil, action: nil)
        redact.state = .on
        panel.accessoryView = redact
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let redactContent = redact.state == .on, log = log
        _Concurrency.Task {
            let failure = await _Concurrency.Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try TraceExport.write(trace: trace, to: url, redactContent: redactContent)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let failure else { return }
            log.error("export-failed", ["task": .string(task), "reason": .string(failure)])
            let alert = NSAlert()
            alert.messageText = "Agneta couldn't export the diagnostics"
            alert.informativeText = failure
            alert.runModal()
        }
    }
}
