// agneta-diag: reads Agneta's task traces (docs/DIAGNOSTICS.md) for people and
// scripts. Read-only, except `export`, which writes the file you name.
//
//   agneta-diag [--home <dir>] tasks [--limit <n>]
//   agneta-diag [--home <dir>] show <task> [--types t1,t2] [--json]
//   agneta-diag [--home <dir>] tail [-f] <task> [--json]
//   agneta-diag [--home <dir>] summary <task>
//   agneta-diag [--home <dir>] export <task> --out <file> [--redact-content]
//   agneta-diag [--home <dir>] log [--lines <n>] [--errors]
//
// <task> may be any unique prefix of a task id. The home defaults to $AGNETA_HOME,
// else Agneta's Application Support folder (the release one if present, else development).
import AgnetaKit
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agneta-diag: \(message)\n".utf8))
    exit(1)
}

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

let givenHome = option("--home") ?? ProcessInfo.processInfo.environment["AGNETA_HOME"]
let home: URL = {
    if let path = givenHome { return URL(filePath: path, directoryHint: .isDirectory) }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let release = support.appending(path: "com.objectivecoder.agneta", directoryHint: .isDirectory)
    return FileManager.default.fileExists(atPath: release.path(percentEncoded: false))
        ? release : support.appending(path: "com.objectivecoder.agneta.dev", directoryHint: .isDirectory)
}()
let store = AgnetaStore(root: home)
let traces = Traces(folder: store.tracesFolder)

@MainActor func resolve(_ prefix: String) -> String {
    let names =
        (try? FileManager.default.contentsOfDirectory(atPath: store.tracesFolder.path(percentEncoded: false))) ?? []
    let matches = names.filter { $0.hasSuffix(".jsonl") && $0.hasPrefix(prefix) }.map { String($0.dropLast(6)) }
    if matches.count == 1 { return matches[0] }
    fail(
        matches.isEmpty
            ? "no trace starts with \(prefix) in \(store.tracesFolder.path(percentEncoded: false))"
            : "\(prefix) matches \(matches.count) traces")
}

@MainActor func records(_ task: String) -> [JSONValue] {
    guard let text = try? String(contentsOf: traces.file(for: task), encoding: .utf8) else {
        fail("can't read the trace of \(task)")
    }
    return text.split(separator: "\n").compactMap { try? JSONCoding.decode(Data($0.utf8)) }
}

@MainActor func json(_ value: JSONValue) -> String {
    let data = (try? JSONCoding.encode(value)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

@MainActor func short(_ value: JSONValue?, _ limit: Int = 120) -> String {
    guard let value, value != .null else { return "" }
    let text = value.stringValue ?? json(value)
    let flat = text.replacingOccurrences(of: "\n", with: "⏎")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
}

@MainActor func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .double(let v)?: v
    case .int(let v)?: Double(v)
    default: nil
    }
}

