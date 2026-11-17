// Pairing requests waiting for the user, one shown at a time. Every request is
// answered exactly once: by the user, by dismissing its window (Don't Allow),
// by its app going away, by expiry, or by Reset. A request left unanswered
// would keep its app waiting forever, and every later request behind it.
import Foundation

public struct ApprovalQueue<Request: Sendable, Value: Sendable>: Sendable {
    /// Called once with the user's answer, or nil for Don't Allow.
    public typealias Answer = @Sendable (_ value: Value?) -> Void

    struct Entry: Sendable {
        let id: UUID
        var request: Request
        let answer: Answer
    }

    private var shown: Entry?
    private var waiting: [Entry] = []

    public init() {}

    /// The request on screen, if any.
    public var current: Request? {
        get { shown?.request }
        set { if let newValue { shown?.request = newValue } }
    }

    public var currentID: UUID? { shown?.id }
    public var count: Int { (shown == nil ? 0 : 1) + waiting.count }

    /// Adds a request. True when it's now the one to show (nothing else was waiting for the user).
    public mutating func add(id: UUID, _ request: Request, answer: @escaping Answer) -> Bool {
        let entry = Entry(id: id, request: request, answer: answer)
        guard shown == nil else {
            waiting.append(entry)
            return false
        }
        shown = entry
        return true
    }

    /// Answers request `id`, whether shown or waiting; nil is Don't Allow. Unknown ids (already answered) are
    /// ignored. True when the shown request changed: show `current`, or close the window if it's nil.
    @discardableResult
    public mutating func answer(_ id: UUID, with value: Value?) -> Bool {
        if shown?.id == id {
            let entry = shown!
            shown = waiting.isEmpty ? nil : waiting.removeFirst()
            entry.answer(value)
            return true
        }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        waiting.remove(at: index).answer(value)
        return false
    }

    /// Answers every request with Don't Allow (Reset, quitting).
    public mutating func refuseAll() {
        let all = (shown.map { [$0] } ?? []) + waiting
        shown = nil
        waiting = []
        all.forEach { $0.answer(nil) }
    }
}
