# Diagnostics: full insight into every task

An app that runs AI work through Agneta must see at least as much as it would by running the agent itself: every message, every tool call with its full input and result, every model call with its usage, the timing of each, and every decision Agneta made on the way. A gateway that hides this would make the app worse at its job, and nobody could review a run afterwards.

So Agneta writes **one trace per task** and lets three kinds of reader at it:

| Reader | How | Sees |
| --- | --- | --- |
| The app that ran the task | The ACP extension `agneta/trace`, live and afterwards ([APP_PROTOCOL.md](APP_PROTOCOL.md#the-trace)) | Its own tasks only |
| Agents and tools (a coding agent debugging a run, a developer) | The diagnostics MCP server, with a token the user creates | Every task |
| People and scripts | The files, through `agneta-diag` | Every task |

Why not files alone: a sandboxed app can't read Agneta's files, and files give no scoping per app. Why not MCP alone: the owning app already holds an ACP connection, identity and grant, so a second connection and credential would add nothing.

Two kinds of record stay apart:
- **Task traces** hold content (prompts, tool input and output), because that's their purpose. They're local, owner-only (mode 0600), kept as long as task history, and deleted by Clear History and Reset.
- **Agneta's operational log** holds event names, ids, counts and timing, never content. Its job is to debug Agneta itself.

## The task trace, `agneta/trace`

One JSON Lines file per task: `Traces/<task id>.jsonl` in Agneta's Application Support folder.

Every line has these fields:

| Field | Meaning |
| --- | --- |
| `v` | Format version, 1 |
| `seq` | Gapless per task, from 1. File order is sequence order |
| `t` | Wall time, ISO 8601 UTC with microseconds |
| `mono` | Nanoseconds since the trace was opened (or resumed), monotonic |
| `task` | Agneta's session id |
| `turn` | 0 before the first prompt, then the turn number |
| `type` | The record type, below |

**Secrets are masked before writing:** the app's pairing token and its MCP header values by exact value; `sk-…` keys, bearer values and JWTs by shape; and fields named like `authorization`, `token`, `api_key`, `password` or `secret`, at any depth.

### Record types

| `type` | Fields | Source |
| --- | --- | --- |
| `meta` | app (name, identifier, verified, grant), account (id, label, kind, billing: `api-key` or `subscription`, runner), engine (id, `stateFormat`, name and version, pid, dedicated, start time, engine session), policy (tools, network, approval, folders, `sandbox`: the mode the task ran in, and `toolEnvironment`: the names of the variables the app set for commands, never their values; `builtins`: the groups of the engine's own tools the app kept, null for no narrowing, and `builtinsOffered`: those the session has, null when not known), the `session/new` request, the engine's result, instructions | Agneta at `session/new` |
| `config` | method, request, `by` | Model, option and instruction changes |
| `acp` | `leg` (`app→agneta`, `agneta→engine`, `engine→agneta`, `agneta→app`), `msg`: the JSON-RPC message exactly as received | Both connections |
| `event` | Normalized, below | Derived from the ACP stream and the engine's records |
| `engine.message` | A message as the model saw it: role, content, meta, created | The engine's own records (Goose, OpenCode) |
| `engine.usage` | One row per model call: model, input, output, cache read and write tokens, cost, cost source, compaction | The engine's own records or stream |
| `permission` | engine call id, tool kind, title, decision (`asked-app`, `allowed-by-policy`, `refused-by-policy`, `cancelled`), answer, ms | Agneta's router |
| `shell` | command, cwd, exit code or signal, ms, stdout and stderr bytes, the end of stderr, or why it was refused | Agneta's tool broker |
| `stderr` | One line of the engine's stderr (dedicated engines) | The engine |
| `lifecycle` | `engine-start` (pid, ms to initialize), `engine-exit` (code or signal), `queued` (with `waitingFor`: `app`, `account` or `agneta`), `dequeued`, `queue-cancelled`, `queue-paused`, `stop` (by `user`, `app`, `engine` or `agneta` when it quits, with the reason), `steer` (delivery), `limit` (with `setBy`: `app` for the policy's, `user` for the app's spending limit), `app-limit` (the app's spending limit reached: `limit`, `max`, `used`), `unpriced` (a turn on an API key whose model calls had no price, so the app's spending limit didn't count it: `modelCalls`), `limit-enforced`, `resumed`, `resume-failed`, `forked`, `dropped`, `trace-truncated`, `trace-full`, `engine-db-unavailable`, `engine-records-limited` (a reader of the engine's records hit one of its limits, with why: Claude Code's transcript) | Agneta |
| `end` | No fields; the outcome is in Agneta's task history | Agneta |

### Normalized events

`event` records carry a `kind`, so a reader needs no knowledge of each engine's stream:

| `kind` | Fields |
| --- | --- |
| `init` | model, config options, MCP servers, the engine's extension results, engine name and version |
| `prompt` | `n`, the full prompt |
| `text-delta`, `thinking-delta` | message id, delta |
| `tool-call` | `call` (task-scoped id, `c1`, `c2`, …), `engineCall`, `tool` and `extension` (the tool's own name and the server it came from), `message` (the model response id, when known), `name` (the engine's title, which may carry arguments), `toolKind`, full `input`, `tStart` |
| `tool-input` | `call`, and input or name that arrived after the first sighting (ACP updates are upserts) |
| `tool-result` | `call`, status, `isError`, full `content` and `rawOutput`, `tEnd`, `ms`, `bytes`, `estTokens` |
| `model-call` | `n` (per task), model, input, output, cacheRead, cacheWrite, cost, `costKind` (`estimated` or `plan-equivalent`), `costSource`, compaction, `outputPartial` (Claude Code: `false` when the output count is final, `true` when it's the stream's opening count), `basis` (`engine-ledger`; on Claude Code `engine-transcript`, or `engine-stream` when the transcript didn't give the call in time or isn't there; [ENGINES.md](ENGINES.md#claude-code)), `taskCost` (the task's known cost so far) |
| `usage` | Context `size` and `used`, **marked cumulative**, with the engine's cost when it sends one |
| `plan` | The engine's plan entries |
| `turn` | `n`, stopReason, `ms`, `msToFirstToken`, `modelCalls`, `ledger` (input, output, cacheRead, cacheWrite), `callLedger` (the per-call sums, when `ledger` holds the engine's own turn totals), `basis`, the engine's own `usage`, `cost`, `taskCost`, `models`, `costKind`, `error` |
| `rate-limited` | account, the provider's message, `resetsAt` |

Rules the format keeps:
- **Ids are task-scoped.** Engine ids can repeat across turns and processes, so `call` is Agneta's own, with the engine's id beside it.
- **Usage comes from the engine's own records, never from counting stream items.** Cumulative values are labelled as cumulative.
- **Every tool, built-in or app MCP, gets `tStart` and `tEnd`,** and shell commands also get the broker's exact timing.
- **Unknown stays unknown.** Nothing is estimated silently, and the cost kind is always stated.

### Writing

- **Writing never blocks a turn.** Each task has one writer with its own serial queue. Records are numbered as they're written, in the order they were recorded, so file order is sequence order and numbers have no gaps; masking and encoding happen on the writer's queue.
- **Under pressure, droppable records go first:** raw `acp` frames, text and thinking deltas, and engine stderr, when 20,000 records wait or the task passes 200 MB (`trace-truncated` notes it).
- **At 1 GB a task's trace is full:** nothing more is written but its `end` (`trace-full` notes it). Skipped records are counted in a `dropped` record at the next turn's end, or just before the task's `end`, which is always the last record.
- **A record over 16 MB** (a huge tool output) is written as a stub that keeps what identifies it (`kind`, `call`, `tool`, `status`, …) and `oversize`, its size in bytes.
- **A trace that can't be written** (the disk is full, the file is gone) stops rather than skip silently: Agneta logs `trace-write-failed`, and its menu says that task records are incomplete.
- **On resume,** `seq`, `turn`, the model-call `n` and `taskCost` continue, while `mono` starts again from zero.
- The file is synced at least once a second while records arrive, and at each turn end.
- Engine records are read from the engine's own files, read-only, at each turn end and every 2 seconds while a turn runs. If they can't be read (an engine version with another schema), the trace says so once (`engine-db-unavailable`) and continues without them.

## The diagnostics MCP server

Streamable HTTP (JSON responses) at `http://127.0.0.1:47323/mcp`, two above the apps' port (development builds: 47333), on a listener of its own.

- **Off until the user creates a token** under Settings → Advanced → Diagnostics, which can also copy a ready-made `claude mcp add` command and replace or revoke the token. Every request needs `Authorization: Bearer <token>`. The token is kept in the Keychain.
- **Browser requests** (any request with an `Origin` header) are refused.
- At most 16 connections, each closed after 10 seconds, with request bodies up to 1 MB.

Tools return compact text by default, and JSON with `json: true`. A task can be named by any unique prefix of its id.

| Tool | Returns |
| --- | --- |
| `list_tasks(app?, limit?, json?)` | Tasks with traces, newest first: id, app, title, account, start, turns, whether it ended |
| `task_summary(task, json?)` | Turns with time, model calls and tokens; tools by total time, with failures and p95; model usage; shell commands; permission decisions; lifecycle |
| `tool_calls(task, name?, errors_only?, turn?, full?, json?)` | Each call's input, result, status and exact timing; input and result cut to 2,000 characters unless `full` |
| `model_calls(task, turn?, json?)` | Model calls from the engine's records: model, tokens, cost, compaction |
| `read_trace(task, after?, types?, limit?)` | Trace records after a sequence number, filtered by type; raw ACP frames only when `types` includes `acp` |
| `tail(task, after, wait_ms?)` | Waits up to `wait_ms` (at most 8,000, under the server's 10 s per connection) for new records of a running task; call again to keep following |
| `engine_log(task, lines?)` | The end of the engine's own log, for a task with a dedicated engine |
| `agneta_log(lines?, errors_only?)` | The end of Agneta's operational log |

Every token sees every task. Limiting a token to chosen apps isn't supported yet.

## `agneta-diag`

A command-line reader bundled in the app at `Contents/MacOS/agneta-diag`:

```text
agneta-diag [--home <dir>] tasks [--limit <n>]
agneta-diag [--home <dir>] show <task> [--types t1,t2] [--json]
agneta-diag [--home <dir>] tail [-f] <task> [--json]
agneta-diag [--home <dir>] summary <task>
agneta-diag [--home <dir>] export <task> --out <file> [--redact-content]
agneta-diag [--home <dir>] log [--lines <n>] [--errors]
```

- The data folder defaults to `$AGNETA_HOME`, else Agneta's Application Support folder (the release build's when it exists, else the development build's).
- Tasks can be named by any unique id prefix.
- `export --redact-content` writes the trace as one owner-only file for a bug report. It's an allow-list: content-bearing fields (prompts, deltas, tool input and output, titles, instructions, error text) are replaced by their size, and then a string stays only where it's structural (record types and kinds, statuses, decisions, model and engine names). App and account names, identifiers and paths are replaced by their size too, and tool and server names become tokens that are the same within one export and different in the next. Timings, sizes, counts, tokens and costs stay ([PRIVACY.md](PRIVACY.md#sharing-a-trace)).

Settings → Activity shows each task's summary and timeline, and exports the same files.

## Agneta's operational log

`~/Library/Logs/Agneta/agneta.jsonl` (development builds: `Logs/Agneta Dev`): JSON lines of what Agneta itself did, such as starts, pairing, tasks, limits (`app-limit-reached`, `app-limits-changed`), sign-in and reset. Ids, names, counts and timing only, never prompts, tool content, tokens or keys; values are masked again on write. Rotated by size and kept 7 days.

## Retention

- Traces follow task history: 30 days by default, or a week, 90 days or none, set in Settings → Privacy. History is pruned at launch and daily.
- Clear History and Reset delete traces, along with the engine homes that held those tasks' conversations, and Claude Code's transcripts and Codex's session files of those tasks.
- A dedicated engine's stderr goes to `engine.log` in its engine home, kept under 1 MB.
- A total cap across all traces isn't supported yet: each task's trace is capped at 1 GB, and history retention bounds how many are kept.
