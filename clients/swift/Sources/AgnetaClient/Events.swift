import Foundation

@MainActor final class EventHub<Event> {
    typealias Listener = @MainActor (Event) -> Void
    private var listeners: [(UUID, Listener)] = []
    @discardableResult func on(_ listener: @escaping Listener) -> @MainActor () -> Void {
        let id = UUID()
        listeners.append((id, listener))
        return { [weak self] in self?.listeners.removeAll { $0.0 == id } }
    }
    func emit(_ event: Event) {
        let snapshot = listeners
        for (_, listener) in snapshot { listener(event) }
    }
}

// The continuation gate also works with UI guides that do not themselves respond to cancellation.
// Once settled, a late answer cannot resume the caller or open anything.
@MainActor private final class WaitGate<T: Sendable> {
    var continuation: CheckedContinuation<T, any Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var result: Result<T, any Error>?
    func finish(_ result: Result<T, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        work?.cancel(); timer?.cancel(); work = nil; timer = nil
        continuation?.resume(with: result); continuation = nil
    }
}

@MainActor func withDeadline<T: Sendable>(
    _ seconds: TimeInterval, method: String,
    operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    guard seconds.isFinite, seconds >= 0 else {
        throw AgnetaError(.invalidParams, "Timeout must be finite and nonnegative.")
    }
    try Task.checkCancellation()
    let gate = WaitGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation
            if let result = gate.result { continuation.resume(with: result); gate.continuation = nil; return }
            gate.work = Task { @MainActor in
                do { let result = try await operation(); gate.finish(.success(result)) } catch {
                    gate.finish(.failure(error))
                }
            }
            if seconds > 0 {
                gate.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    gate.finish(
                        .failure(AgnetaError(.timeout, "\(method) timed out after \(seconds) seconds.", method: method))
                    )
                }
            }
        }
    } onCancel: {
        Task { @MainActor in gate.finish(.failure(CancellationError())) }
    }
}
