# Agneta

**Give Mac apps an AI agent you control.**

Agneta is an open-source macOS menu bar app. You connect the AI accounts you already have once: a ChatGPT or Claude plan, or an OpenAI or Anthropic API key. Then you decide which apps may use them. When an allowed app needs an AI agent to do some work, it asks Agneta. Agneta runs the agent on your Mac, in a sandbox, on your account, and shows you every task with a stop button.

For app developers, this means agent features without running an agent loop, building sign-in for every provider, or putting a model bill on your own credit card. Your app speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP) to Agneta over a local WebSocket, and Agneta does the rest.

<p align="center">
  <img src="docs/images/panel.png" width="340" alt="Agneta's menu bar panel: two running tasks from Example App, and three connected accounts">
  &nbsp;&nbsp;
  <img src="docs/images/approval.png" width="400" alt="An app asks to use Agneta; the user picks which accounts it may use">
</p>

> **Status: early, and built from source only.** Agneta runs real tasks on real ChatGPT and Claude plans. Before you rely on it, know that:
> - there's no signed or notarized release yet, so you build it yourself;
> - the app protocol may still change;
> - an engine can reach any HTTPS host, not only its provider's (a per-provider host allowlist isn't built yet);
> - it's tested on Intel Macs with macOS 26; Apple silicon and macOS 14 and 15 are untested.

## What it is