/// One record as one readable line: seconds since the task started, turn, what happened.
@MainActor func describe(_ record: JSONValue) -> String {
    let seconds = String(format: "%9.3f", Double(record["mono"]?.intValue ?? 0) / 1e9)
    let turn = "t\(record["turn"]?.intValue ?? 0)"
    let type = record["type"]?.stringValue ?? "?"
    let detail: String
    switch type {
    case "event":
        let kind = record["kind"]?.stringValue ?? "?"
        switch kind {
        case "tool-call":
            detail = "tool-call \(short(record["call"])) \(short(record["name"], 40)) \(short(record["input"]))"
        case "tool-result":
            detail =
                "tool-result \(short(record["call"])) \(short(record["status"])) \(Int(number(record["ms"]) ?? 0)) ms \(short(record["content"], 80))"
        case "model-call":
            detail =
                "model-call #\(short(record["n"])) \(short(record["model"])) in \(short(record["input"])) out \(short(record["output"])) cache \(short(record["cacheRead"]))/\(short(record["cacheWrite"]))"
        case "turn":
            detail =
                "turn \(short(record["n"])) \(short(record["stopReason"])) \(Int(number(record["ms"]) ?? 0)) ms, first token \(Int(number(record["msToFirstToken"]) ?? 0)) ms, \(short(record["modelCalls"])) model calls"
        case "prompt": detail = "prompt \(short(record["prompt"]))"
        case "text-delta", "thinking-delta": detail = "\(kind) \(short(record["delta"]))"
        default:
            detail =
                "\(kind) \(short(.object((record.objectValue ?? [:]).filter { !TraceRecordKeys.header.contains($0.key) && $0.key != "kind" })))"
        }
    case "acp":
        detail =
            "acp \(short(record["leg"])) \(short(record["msg"]?["method"] ?? (record["msg"]?["result"] != nil ? "result" : "error"), 60))"
    case "shell":
        detail =
            "shell exit \(short(record["exit"] ?? record["signal"])) \(Int(number(record["ms"]) ?? 0)) ms \(short(record["command"]))"
    case "permission":
        detail = "permission \(short(record["decision"])) \(short(record["toolKind"])) \(short(record["title"], 60))"
    case "result":
        detail =
            "result \(short(record["event"])) \(short(record["name"] ?? record["tool"])) \(short(record["answer"] ?? record["report"]?["status"] ?? .null))"
    case "lifecycle":
        detail =
            "lifecycle \(short(record["event"])) \(short(.object((record.objectValue ?? [:]).filter { !TraceRecordKeys.header.contains($0.key) && $0.key != "event" })))"
    case "meta":
        detail =
            "meta \(short(record["app"]?["name"])) on \(short(record["account"]?["label"])) (\(short(record["account"]?["billing"]))), engine \(short(record["engine"]?["info"]?["version"]))"
    case "engine.usage":
        detail =
            "engine.usage \(short(record["model"])) in \(short(record["input_tokens"])) out \(short(record["output_tokens"]))"
    case "engine.message": detail = "engine.message \(short(record["role"])) \(short(record["content"], 100))"
    default:
        detail =
            "\(type) \(short(.object((record.objectValue ?? [:]).filter { !TraceRecordKeys.header.contains($0.key) })))"
    }
    return "\(seconds)  \(turn)  \(detail)"
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }

enum TraceRecordKeys { static let header: Set<String> = ["v", "seq", "t", "mono", "task", "turn", "type"] }

@MainActor func summary(_ task: String) {
    let all = records(task)
    let s = TraceSummary(records: all)
    func n(_ value: Double?) -> String { value.map { String(Int($0)) } ?? "?" }
    print("Task \(task): \(s.app ?? "?") on \(s.account ?? "?") (\(s.billing ?? "?"))")
    print(
        "Engine \(s.engine ?? "?"), \(s.dedicated ? "dedicated" : "shared"), policy \(s.tools ?? "?") / network \(s.network ?? "?")"
    )
    print("\nTurns")
    for turn in s.turns {
        print(
            "  \(turn.n)  \(turn.stopReason)  \(n(turn.ms)) ms (first token \(n(turn.msToFirstToken)) ms)  \(turn.modelCalls) model calls  in \(turn.input) out \(turn.output) cache \(turn.cacheRead)/\(turn.cacheWrite)  cost \(turn.cost.map { String(format: "$%.4f", $0) } ?? "unknown")\(turn.error.map { "  error: \(short(.string($0)))" } ?? "")"
        )
    }
    print(
        "\nTool calls (\(s.toolCalls)\(s.unfinishedToolCalls > 0 ? ", \(s.unfinishedToolCalls) without a result" : ""))"
    )
    for tool in s.toolStats {
        print(
            "  \(tool.name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(tool.calls)×  errors \(tool.errors)  total \(Int(tool.totalMs)) ms  p95 \(Int(tool.p95Ms)) ms"
        )
    }
    print(
        "\nModel calls: \(s.modelCalls)  input \(s.input)  output \(s.output)  cache read \(s.cacheRead)  cache write \(s.cacheWrite)  compactions \(s.compactions)"
    )
    print("Shell commands: \(s.shellCommands)  non-zero exits \(s.shellFailures)  refused \(s.shellRefused)")
    let decisions = s.permissions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("Permissions: \(s.permissions.values.reduce(0, +)) \(decisions.isEmpty ? "" : "(\(decisions))")")
    if !s.results.isEmpty {
        print("\nStructured results")
        for result in s.results {
            print(
                "  turn \(result.turn)  \(result.name)  \(result.status)\(result.reason.map { " (\($0))" } ?? "")  \(result.attempts) attempts, \(result.refused) refused"
            )
        }
    }
    if !s.lifecycle.isEmpty {
        print("\nLifecycle")
        for record in s.lifecycle { print("  " + describe(record)) }
    }
    print("\n\(s.records) records\(s.ended ? ", ended" : ", still open")")
}

