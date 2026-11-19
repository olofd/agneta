// Reading a task's trace from a test. The trace writer writes off the caller's thread, so a test that reads the
// file right after a request can find it a record short (CI hit this twice on 2026-11-18): flush first.
import Foundation

@testable import AgnetaKit

extension Traces {
    /// A task's trace as written so far, with its writer flushed first while the task is open.
    func text(of task: String) throws -> String {
        session(task)?.writer.flush()
        return try String(contentsOf: file(for: task), encoding: .utf8)
    }
}