- **A local agent runtime that apps share.** An app sends a task: a workspace folder, its own tools (an MCP server), instructions and limits. Agneta runs an agent engine on it and streams back ACP updates, usage and a full trace.
- **An account manager.** It handles sign-in for ChatGPT and Claude plans through your own Codex's and Claude Code's logins, so Agneta never holds a plan's tokens. API keys stay in your Keychain. One account can serve several apps, and every task shows which app it belongs to, which account it runs on and what it costs.
- **A consent layer.** An app has to pair before it can do anything. You approve it in a window that shows whether its code signature checks out and what it will be able to do (its tools and folders), and you choose which accounts it may use, once or always. You can see and stop every task, and remove an app's access at any time.
- **A sandbox.** Every engine runs under a macOS sandbox profile. It can read the task's workspace, the folders the policy names and what the engine itself needs, and nothing else in your home folder. The engine itself can reach any HTTPS host, which is how it reaches its provider. Shell commands run under an even stricter profile, confined to the workspace with no network (engines that run their own shells aren't allowed to run commands while a task has no network). [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#sandbox-profiles) lists exactly what each part can reach.
- **A flight recorder.** Every task leaves a structured trace: prompts, tool calls, model calls, permission decisions and timing. You read it with the `agneta-diag` command-line tool or an optional local MCP server. Apps can read their own tasks' traces live.

## What it is not

- **Not a model proxy.** Agneta doesn't hand apps an OpenAI-compatible endpoint backed by your subscription. Apps get agent tasks, run under rules you can see, not raw model access.
- **Not a chat app.** There's no chat window. The apps you use are the interface.
- **Not a way around provider terms.** Agneta uses your own accounts and your own installed Claude Code and Codex. Whether a given use fits a provider's terms is between you and that provider. See [docs/TERMS.md](docs/TERMS.md).
- **Not a coding agent of its own.** It hosts proven open-source and vendor agents ([Goose](https://github.com/aaif-goose/goose), [OpenCode](https://github.com/anomalyco/opencode), Claude Code and Codex) behind one boundary.
- **Not a service.** Everything listens on loopback only and browsers are refused. Agneta has no servers of its own and sends no telemetry; engines talk to their AI provider, with their own analytics and update checks turned off where they allow it.

## What it's for

**Apps that want an agent but not a backend.** A music tool that lets an agent tune a model against its own renders, a notes app that summarizes and files, a research tool that reads a folder of papers. The app keeps its own tools and data and exposes them as an MCP server on loopback. Agneta runs the agent loop with those tools, on the user's account, inside a policy the app declares and the user can see.

**People who already pay for an AI plan.** You can use that plan in the apps you choose, see what each one does with it, and stop it.

## How it works

```
 Your app ──ACP over ws://127.0.0.1──▶ Agneta ──ACP over stdio──▶ Agent engine (sandboxed)
    ▲                                    │                          │
    └──── MCP over loopback (your tools) ◀──────────────────────────┘
                                         │
                       accounts · consent · policy · limits · traces
```

1. **Pair once.** The app connects and calls `agneta/pair` with the scope it needs (tools and folders). Agneta identifies the process by its code signature; the user sees the scope, picks accounts, and allows it once or always. The app keeps a token in its Keychain.
2. **Start a session.** It calls `session/new` with a workspace, the app's MCP server and a policy, for example `{"tools": "workspace", "network": "none", "limits": {"maxTurns": 200}}`. Agneta refuses any policy it can't enforce rather than quietly weakening it.
3. **Prompt.** Agneta queues the turn within the account's limits and starts or reuses an engine under the right sandbox profile. It streams the engine's ACP updates back, answers permission requests from the policy (or asks the app), and returns usage with the result.
4. **Watch and stop.** The task appears in the menu bar panel, its trace is written as it runs, and the user can stop it at any time.

Plain ACP works unchanged. Agneta's own extensions (`agneta/policy@1`, `agneta/usage@1`, `agneta/steer@1`, `agneta/fork@1`, `agneta/trace@1` and others) are listed in `initialize`, and an app that ignores them still works.

### Accounts and engines

| Account | Engines | Sign-in |
| --- | --- | --- |
| ChatGPT plan | Codex | Your installed Codex's own login, kept per account |
| Claude plan | Claude Code, Goose | Your installed Claude Code's own login, kept per account; both engines run that Claude Code |
| OpenAI API key | Goose, OpenCode, Codex | Key in the Keychain |
| Anthropic API key | Goose, OpenCode, Claude Code | Key in the Keychain |

**Without Claude Code or Codex,** Agneta still works with an OpenAI or Anthropic API key, on the bundled Goose and OpenCode. A Claude plan needs Claude Code (the Claude desktop app includes it), and a ChatGPT plan needs Codex 0.166 or later.

Goose and OpenCode come bundled, pinned by version and SHA-256. Claude Code and Codex are your own installs: Agneta finds them, including the copy inside the Claude desktop app, and never redistributes them. Engines differ in what they can do (steering, forking, cost reporting), and Agneta exposes each one's extras instead of hiding them behind a common subset. See [docs/ENGINES.md](docs/ENGINES.md).

## Build and run

You need **Xcode 26 or later** (Swift 6.2 and the macOS 26 SDK, which the app's glass look is built with), and network access to GitHub, nodejs.org and registry.npmjs.org for the engines (about 170 MB to download the first time, about 400 MB unpacked). The app runs on macOS 14 or later; the glass look needs macOS 26.

```bash
git clone https://github.com/olofd/agneta.git && cd agneta
scripts/dev/build-app              # fetches the pinned engines, builds and signs ad hoc
open "build/Agneta Dev.app"
```

- The connected-rings symbol appears in the menu bar. Connect an account from its panel.
- To see the app side, choose **Run a Test Task** from the panel's ⋯ menu. A small sandboxed test app asks for access; once you allow it, it runs one short task and shows the reply.
- Development builds listen on `ws://127.0.0.1:47331/acp` and keep their data in `~/Library/Application Support/com.objectivecoder.agneta.dev/`. The bundle identifiers (`com.objectivecoder.agneta`, and `.dev` for development builds) use the author's developer name. They also name Agneta's data folder, Keychain items and logs, so they stay the same from release to release.
- For a throwaway instance, `AGNETA_HOME=<folder> AGNETA_PORT=<port> "build/Agneta Dev.app/Contents/MacOS/Agneta"` keeps its data, Keychain items and Reset inside that folder. Give each instance its own port (diagnostics listen two above it); one without `AGNETA_PORT`, or on your own Agneta's ports, doesn't listen and says why.

Tests:

```bash
scripts/fetch-engines --engine all  # the pinned Goose and OpenCode the integration tests run
swift build && swift test           # unit, contract and integration tests, with fake models and the real engines
AGNETA_REAL_PROBE=1 AGNETA_REAL_PROBE_HOME=<folder> swift test --filter realProbe   # optional: a real round on your own accounts
```

The integration tests run the real engines against a fake model and tool server inside the test process. Without the engines, those suites are skipped and say why. Project Chat's smoke test and the scripts in `scripts/dev` use `python3` (standard library only, as Xcode's command line tools provide) for the same fakes.

## For app developers

**Try the [Project Chat example](examples/project-chat/README.md).** This small Electron app pairs with Agneta, streams a conversation, and lets the agent propose a note for you to review.

Your app is an ACP **client** and Agneta is the ACP **agent**. If your app already speaks ACP, most of what follows is familiar. What Agneta adds is how you reach it, how the user lets your app in, and the rules a task runs under.

| | Plain ACP | With Agneta |
| --- | --- | --- |
| Transport | Usually stdio to an agent process the client starts | A WebSocket on loopback (`ws://127.0.0.1:47331/acp` for development builds), one JSON-RPC 2.0 message per text frame. Agneta is already running; your app never starts an agent |
| Who may connect | Whoever starts the process | Apps the user approved. Pairing gives your app a token, sent in `initialize` |
| Which account and model | The agent's own configuration | Accounts the user granted your app, chosen per session; models through the engine's own config options |
| What the agent may touch | Whatever the agent process can reach | A policy you send with each session (tools, folders, network, approval, limits), enforced by sandboxes, or refused |
| Afterwards | Nothing standard | Usage in every prompt result, and the task's full trace, live or later |

No SDK is needed. Any WebSocket and JSON-RPC 2.0 code will do, including in a sandboxed Mac App Store app. That needs `com.apple.security.network.client` to connect, plus `com.apple.security.network.server` if the app serves its own MCP tools; its folders come from the user (an open panel or a security-scoped bookmark), since Agneta keeps app containers out of reach ([details](docs/APP_PROTOCOL.md#connecting)). To see the whole exchange in Swift, read [`Sources/agneta-testclient/main.swift`](Sources/agneta-testclient/main.swift), the maintainers' test client: it pairs, opens a session with a policy and an MCP server, prompts and prints the stream in about 170 lines. It's a demonstration, not a client library: a real app keeps its token in the Keychain and handles reconnects.

### The conversation, step by step

**1. Connect.** Open `ws://127.0.0.1:47331/acp`, the port of development builds, which are the only kind there is today. Signed releases will listen on 47321. If the connection is refused, Agneta isn't running: ask the user to open it, and don't try to start it yourself.

**2. Pair, the first time only.** Ask to be let in, and show the user that you're waiting:

```json
→ {"jsonrpc": "2.0", "id": 1, "method": "agneta/pair",
   "params": {"name": "Example App", "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"]}}}
← {"jsonrpc": "2.0", "id": 1, "result": {"token": "…", "accounts": ["acct-1"], "workspace": "…"}}
```

The `scope` says what your app will need: the most built-in tools, and the user's folders its sessions will work in. Without one, your app gets its own tools only, in a workspace Agneta makes for it (`workspace`). Agneta opens its approval window, which shows the scope; the user picks accounts and chooses Allow Once or Always Allow. Every later session must fit the scope. If your app is signed with a Developer ID or App Store certificate, Agneta checks the signature and shows the app as verified. If it isn't (ad hoc or development builds), Agneta first sends you `agneta/pairingCode {"code": "123456"}`. Show that code; the user allows your app only if it matches the one in Agneta's window. Store the token in your Keychain. A refusal comes back as error `-32002`.

**3. Initialize, on every connection.**

```json
→ {"jsonrpc": "2.0", "id": 2, "method": "initialize",
   "params": {"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"agneta": {"token": "…"}}}}
← {"jsonrpc": "2.0", "id": 2, "result": {"protocolVersion": 1, "agentCapabilities": {…},
   "_meta": {"agneta": {"extensions": ["agneta/policy@1", "agneta/usage@1", …],
                        "accounts": [{"id": "acct-1", "label": "Claude", "paused": false, "capabilities": {…}}]}}}}
```

Error `-32001` with `needsPairing` means the user removed your app, or the token is unknown. Pair again.

**4. Start a session** in a workspace folder, with your own tools and a policy:

```json
→ {"jsonrpc": "2.0", "id": 3, "method": "session/new", "params": {
     "cwd": "/Users/me/Documents/Example Project",
     "mcpServers": [{"type": "http", "name": "app", "url": "http://127.0.0.1:52011/mcp",
                     "headers": [{"name": "Authorization", "value": "Bearer <per-session secret>"}]}],
     "_meta": {
       "agneta": {"account": "acct-1"},
       "agneta/policy@1": {"tools": "workspace", "network": "none", "approval": "never-ask",
                           "limits": {"maxTurns": 100, "maxSeconds": 900}},
       "agneta/task@1": {"title": "Tidying the project notes"},
       "agneta/instructions": {"text": "You are Example App's assistant."},
       "agneta/trace@1": {"live": true}}}}
← {"jsonrpc": "2.0", "id": 3, "result": {"sessionId": "s_…", "configOptions": […],
   "_meta": {"agneta": {"account": "acct-1", "capabilities": {"engine": "goose", "steer": true, "fork": true, …}}}}}
```

- **Your tools** are an MCP server (Streamable HTTP) that your app runs on loopback, with a fresh bearer per session. Agneta accepts only loopback HTTP servers and masks the bearer in traces. A session with its own engine may reach exactly those ports; app-only sessions on Goose share one engine per account, and OpenCode runs a private server, so those may reach any loopback port. Your tools run in your app, with your app's permissions, not inside Agneta's sandbox.
- **`tools`** is `app-only` (only your MCP tools), `read` (plus reading files) or `workspace` (plus editing and a shell confined to `cwd`).
- **A policy Agneta can't enforce is refused** with `-32602` and `data.agneta.unenforceable` naming the field. Examples: an unknown field, a folder containing the home folder, or a cost limit on an engine that can't report cost while a turn runs.
- **`capabilities`** tells you what this session's engine can do. Offer steering, forking or cost limits only where it says so.

**5. Prompt, and stream.**

```json
→ {"jsonrpc": "2.0", "id": 4, "method": "session/prompt",
   "params": {"sessionId": "s_…", "prompt": [{"type": "text", "text": "Sort these notes by topic."}]}}
← {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s_…", "update": {"sessionUpdate": "agent_message_chunk", …}}}
← {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s_…", "update": {"sessionUpdate": "tool_call", …}}}
   …
← {"jsonrpc": "2.0", "id": 4, "result": {"stopReason": "end_turn",
   "_meta": {"agneta/usage@1": {"modelCalls": 3, "inputTokens": 5120, "outputTokens": 410, "cost": null,
                                "costKind": "plan-equivalent", "billing": "subscription", "ms": 8210.4}}}}
```

The engine's standard ACP `session/update` notifications arrive unchanged, under your session id. With `"approval": "ask-app"`, tool permission requests come to you as standard `session/request_permission` requests. Answer them, and Agneta records your decision in the trace.

**6. While it runs and after.**

| You want to | Send |
| --- | --- |
| Add input to the running turn | `agneta/steer {"sessionId", "prompt"}` |
| Stop the turn | `session/cancel` (a notification) |
| Change model or effort between turns | `session/set_config_option {"sessionId", "configId", "value"}` |
| Change the instructions between turns | `agneta/instructions/set` |
| Reopen a task after a restart | `session/load` (pass your MCP servers again: bearers are per session) |
| Ask about a finished task without changing it | `agneta/fork` |
| Read the task's trace from any point | `agneta/trace/read {"sessionId", "after"}` |
| End it | `session/close` |

### Messages your app should handle

| From Agneta | Meaning, and what to show |
| --- | --- |
| `agneta/queued {"sessionId", "position"}` | The account is busy; the turn waits its place and runs later |
| `agneta/sessionStopped {"stoppedBy": "user"}` | The user pressed Stop in Agneta. Show it as stopped, not as an error |
| `agneta/sessionStopped {"stoppedBy": "engine"}` | The engine ended on its own; resume the task with `session/load` |
| `agneta/rateLimited {"account", "resetsAt"}` | The provider's limit stopped the turn. Retry after `resetsAt`, or use another account |
| Error with `data.agneta.needsSignIn` | The account must sign in again; ask the user to open Agneta |
| `-32011` | A turn is already running in this session: steer it, or wait |
| `-32012` | Too many turns are waiting; try again shortly |
| `-32013` | The user paused this account |
| `-32014` | This engine can't do that; check `capabilities` |

The full reference, with every field, limit and error, is **[docs/APP_PROTOCOL.md](docs/APP_PROTOCOL.md)**. Every step there is exercised by `Tests/AgnetaKitTests/AppScenarioTests.swift` against a real engine.

## Diagnostics

An app that hands its agent work to Agneta should see at least as much as it would by running the agent itself. So Agneta writes **one trace per task**, from the first message to the last, and lets three kinds of reader at it:

| Reader | How | Sees |
| --- | --- | --- |
| The app that ran the task | `agneta/trace@1` over its ACP connection: live notifications, or `agneta/trace/read` pages afterwards | Its own tasks only |
| An agent or a developer debugging a run | The diagnostics MCP server, once the user turns it on | Every task |
| People and scripts | `agneta-diag` on the command line, or the JSON Lines files | Every task |

**What a trace holds.** Each trace is a JSON Lines file, `Traces/<task>.jsonl` in Agneta's Application Support folder, readable by your user only. It records:
- the task's metadata (app, account, engine and version, policy);
- every prompt;
- every tool call, with its full input, result, status and exact timing;
- every model call, with its model, tokens, cache use and cost, read from the engine's own records;
- every turn's summary;
- every permission decision and who made it;
- shell commands with their exit codes;
- engine starts, stops and errors;
- optionally, the raw ACP frames of both connections.

Records are numbered without gaps and carry wall-clock and monotonic times. API keys, tokens, bearers and JWTs are masked before anything is written.

**The diagnostics MCP server** lets an agent such as Claude Code answer questions like "which tool calls failed in turn 12?" without parsing megabytes of JSON. It's off until you turn on **Allow diagnostic tools** in Settings → Advanced, which creates a token and can copy the command to add it:

```bash
claude mcp add --transport http agneta-diagnostics http://127.0.0.1:47323/mcp \
  --header "Authorization: Bearer <token>"
```

It has these tools:
- `list_tasks` and `task_summary`;
- `tool_calls`, which can be filtered to errors, one tool or one turn;
- `model_calls`;
- `read_trace` and `tail`;
- `engine_log` and `agneta_log`.

It listens on loopback only, two ports above the apps' port (47333 for development builds), and refuses browsers.

**`agneta-diag`** is bundled in the app: `"build/Agneta Dev.app/Contents/MacOS/agneta-diag"` when you built it from source. Or run `swift run agneta-diag` in the repository.

```bash
agneta-diag tasks                                         # recent tasks, newest first
agneta-diag summary <task>                                # turns, tools by time with failures and p95, tokens, cost, decisions
agneta-diag show <task> --types tool-call,tool-result     # selected records, readable or --json
agneta-diag tail -f <task>                                # follow a running task
agneta-diag export <task> --out trace.jsonl --redact-content   # for a bug report: content, names and paths removed
agneta-diag log --errors                                  # Agneta's own log
```

A task can be named by any unique prefix of its id. The same summary and timeline are in Settings → Activity → Details.

**Agneta's own log** is `~/Library/Logs/Agneta/agneta.jsonl`. It holds what Agneta itself did (starts, pairing, tasks, limits, sign-in), with ids, counts and timing only, never prompts, tool content or keys.

**Retention.** Traces live as long as task history: 30 days by default, or a week, 90 days or none, set in Settings → Privacy. Clear History and Reset delete them.

The trace format and every record type are in **[docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)**.

## Documentation

| Document | For |
| --- | --- |
| [docs/APP_PROTOCOL.md](docs/APP_PROTOCOL.md) | Integrating an app |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How Agneta is built, and its security model |
| [docs/ENGINES.md](docs/ENGINES.md) | Goose, OpenCode, Claude Code and Codex behind the engine boundary |
| [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) | Traces, `agneta-diag` and the diagnostics MCP server |
| [docs/PRIVACY.md](docs/PRIVACY.md) | What leaves your Mac, what stays and for how long, what each action removes, and the threat model |
| [docs/CONTAINMENT.md](docs/CONTAINMENT.md) | How engines are confined, how that's checked on each macOS, and the plan if `sandbox-exec` goes |
| [docs/CI.md](docs/CI.md) and [docs/RELEASING.md](docs/RELEASING.md) | What CI checks; how a release is built, signed, smoke-tested, and what it weighs |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release |
| [docs/TERMS.md](docs/TERMS.md) | Accounts, provider terms and trademarks |
| [THIRD_PARTY.md](THIRD_PARTY.md) | Bundled and downloaded components and their licences |

## Contributing and security

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Agneta handles credentials and runs code on people's Macs, so report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in public issues.

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Bundled and downloaded components keep their own licences ([THIRD_PARTY.md](THIRD_PARTY.md)).

Agneta is an independent project. It isn't affiliated with or endorsed by OpenAI, Anthropic, the Agent Client Protocol maintainers, or the Goose or OpenCode projects. Product names and logos belong to their owners.
