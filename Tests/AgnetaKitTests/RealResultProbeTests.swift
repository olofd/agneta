// Structured results on real models (manual), the numbers behind docs/ENGINES.md's structured results:
//   AGNETA_REAL_PROBE_RESULTS=1 AGNETA_REAL_PROBE_HOME=<folder> swift test --filter realResultProbe
// Runs a fixed corpus (a flat object, a nested invoice with an array, an enum and a nullable field, and a schema with a
// pattern and bounds a model has to work to meet) through Agneta's whole stack on each account and model, a few times
// each, and prints per run: the outcome, attempts, model calls, time and tokens; then a summary per configuration.
// The sign-ins are the real probe's (RealProbeTests). AGNETA_REAL_PROBE_RUNS=<n> runs each case n times (default 3);
// AGNETA_REAL_PROBE_ACCOUNTS=codex,claude-direct,claude picks accounts, AGNETA_REAL_PROBE_CASES=invoice,… cases;
// AGNETA_REAL_PROBE_KEEP=<folder> writes every run as JSON lines there, and the tasks' traces (each attempt's issues
// are in their result records) in its Traces folder. It uses your plans' limits.
import AgnetaFakes
import Foundation
import Testing

@testable import AgnetaKit

enum ResultCorpus {
    struct Case: Sendable {
        var name: String
        var schema: JSONValue
        var prompt: String
        /// What a correct value must say, checked after Agneta's validation (which only says it's well-formed).
        var check: @Sendable (JSONValue) -> Bool
    }

