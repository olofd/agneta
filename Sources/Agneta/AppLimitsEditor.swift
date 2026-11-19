// The limits the user sets for one app, in Settings → Apps: what it may spend on API keys, its tasks at once, and its
// new tasks, each a toggle and a number, with the app's usage first so the user sees what a limit would mean. Every
// change is saved at once (AppModel.setLimits); a number that isn't a valid limit isn't applied. At a limit, work
// stops (more is refused, or for at once waits), so there's nothing to choose about what happens then yet.
import AgnetaKit
import SwiftUI

struct AppLimitsEditor: View {
    var model: AppModel
    var grant: Router.Grant
    /// Why the last number typed wasn't applied, until the next change.
    @State private var problem: String?

    private var limits: AppLimits { grant.limits }
    private var status: AppLimitStatus? { model.appStatus[grant.id] }
    private var providers: [AccountRecord] { model.accounts.filter { grant.accounts.contains($0.id) } }
    private var engines: Set<String> {
        switch grant.engines {
        case .all: Set(model.library.catalog.entries.keys)
        case .only(let some): some
        }
    }

    /// Plans aren't charged per call: an app that uses only plans isn't offered a spending limit.
    private var usesKeys: Bool { providers.contains { $0.kind.subscription == nil } }

    private func set(_ change: (inout AppLimits) -> Void) {
        var changed = limits
        change(&changed)
        guard changed != limits else { return }
        problem = changed.problem(global: model.maxAtOnce)
        guard problem == nil else { return }
        model.setLimits(grant, changed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.usage(status)).font(.system(size: 11.5)).foregroundStyle(.secondary)

            if usesKeys || limits.spend != nil {
                Toggle(
                    isOn: Binding(
                        get: { limits.spend != nil },
                        set: { on in set { $0.spend = on ? .init(max: 5, period: .day) : nil } })
                ) {
                    Text("Limit spending on API keys").font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox).tint(Palette.fill)
            }
            if let spend = limits.spend {
                HStack(spacing: 6) {
                    Text("Up to $").font(.system(size: 12))
                    TextField(
                        "Amount", value: Binding(get: { spend.max }, set: { value in set { $0.spend?.max = value } }),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .labelsHidden().frame(width: 64).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Most it may spend, in dollars")
                    Picker(
                        "Per",
                        selection: Binding(get: { spend.period }, set: { period in set { $0.spend?.period = period } })
                    ) {
                        Text("a day").tag(AppLimits.Period.day)
                        Text("a week").tag(AppLimits.Period.week)
                        Text("a month").tag(AppLimits.Period.month)
                    }
                    .labelsHidden().fixedSize()
                    Text("at API prices").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
                if let line = Self.spent(status, spend) {
                    Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 20)
                }
            }
            ForEach(
                Self.spendNotes(limits: limits, providers: providers.map(\.kind), engines: engines)
                    + Self.unpricedNote(status), id: \.self
            ) { note in
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true
                ).padding(.leading, 20)
            }

            Toggle(isOn: Binding(get: { limits.atOnce != nil }, set: { on in set { $0.atOnce = on ? 2 : nil } })) {
                Text("Limit tasks at once").font(.system(size: 12.5))
            }
            .toggleStyle(.checkbox).tint(Palette.fill)
            if let atOnce = limits.atOnce {
                Stepper(
                    value: Binding(get: { atOnce }, set: { value in set { $0.atOnce = value } }),
                    in: 1...model.maxAtOnce
                ) {
                    Text("\(atOnce) at once. More wait their turn.").font(.system(size: 12))
                }
                .padding(.leading, 20)
            }

            Toggle(
                isOn: Binding(
                    get: { limits.newTasks != nil },
                    set: { on in set { $0.newTasks = on ? .init(max: 10, period: .hour) : nil } })
            ) {
                Text("Limit new tasks").font(.system(size: 12.5))
            }
            .toggleStyle(.checkbox).tint(Palette.fill)
            if let starts = limits.newTasks {
                HStack(spacing: 6) {
                    Text("Up to").font(.system(size: 12))
                    TextField(
                        "Tasks",
                        value: Binding(get: { starts.max }, set: { value in set { $0.newTasks?.max = value } }),
                        format: .number
                    )
                    .labelsHidden().frame(width: 56).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Most new tasks")
                    Picker(
                        "Per",
                        selection: Binding(
                            get: { starts.period }, set: { period in set { $0.newTasks?.period = period } })
                    ) {
                        Text("an hour").tag(AppLimits.Period.hour)
                        Text("a day").tag(AppLimits.Period.day)
                    }
                    .labelsHidden().fixedSize()
                    if let started = status?.started {
                        Text("\(started) so far").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 20)
            }
            if let problem {
                Text("\(problem); not changed.").font(.system(size: 11.5)).foregroundStyle(Palette.attention)
            }
            Text("When a limit is reached, the app's tasks stop and it's told why. Resuming a task isn't a new one.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Words

    /// "Today: 4 tasks · $1.20 on API keys"; nothing yet: "Nothing today yet".
    static func usage(_ status: AppLimitStatus?) -> String {
        guard let today = status?.today, today.tasks + today.turns > 0 || today.cost > 0 else {
            return "Nothing today yet"
        }
        var parts = [today.tasks == 1 ? "1 task" : "\(today.tasks) tasks"]
        if today.cost > 0 { parts.append("\(AppLimits.cents(today.cost)) on API keys") }
        return "Today: " + parts.joined(separator: " · ")
    }

    /// "$1.20 of $5 · resets at midnight".
    static func spent(_ status: AppLimitStatus?, _ spend: AppLimits.Spend) -> String? {
        guard let spent = status?.spent else { return nil }
        return "\(AppLimits.cents(spent)) of \(AppLimits.dollars(spend.max))"
            + (status?.spendResets.map { " · resets \($0)" } ?? "")
    }

    /// Turns today whose engine gave no price for the model they called: a spending limit couldn't count them.
    static func unpricedNote(_ status: AppLimitStatus?) -> [String] {
        guard let unpriced = status?.today.unpriced, unpriced > 0 else { return [] }
        return [
            "\(unpriced == 1 ? "1 turn" : "\(unpriced) turns") today called a model its engine has no price for, so \(unpriced == 1 ? "its" : "their") cost isn't known or counted."
        ]
    }

    /// What the user should know about a spending limit for this app: plans aren't counted, Claude Code counts at a
    /// turn's end, and Codex can't run on an API key under it. Only what applies to the app's providers and engines.
    static func spendNotes(limits: AppLimits, providers: [AccountKind], engines: Set<String>) -> [String] {
        let keys = providers.filter { $0.subscription == nil }, plans = providers.filter { $0.subscription != nil }
        var notes: [String] = []
        if !plans.isEmpty {
            notes.append(
                keys.isEmpty
                    ? "This app uses only plans, which aren't charged per call: a spending limit wouldn't count its tasks."
                    : "Counts tasks on API keys only. A plan isn't charged per call, so its tasks aren't counted or stopped."
            )
        }
        guard limits.spend != nil else { return notes }
        if keys.contains(.anthropicKey), engines.contains("claude-code") {
            notes.append("Claude Code's cost is known when a turn ends, so a turn on it can go over the limit.")
        }
        if keys.contains(.openAIKey), engines.contains("codex") {
            notes.append(
                "Codex reports no cost, so this app's tasks on an OpenAI API key can't use Codex while spending is limited."
            )
        }
        return notes
    }
}
