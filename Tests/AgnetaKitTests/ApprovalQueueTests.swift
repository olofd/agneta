// The pairing queue behind Agneta's approval window: every request answered exactly once, whichever way it ends.
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct ApprovalQueueTests {
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func record(_ name: String) -> ApprovalQueue<String, [String]>.Answer {
            { [self] allowed in lock.withLock { log.append("\(name): \(allowed?.joined(separator: ",") ?? "refused")") } }
        }
        var all: [String] { lock.withLock { log } }
    }

    /// One request shows at a time; answering it shows the next. Dismissing the window (answering nil) does the
    /// same: the bug was a dismissed window leaving its request, and every one behind it, waiting forever.
    @Test func answeringTheShownRequestShowsTheNext() {
        var queue = ApprovalQueue<String, [String]>()
        let answers = Answers()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let aShows = queue.add(id: a, "A", answer: answers.record("A"))
        let bShows = queue.add(id: b, "B", answer: answers.record("B"))
        let cShows = queue.add(id: c, "C", answer: answers.record("C"))
        #expect(aShows && !bShows && !cShows)
        #expect(queue.current == "A" && queue.count == 3)
        let closedWindowAdvanced = queue.answer(a, with: nil) // the window was closed
        #expect(closedWindowAdvanced && queue.current == "B")
        let allowAdvanced = queue.answer(b, with: ["acct"])
        #expect(allowAdvanced && queue.current == "C")
        #expect(answers.all == ["A: refused", "B: acct"])
    }

    /// A request answered twice (the window closing after the user clicked Allow, an expiry after an answer) is
    /// answered once; a waiting request withdrawn (its app went away) leaves the shown one alone.
    @Test func everyRequestIsAnsweredExactlyOnce() {
        var queue = ApprovalQueue<String, [String]>()
        let answers = Answers()
        let (a, b, c) = (UUID(), UUID(), UUID())
        _ = queue.add(id: a, "A", answer: answers.record("A"))
        _ = queue.add(id: b, "B", answer: answers.record("B"))
        _ = queue.add(id: c, "C", answer: answers.record("C"))
        let allowed = queue.answer(a, with: ["x"])
        let lateAnswerChangedAnything = queue.answer(a, with: nil)
        let withdrawalChangedShown = queue.answer(c, with: nil)
        #expect(allowed && !lateAnswerChangedAnything && !withdrawalChangedShown)
        #expect(queue.current == "B")
        queue.refuseAll() // Reset
        let answeredAfterReset = queue.answer(b, with: ["x"])
        #expect(queue.current == nil && queue.count == 0 && !answeredAfterReset)
        #expect(answers.all == ["A: x", "C: refused", "B: refused"])
    }

    /// The user's edits to the shown request (which accounts) are kept until it's answered.
    @Test func editsToTheShownRequestStick() {
        var queue = ApprovalQueue<String, [String]>()
        _ = queue.add(id: UUID(), "A", answer: { _ in })
        queue.current = "A edited"
        #expect(queue.current == "A edited")
        queue.current = nil // ignored: only answering removes a request
        #expect(queue.current == "A edited")
    }
}