    static let cases: [Case] = [
        Case(
            name: "contact",
            schema: [
                "type": "object",
                "properties": ["name": ["type": "string"], "email": ["type": "string"], "company": ["type": "string"]],
                "required": ["name", "email"], "additionalProperties": false
            ],
            prompt: """
                Extract the sender's contact details from this email.

                Hi! Thanks for the call yesterday. Talk soon,
                Ada Lovelace
                Analytical Engines Ltd · ada@analytical.example
                """,
            check: { $0["name"]?.stringValue?.contains("Ada") == true && $0["email"] == "ada@analytical.example" }),
        Case(
            name: "invoice",
            schema: [
                "type": "object",
                "properties": [
                    "number": ["type": "string"],
                    "status": ["enum": ["draft", "sent", "paid"]],
                    "due": ["type": ["string", "null"], "description": "ISO date, or null when not stated"],
                    "lines": [
                        "type": "array", "minItems": 1,
                        "items": [
                            "type": "object",
                            "properties": ["text": ["type": "string"], "amount": ["type": "number"]],
                            "required": ["text", "amount"], "additionalProperties": false
                        ]
                    ],
                    "total": ["type": "number"]
                ],
                "required": ["number", "status", "due", "lines", "total"], "additionalProperties": false
            ],
            prompt: """
                Turn this into an invoice record.

                Invoice A-1042, already paid. Mixing: 400. Mastering: 150.50. No due date given.
                """,
            check: {
                $0["number"] == "A-1042" && $0["status"] == "paid" && $0["due"] == .null
                    && $0["lines"]?.arrayValue?.count == 2 && JSONNumber.compare($0["total"] ?? 0, 550.5) == 0
            }),
        Case(
            name: "constrained",
            schema: [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "pattern": "^[A-Z]{3}-\\d{4}$"],
                    "score": ["type": "integer", "minimum": 1, "maximum": 5],
                    "tags": [
                        "type": "array", "items": ["type": "string", "maxLength": 12], "maxItems": 3,
                        "uniqueItems": true
                    ]
                ],
                "required": ["code", "score", "tags"], "additionalProperties": false
            ],
            prompt: """
                Make a review record for this: product code abc 7 (the code is three capital letters, a dash and four \
                digits, so pad the number), rated "excellent, five stars", about sound, mixing, warmth and price.
                """,
            check: { $0["code"] == "ABC-0007" && $0["score"] == 5 })
    ]
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AGNETA_REAL_PROBE_RESULTS"] != nil))
func realResultProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    let home = try #require(
        env["AGNETA_REAL_PROBE_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) },
        "Set AGNETA_REAL_PROBE_HOME to the folder holding the probe's sign-ins")
    let runs = Int(env["AGNETA_REAL_PROBE_RUNS"] ?? "") ?? 3
    let root = FileManager.default.temporaryDirectory.appending(
        path: "agneta-real-results-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory
    ).realFileURL
    try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let traces = Traces(folder: root.appending(path: "agneta/Traces", directoryHint: .isDirectory))
    let (router, supervisor) = try await realProbeStack(home: home, root: root, traces: traces)
    let server = try WebSocketServer(port: 47498)
    try await server.start()
    defer { server.stop() }
    Task { for await connection in server.connections { Task { await router.serve(connection) } } }
    AppClient.register(scope: root.appending(path: "work", directoryHint: .isDirectory), port: 47498)
    let app = AppClient(port: 47498)
    defer { app.close() }
    try await app.pairAndInitialize("Results probe")
    let keep = env["AGNETA_REAL_PROBE_KEEP"].map { URL(filePath: $0) }
    let only = env["AGNETA_REAL_PROBE_ACCOUNTS"].map { Set($0.split(separator: ",").map(String.init)) }
    let cases = env["AGNETA_REAL_PROBE_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
    // Only Luna, Terra and Sonnet (the maintainer's choice for real-model tests).
    let configurations: [(account: String, model: String)] = [
        ("codex", "luna"), ("codex", "terra"), ("claude-direct", "sonnet"), ("claude", "sonnet")
    ]
    var summary: [String: [String]] = [:]
    for (account, wanted) in configurations where only?.contains(account) ?? true {
        for corpus in ResultCorpus.cases where cases?.contains(corpus.name) ?? true {
            for run in 1...runs {
                let label = "\(account)/\(wanted)/\(corpus.name)#\(run)"
                do {
                    let created = try await app.request(
                        "session/new",
                        [
                            "cwd": .string(root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                            "_meta": [
                                "agneta": [
                                    "account": .string(account),
                                    "engine": account == "claude-direct" ? "claude-code" : .null
                                ],
                                SessionPolicy.key: ["tools": "app-only", "approval": "never-ask"],
                                "agneta/result": ["schema": corpus.schema]
                            ]
                        ])
                    let session = try #require(created["sessionId"]?.stringValue)
                    let options =
                        created["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }?["options"]?
                        .arrayValue ?? []
                    guard
                        let pick = options.compactMap({ $0["value"]?.stringValue }).first(where: {
                            $0.lowercased().contains(wanted)
                        })
                    else {
                        print(
                            "RESULTS \(label) skipped: no \(wanted) among",
                            options.compactMap { $0["value"]?.stringValue })
                        _ = try? await app.request("session/close", ["sessionId": .string(session)])
                        break
                    }
                    _ = try await app.request(
                        "session/set_config_option",
                        ["sessionId": .string(session), "configId": "model", "value": .string(pick)])
                    let started = ContinuousClock.now
                    let reply = try await app.prompt(session, corpus.prompt)
                    let elapsed = ContinuousClock.now - started
                    let result = reply["_meta"]?["agneta/result"] ?? .null
                    let usage = reply["_meta"]?["agneta/usage"] ?? .null
                    let status = result["status"]?.stringValue ?? "none"
                    let correct = status == "valid" && corpus.check(result["value"] ?? .null)
                    let line =
                        "\(status)\(status == "missing" ? "(\(result["reason"]?.stringValue ?? "?"))" : "")"
                        + " attempts=\(result["attempts"]?.intValue ?? 0) correct=\(correct)"
                        + " calls=\(usage["modelCalls"]?.intValue ?? 0) in=\(usage["inputTokens"]?.intValue ?? 0)"
                        + " cached=\(usage["cacheReadTokens"]?.intValue ?? 0)+\(usage["cacheWriteTokens"]?.intValue ?? 0)"
                        + " out=\(usage["outputTokens"]?.intValue ?? 0) ms=\(Int(elapsed / .milliseconds(1)))"
                    print("RESULTS \(label) [\(pick)]", line)
                    summary["\(account)/\(wanted)/\(corpus.name)", default: []].append(line)
                    if let keep {
                        let record: JSONValue = [
                            "label": .string(label), "model": .string(pick), "result": result, "usage": usage,
                            "correct": .bool(correct), "stopReason": reply["stopReason"] ?? .null
                        ]
                        let data = try JSONCoding.encode(record) + Data("\n".utf8)
                        let file = keep.appending(path: "results.jsonl")
                        if let handle = try? FileHandle(forWritingTo: file) {
                            handle.seekToEndOfFile()
                            handle.write(data)
                            try? handle.close()
                        } else {
                            try data.write(to: file)
                        }
                    }
                    _ = try await app.request("session/close", ["sessionId": .string(session)])
                } catch {
                    print("RESULTS \(label) failed:", error)
                    summary["\(account)/\(wanted)/\(corpus.name)", default: []].append("error")
                }
            }
        }
    }
    for key in summary.keys.sorted() {
        let lines = summary[key]!
        let valid = lines.filter { $0.hasPrefix("valid") }.count
        let correct = lines.filter { $0.contains("correct=true") }.count
        let first = lines.filter { $0.hasPrefix("valid attempts=1 ") }.count
        print("RESULTS SUMMARY \(key): valid \(valid)/\(lines.count), first attempt \(first), correct \(correct)")
    }
    await supervisor.stopAll()
    if let keep {
        try? FileManager.default.copyItem(
            at: root.appending(path: "agneta/Traces"), to: keep.appending(path: "Traces-\(UUID().uuidString.prefix(6))")
        )
    }
}