guard let command = arguments.first else {
    print(
        "usage: agneta-diag [--home <dir>] tasks | show <task> | tail [-f] <task> | summary <task> | export <task> --out <file> [--redact-content] | log [--lines <n>] [--errors]"
    )
    exit(2)
}
arguments.removeFirst()

switch command {
case "tasks":
    let limit = Int(option("--limit") ?? "30") ?? 30
    let history: [TaskRecord], ended: Set<String>
    do {
        let database = try AgnetaDatabase(reading: store.databaseFile)
        history = try database.history(limit: limit)
        ended = try database.endedTaskIDs()
    } catch {
        fail("can't read \(store.databaseFile.path(percentEncoded: false)): \(error)")
    }
    let names =
        (try? FileManager.default.contentsOfDirectory(atPath: store.tracesFolder.path(percentEncoded: false))) ?? []
    let running = names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.filter { !ended.contains($0) }
    for id in running { print("\(id)  running or unfinished") }
    for task in history {
        let formatter = ISO8601DateFormatter()
        let trace = names.contains("\(task.id).jsonl") ? "" : "  (no trace)"
        print(
            "\(task.id)  \(formatter.string(from: task.started))  \(task.app)  \(task.title)  \(task.outcome?.rawValue ?? "?")  \(task.turns) turns\(task.cost.map { String(format: "  $%.4f", $0) } ?? "")\(trace)"
        )
    }
case "show":
    let types = option("--types").map { Set($0.split(separator: ",").map(String.init)) }
    let asJSON = flag("--json")
    guard let prefix = arguments.first else { fail("show needs a task") }
    for record in records(resolve(prefix))
    where types == nil || types!.contains(record["type"]?.stringValue ?? "")
        || types!.contains(record["kind"]?.stringValue ?? "")
    {
        print(asJSON ? json(record) : describe(record))
    }
case "tail":
    let follow = flag("-f")
    let asJSON = flag("--json")
    guard let prefix = arguments.first else { fail("tail needs a task") }
    let file = traces.file(for: resolve(prefix))
    guard let handle = try? FileHandle(forReadingFrom: file) else {
        fail("can't read \(file.path(percentEncoded: false))")
    }
    var splitter = LineSplitter(limit: 64 << 20)
    var ended = false
    do {
        while true {
            guard let data = try handle.read(upToCount: 64 << 10), !data.isEmpty else {
                if !follow || ended { break }
                usleep(200_000)
                continue
            }
            for line in try splitter.push(data) {
                guard let record = try? JSONCoding.decode(line) else { continue }
                print(asJSON ? String(decoding: line, as: UTF8.self) : describe(record))
                ended = record["type"]?.stringValue == "end"
            }
            if data.last != 0x0A { ended = false } // another record is still being written
            fflush(stdout)
        }
    } catch {
        fail("can't read \(file.path(percentEncoded: false)): \(error)")
    }
case "log":
    let lines = Int(option("--lines") ?? "50") ?? 50
    let errorsOnly = flag("--errors")
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let folder =
        givenHome != nil
        ? home.appending(path: "Logs", directoryHint: .isDirectory)
        : library.appending(
            path: home.lastPathComponent.hasSuffix(".dev") ? "Logs/Agneta Dev" : "Logs/Agneta",
            directoryHint: .isDirectory)
    var tail = OperationalLog(folder: folder).tail(errorsOnly ? 100_000 : lines)
    if errorsOnly { tail = Array(tail.filter { $0.contains(#""level":"error""#) }.suffix(lines)) }
    print(tail.isEmpty ? "Nothing logged in \(folder.path(percentEncoded: false))." : tail.joined(separator: "\n"))
case "summary":
    guard let prefix = arguments.first else { fail("summary needs a task") }
    summary(resolve(prefix))
case "export":
    guard let out = option("--out") else { fail("export needs --out <file>") }
    let redactContent = flag("--redact-content")
    guard let prefix = arguments.first else { fail("export needs a task") }
    let task = resolve(prefix)
    let target = URL(filePath: out)
    do { try TraceExport.write(trace: traces.file(for: task), to: target, redactContent: redactContent) } catch {
        fail("can't write \(out): \(error.localizedDescription)")
    }
    print("Wrote \(target.path(percentEncoded: false))\(redactContent ? " (content removed)" : "")")
default:
    fail("unknown command \(command)")
}
