// After a crash, engines Agneta started may still run. Each one was recorded
// with its pid and process start time; at the next launch a process is stopped
// only when both still match and it still leads its own process group, so a
// reused pid is never touched. Never by name.
import Darwin
import Foundation

/// Where the supervisor reports the engines it starts and stops.
public protocol EngineLedger: Sendable {
    func engineStarted(pid: pid_t, account: String)
    func engineStopped(pid: pid_t)
}

public enum EngineReaper {
    /// The process's start time in seconds since 1970 (microsecond precision), or nil if it isn't running.
    public static func startTime(of pid: pid_t) -> Double? {
        bsdInfo(pid).map { Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1_000_000 }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Whether `record` still describes a live process: same pid, same start time, its own group leader.
    public static func isAlive(_ record: EngineRecord) -> Bool {
        guard let info = bsdInfo(record.pid) else { return false }
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return abs(started - record.started) < 0.000_002 && info.pbi_pgid == UInt32(record.pid)
    }

    /// Stops every recorded engine that is still alive, with its whole process group.
    /// Returns the pids it stopped.
    public static func reap(_ records: [EngineRecord], grace: Duration = .seconds(3)) async -> [pid_t] {
        let alive = records.filter(isAlive)
        for record in alive { killpg(record.pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        while alive.contains(where: isAlive), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for record in alive where isAlive(record) { killpg(record.pid, SIGKILL) }
        return alive.map(\.pid)
    }
}
