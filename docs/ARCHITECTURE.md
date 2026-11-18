# Architecture

How Agneta works inside, for contributors and for anyone deciding whether to trust it. What apps send and receive is in [APP_PROTOCOL.md](APP_PROTOCOL.md); the engines are in [ENGINES.md](ENGINES.md); traces and logs are in [DIAGNOSTICS.md](DIAGNOSTICS.md).

```text
App (sandboxed or not) ──ACP over a local WebSocket, paired──▶ Agneta (menu bar app)
                                                                 │ ACP over stdio
                                                                 ▼
                                  engine: Goose, OpenCode, Claude Code or Codex
                                  its own home, under macOS's sandbox
                                     │ model calls          │ the app's MCP tools
                                     ▼                      ▼
                                  the account's provider    the app's tool server (loopback)
```

- **Agneta** owns the accounts and their credentials, app pairing, the ACP router, each session's policy, the engines and their sandboxes, task history, traces, and the menu bar UI with Stop.
- **The engine** runs the agent loop: model call, tool call, repeat. Agneta pins it, isolates it and translates each session's policy into the engine's own settings.
- **The app** brings a workspace folder, instructions, its own tools as an MCP server, and a policy. It never sees the engine, its port or its credentials.
- **The provider** is reached with the account's API key or plan sign-in, from inside the engine.

## Code layout

| Path | What |
| --- | --- |
| `Sources/AgnetaKit/` | Everything testable without a window: a Swift package library |
| `  JSON/` | `JSONValue` (any JSON, lossless, 64-bit integers kept) and JSON-RPC 2.0 messages |
| `  ACP/` | `RPCPeer`: one side of a JSON-RPC connection, transport-agnostic |
| `  Transport/` | Newline-delimited stdio framing, the WebSocket server for apps, a minimal HTTP server for diagnostics |
| `  Runtime/` | `AgnetaRuntime`: the router, engines and records wired together; it records grants and task history, cleans up after a crash and applies retention |
| `  Router/` | The router: pairing and app connections (`Router.swift`), opening sessions (`+Sessions`), engine messages and permissions (`+Engines`), the turn queue and limits (`+Turns`), grant scopes, rate-limit detection |
| `  Engine/` | `EngineAdapter` and one adapter per engine, `BuiltinTools` (the built-in tools each policy permits, the contract every engine is tested against), the supervisor, CLI discovery, usage readers, crash recovery |
| `  Policy/` | `agneta/policy@1` parsing, Seatbelt profiles, the tool broker |
| `  Pairing/` | Who is on the other end of a loopback connection |
| `  SignIn/` | Plan sign-ins and token refresh |
| `  Store/` | SQLite store, Keychain, Reset |
| `  Diagnostics/` | Trace writer and normalizer, trace export, the diagnostics MCP server, the operational log |
| `Sources/Agneta/` | The menu bar app: a thin SwiftUI and AppKit layer that opens the runtime, tells it which accounts to serve, and observes it |
| `Sources/agneta-shell/` | The shell engines are given: forwards each command to the tool broker |
| `Sources/agneta-diag/` | Command-line trace reader, shipped in the app |
| `Sources/agneta-testclient/` | A stand-in client app, built as a sandboxed app with Mac App Store entitlements; the panel's Run a Test Task uses it |
| `Sources/agnetad`, `agneta-probe`, `agneta-signin` | Development tools: a headless runtime, a direct engine probe, a sign-in driver. Not shipped |
| `Engines/*.lock` | Pinned engine and runtime versions with SHA-256 hashes; `scripts/fetch-engines` and `scripts/fetch-codex` fetch them |

