// What Settings → Apps and the panel say about the limits the user set for an app.
import AgnetaKit
import Foundation
import Testing
@testable import Agneta

@MainActor struct AppLimitsWordsTests {
    @Test func theEditorSaysWhatALimitWouldMean() {
        #expect(AppLimitsEditor.usage(nil) == "Nothing today yet")
        #expect(AppLimitsEditor.usage(AppLimitStatus(today: .init(cost: 1.2, turns: 9, tasks: 4))) == "Today: 4 tasks · $1.20 on API keys")
        #expect(AppLimitsEditor.usage(AppLimitStatus(today: .init(turns: 2, tasks: 1))) == "Today: 1 task")
        let spend = AppLimits.Spend(max: 5, period: .day)
        #expect(AppLimitsEditor.spent(AppLimitStatus(spent: 1.2, spendResets: "at midnight"), spend) == "$1.20 of $5 · resets at midnight")

        let limited = AppLimits(spend: spend)
        let all: Set<String> = ["goose", "opencode", "claude-code", "codex"]
        #expect(AppLimitsEditor.spendNotes(limits: limited, providers: [.openAIKey], engines: ["goose"]).isEmpty)
        #expect(AppLimitsEditor.spendNotes(limits: limited, providers: [.claude, .anthropicKey, .openAIKey], engines: all) == [
            "Counts tasks on API keys only. A plan isn't charged per call, so its tasks aren't counted or stopped.",
            "Claude Code's cost is known when a turn ends, so a turn on it can go over the limit.",
            "Codex reports no cost, so this app's tasks on an OpenAI API key can't use Codex while spending is limited.",
        ])
        #expect(AppLimitsEditor.spendNotes(limits: .none, providers: [.chatGPT], engines: all)
            == ["This app uses only plans, which aren't charged per call: a spending limit wouldn't count its tasks."])
    }

    @Test func thePanelSaysWhichAppReachedWhichLimit() {
        let spend = AppLimitNotice(grant: "g", app: "Example App", limit: "spend", summary: "$5 a day", used: "$5.04 today", resetsAt: nil, resets: "at midnight")
        #expect(AppModel.limitTitle(spend) == "Example App reached its limit")
        #expect(AppModel.limitDetail(spend) == "$5.04 today, of $5 a day · resets at midnight")
        let starts = AppLimitNotice(grant: "g", app: "Example App", limit: "newTasks", summary: "10 new tasks an hour", used: "10 in the last hour",
                                    resetsAt: nil, resets: "at 15:12")
        #expect(AppModel.limitDetail(starts) == "10 in the last hour, of 10 new tasks an hour · frees up at 15:12")
    }
}