The only third-party library linked in is [GRDB.swift](https://github.com/groue/GRDB.swift). Engines are programs Agneta runs, never libraries it links. See [THIRD_PARTY.md](../THIRD_PARTY.md).

## The runtime

`AgnetaRuntime` (an actor) is what a host opens: the menu bar app, or `agnetad` without a UI. It opens the database, stops engines and marks tasks a crash left behind, starts the supervisor and router with the saved grants, and applies retention at launch and daily. Then it records what happens itself: each grant before its token goes out, each task's start, turns, usage and end in the order the router reported them (the outcome from how the task ended: closed by its app, stopped, or its engine exited), Remove Access, and what a task leaves behind (its trace and engine home) when it leaves history. A record that can't be written is logged, never dropped silently. Hosts tell it which accounts to serve and observe its events; they never write Agneta's records themselves.

## The router

`Router` is an actor. It answers `initialize` itself, checks the app's grant and the session policy, translates `session/new` for the engine, and maps session ids both ways, so apps never see engine ids and can't reach another app's sessions. Everything it doesn't need to inspect passes through unchanged as raw JSON, so new ACP or engine features don't break it.

- **Requests from the engine** (permission requests, file or terminal calls) go back to the owning app, after the policy checks in [APP_PROTOCOL.md](APP_PROTOCOL.md#permissions).
- **Notifications are delivered in order.** Each connection handles its notifications and responses one at a time, in arrival order, so streamed chunks never reorder and a turn's result never overtakes its last updates. Requests run concurrently, since a handler may wait on another connection.
- **Writes never block Agneta.** Each engine's stdin is written on a queue of its own, so an engine that stops reading can't hold up anything else.
- **Turns are queued** (8 at once, 3 per account, 32 waiting) and **limited** by the policy's time, model-call and cost limits, checked twice a second.
- **Stopping** (Stop in the menu, `session/close`, an app disconnecting, Remove Access) cancels the turn and closes the session within 5 seconds, even when an engine is stuck or has stopped reading; the session ends whatever the engine answers.
- **An engine that exits on its own** is retired at once (connection closed, broker grant revoked, recorded as stopped), and its sessions end with `stoppedBy: "engine"`; the next session on that account starts a fresh engine.

## Engines and processes

The `EngineSupervisor` starts engines on demand and never replays work.

- **Dedicated engines.** A session with built-in tools, every OpenCode, Claude Code and Codex session, and a Claude plan on Goose get an engine process of their own. Its home is `Engines/<account>-<id>` in Agneta's data folder, and it lives as long as the task's history, since `session/load` needs the conversation kept there.
- **Shared engines.** App-only sessions on Goose share one engine per account (one per account and engine, when an app is set to another engine than the account's), in the account's home. Concurrent starts of the same engine are merged into one.
- **The environment is explicit.** Nothing is inherited from Agneta or the user's shell: a private `HOME` and `TMPDIR`, a minimal `PATH`, the provider's settings, and nothing that would load the user's own configuration of that engine.
- **Every engine runs in its own process group** under `sandbox-exec`, and is stopped by its recorded group, never by name. Its stderr goes to `engine.log` in its home, kept under 1 MB.
- **Crash recovery.** Every engine started is recorded with its pid and process start time. At the next launch, a recorded engine is stopped only if its pid, start time and group leadership all still match, so a reused pid is never touched. Tasks that were running become "Stopped when Agneta quit".

## Security model

Agneta's job is to let an app use the user's AI accounts without the app or the agent getting more than the user allowed. The layers:

### Pairing

An app must be paired before anything else. `agneta/pair` opens Agneta's approval window, where the user chooses which accounts the app may use.

- **Who is asking.** Agneta finds the process that owns the client end of the established loopback connection to its port (both ends must match), and reads its code signature. It's **verified** only when signed with an Apple-issued certificate (Developer ID or App Store) and a team ID; ad hoc and self-signed code is valid but anyone could sign it with any identifier. A verified app is shown by its signing identifier.
- **When it can't verify,** the app is sent a six-digit code to show, and Agneta's window shows the same code. The user allows the app only if they match.
- **The scope.** The app says at pairing what it will need: the most built-in tools and the user's folders (`GrantScope`). The window shows it in plain words. The grant keeps it, plus a workspace of the app's own beside Agneta's data, and every session's policy must fit inside: no more tools, no folder outside. A session can't widen what the user saw.
- **The grant.** The app gets a 32-byte random token. Agneta stores only its SHA-256 hash, with the accounts, scope and signing identity, and saves it before the token goes out. Allow Once keeps nothing and ends with the connection. When a verified app reconnects, its code signature is checked again: the token alone isn't enough. Remove Access revokes it, stops the app's sessions and closes its open connections; nothing more runs on them. Reset closes every app connection.
- **Browsers can't connect.** The WebSocket server refuses upgrades with an `Origin` header, and the diagnostics server refuses requests with one.

### The session policy

Each session's policy is parsed strictly: an unknown field, a malformed limit, or a folder that would reach somewhere protected is refused, never ignored ([APP_PROTOCOL.md](APP_PROTOCOL.md#agnetapolicy1)). Paths are resolved through symlinks before checking. Protected places are the root and the home folder (and anything containing them), other apps' containers and group containers, Agneta's own data, `~/Library/LaunchAgents`, `~/Library/Keychains` and `~/.ssh`.

### Sandbox profiles

macOS's Seatbelt (`sandbox-exec`) confines each engine. Profiles are generated per engine process (`Policy/SandboxProfile.swift`) and written beside it as `engine.sb`. Why Seatbelt, how it's checked on each macOS version, and what replaces it if it goes: [CONTAINMENT.md](CONTAINMENT.md).

| | Engine profile | Tool profile (shell commands) |
| --- | --- | --- |
| Writes | Its home, plus the workspace and `writable` folders when the session has `workspace` tools | The workspace and `writable` folders with `workspace` tools; otherwise only a scratch folder |
| Reads | System locations, its home, the workspace and the policy's readable folders, its own program files (for Claude Code and Codex, the user's install); on a Claude plan also `~/Library/Keychains`, where Claude Code keeps its sign-in | System locations, the workspace and the policy's readable folders |
| `readOnly`, `denied` | Never written; never read or written | Same |
| Network out | TCP port 443 to any host (for the provider), the app's MCP ports on loopback, Agneta's tool broker socket, DNS. Any loopback port for a shared app-only engine and for OpenCode (its private server) | Only the policy's `toolPorts` and `toolSockets` on this Mac |
| Listening | None (OpenCode: loopback only, for its private server) | None |
| Other processes | Can't see or signal processes outside its sandbox, send Apple Events, have LaunchServices open anything, or run a program from a folder it can't read | Same, and no Keychain access |

What each part of a task can reach, in one place:

| What runs | Confined by | Files | Network |
| --- | --- | --- | --- |
| The engine itself (talking to the model, its own bookkeeping) | Engine profile | As in the table above | HTTPS to any host; the app's MCP ports |
| Shell commands on Goose and OpenCode | Tool profile, through the broker | The workspace (with `workspace` tools), or a scratch folder | None, beyond `toolPorts` and `toolSockets` |
| Built-in tools of Claude Code and Codex, which run inside the engine | Engine profile, plus Agneta refusing their `execute` and `fetch` while `network` is `none`, and edits unless tools are `workspace` | The engine's | The engine's, which is why commands and fetches are refused |
| The app's own MCP tools | Not by Agneta: they run in the app, with the app's own permissions | The app's | The app's |

Two consequences to be clear about:
- **Seatbelt filters network by address and port, not by host name.** The engine needs HTTPS to reach its provider, so it can reach any HTTPS server. That's why a host allowlist for tools isn't offered: it couldn't be enforced the same way.
- **macOS won't nest a sandbox inside another.** That's why shell commands go through the tool broker rather than running inside the engine, and why an engine that sandboxes its own commands (Codex) can't run them inside Agneta ([ENGINES.md](ENGINES.md#codex)).

### The tool broker

Goose and OpenCode are given `agneta-shell` as their shell. It forwards each command over a Unix socket (owner-only) to Agneta's tool broker, with a per-engine token. The broker:
- refuses a command whose working directory is outside the session's workspace;
- runs it with `/bin/bash -c` under the session's tool profile, in its own process group, with `HOME` and `TMPDIR` set to the scratch folder;
- ends anything the command left running in the background when the command exits;
- records the command, exit status, timing and output sizes in the task's trace.

Claude Code and Codex run their own tools. For them Agneta checks every permission request against the policy before anything runs, and refuses modes that would stop the engine asking ([APP_PROTOCOL.md](APP_PROTOCOL.md#permissions)).

### Credentials

| Kind | Where it lives | Who refreshes it |
| --- | --- | --- |
| API keys | Agneta's Keychain items (service = the app's bundle identifier) | Nobody; passed to the engine in its environment |
| ChatGPT plan on Codex | Codex's own entry in the login Keychain ("Codex Auth", keyed by the account's `CODEX_HOME`) | Codex |
| Claude plan | Claude Code's own login Keychain entry, keyed by the account's configuration folder | Claude Code |
| Diagnostics token | Agneta's Keychain items | The user, in Settings |

Each account's folder is used only by that account's engines. Claude Code's transcripts of other tasks are denied to each Claude Code engine ([ENGINES.md](ENGINES.md#claude-code)).

## Accounts and billing

| Account | Engines | Billing | Cost means |
| --- | --- | --- | --- |
| ChatGPT plan | Codex | `subscription` | `plan-equivalent`: what the calls would cost; the plan pays |
| Claude plan | Goose, Claude Code | `subscription` | `plan-equivalent` |
| OpenAI API key | Goose, OpenCode, Codex | `api-key` | `estimated`: the engine's price for each call |
| Anthropic API key | Goose, OpenCode, Claude Code | `api-key` | `estimated` |

A paused account starts nothing new: no session opens and no turn begins, queued ones included, while a turn already running finishes. When a provider's limit stops a turn, the menu marks the account with the reset time when the provider gave one. When an engine says the account isn't signed in, the menu asks the user to sign in again.

## Storage

Everything is in Agneta's Application Support folder, named by its bundle identifier:

| Path | What |
| --- | --- |
| `agneta.sqlite` | Accounts, grants (by token hash), task history, turns, recorded engines, settings |
| `Accounts/<id>/` | Each account's engine home and sign-in |
| `Engines/<account>-<id>/` | Dedicated engines' homes |
| `Runtimes/` | Downloaded runtimes (`claude-agent-acp`) |
| `Traces/` | Task traces ([DIAGNOSTICS.md](DIAGNOSTICS.md)) |

- **The database** is SQLite through GRDB. Migrations run in transactions after a file backup (`agneta.sqlite.before-<last applied>`). A database from a newer Agneta is refused untouched.
- **Retention.** Task history, traces and engine homes are kept 30 days by default (or a week, 90 days, or none), pruned at launch and daily.
- **Reset** deletes Agneta's Keychain items, data, caches and logs, preferences and the login item. A marker file beside the data folder makes an interrupted reset resume at the next launch.
- **Isolated instances.** A build started with `AGNETA_HOME=<folder>` and `AGNETA_PORT=<port>` keeps its data, Keychain items (a service of its own, derived from the folder), logs and Reset inside that folder, so tests never touch the user's own Agneta or each other. The port is required, and it and the diagnostics port two above it must stay clear of the user's own Agneta (47321, 47323, 47331, 47333); otherwise the instance listens on nothing and says why.

## The app

A menu bar app (`LSUIElement`) with no Dock icon. Its own `NSStatusItem` and a borderless glass panel show the accounts, running tasks with Stop, and anything needing attention. Settings has panes for general settings, accounts (with each account's default engine and Claude Code or Codex install), apps (with the engine each app runs on, per account), activity with task details, privacy and retention, advanced diagnostics, and about. Approval and sign-in open as their own windows. Reduce Motion and Reduce Transparency are respected, and every control is labelled for VoiceOver.

Release builds update themselves with Sparkle, from the latest published GitHub release; development builds never do ([RELEASING.md](RELEASING.md#3-updates-in-the-app-sparkle-2)).

Releases are built, signed with a Developer ID and notarized on GitHub ([RELEASING.md](RELEASING.md)); development builds are signed ad hoc.

**Not supported yet:** limits set in Settings (the defaults apply).
