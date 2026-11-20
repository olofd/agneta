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
| `  Router/` | The router: its state, grants and access (`Router.swift`, `Access`, `AccessReport`), app connections, pairing and requests (`+Apps`), opening sessions (`+Sessions`), engine messages and permissions (`+Engines`), the turn queue and limits (`+Turns`), the limits the user sets for each app (`AppLimits`, `AppMeter`, `+AppLimits`), grant scopes, rate-limit detection |
| `  Engine/` | `EngineAdapter` and one adapter per engine, `BuiltinTools` (the built-in tools each policy permits, the contract every engine is tested against), the supervisor, CLI discovery, usage readers, crash recovery |
| `  Policy/` | `agneta/policy` parsing, the sandbox modes (`Sandbox`) and what developer access widens (`DeveloperAccess`), Seatbelt profiles, the tool broker |
| `  Pairing/` | Who is on the other end of a loopback connection |
| `  SignIn/` | Plan sign-ins and token refresh |
| `  Store/` | SQLite store, Keychain, Reset, Agneta's own folders made real before use (`OwnFolder`) |
| `  Diagnostics/` | Trace writer and normalizer, trace export, the diagnostics MCP server, the operational log |
| `Sources/Agneta/` | The menu bar app: a thin SwiftUI and AppKit layer that opens the runtime, tells it which accounts to serve, and observes it. `AppModel` holds what the windows show, with the engines on this Mac (`EngineLibrary`), apps asking for access (`Approvals`) and signing in (`SignInFlow`) in types of their own; `Tests/AgnetaTests` tests them without windows |
| `Sources/agneta-shell/` | The shell engines are given: forwards each command to the tool broker. Also Codex's MCP shell (`--mcp`) and the holder of a command's background jobs (`--hold`) |
| `Sources/agneta-diag/` | Command-line trace reader, shipped in the app |
| `Sources/agneta-testclient/` | A stand-in client app, built as a sandboxed app with Mac App Store entitlements; the panel's Run a Test Task uses it |
| `Sources/agnetad`, `agneta-probe`, `agneta-signin` | Development tools: a headless runtime (it approves every pairing, contained unless started with `--sandbox developer`), a direct engine probe, a sign-in driver. Not shipped |
| `Sources/AgnetaFakes`, `agneta-fakes` | Fake model and tool servers for tests: a library the test process serves, and a program for the example apps' and the TypeScript client's integration tests. Not shipped |
| `clients/typescript/` | `@agneta/client`, the official TypeScript client of the app protocol, published to npm on its own ([its design](../clients/typescript/DESIGN.md)). `clients/` holds every official client, one folder per language |
| `examples/` | Project Chat and Replica Bench: Electron apps on the TypeScript client, and the reference for how an app uses Agneta |
| `Engines/*.lock` | Pinned engine and runtime versions with SHA-256 hashes; `scripts/fetch-engines` and `scripts/fetch-codex` fetch them |

The only third-party library linked in is [GRDB.swift](https://github.com/groue/GRDB.swift). Engines are programs Agneta runs, never libraries it links. See [THIRD_PARTY.md](../THIRD_PARTY.md).

## The runtime

`AgnetaRuntime` (an actor) is what a host opens: the menu bar app, or `agnetad` without a UI. It opens the database, stops engines and marks tasks a crash left behind, starts the supervisor and router with the saved grants, and applies retention at launch and daily. Then it records what happens itself: each grant before its token goes out, each task's start, turns, usage and end in the order the router reported them (the outcome from how the task ended: closed by its app, stopped, or its engine exited), Remove Access, and what a task leaves behind (its trace and engine home) when it leaves history. A record that can't be written is logged, never dropped silently. Hosts tell it which accounts to serve and observe its events; they never write Agneta's records themselves.

## The router

`Router` is an actor. It answers `initialize` itself, checks the app's grant and the session policy, translates `session/new` for the engine, and maps session ids both ways, so apps never see engine ids and can't reach another app's sessions. Everything it doesn't need to inspect passes through unchanged as raw JSON, so new ACP or engine features don't break it.

- **Requests from the engine** (permission requests, file or terminal calls) go back to the owning app, after the policy checks in [APP_PROTOCOL.md](APP_PROTOCOL.md#permissions).
- **Notifications are delivered in order.** Each connection handles its notifications and responses one at a time, in arrival order, so streamed chunks never reorder and a turn's result never overtakes its last updates. Requests run concurrently, since a handler may wait on another connection.
- **Writes never block Agneta.** Each engine's stdin is written on a queue of its own, so an engine that stops reading can't hold up anything else.
- **Turns are queued** (8 at once, 3 per account, no more of an app's than the user's "at once" limit for it, 32 waiting). A turn waits only behind earlier turns that want the same room, so neither a busy account nor an app at its own limit holds up another.
- **Turns are limited** by the policy's time, model-call and cost limits, and by the spending limit the user set for the app (on API keys only), checked twice a second. The user's limits for an app (spending, at once, new tasks; [APP_PROTOCOL.md](APP_PROTOCOL.md#limits-the-user-sets)) are kept with its grant and counted per grant in hourly totals; every check that can refuse work is synchronous, made before the request's first wait and again after each one, and new tasks are counted before their engine starts, so a burst can't all pass.
- **Stopping** (Stop in the menu, `session/close`, an app disconnecting, Remove Access) cancels the turn and closes the session within 5 seconds, even when an engine is stuck or has stopped reading; the session ends whatever the engine answers.
- **An engine that exits on its own** is retired at once (connection closed, broker grant revoked, recorded as stopped), and its sessions end with `stoppedBy: "engine"`; the next session on that account starts a fresh engine.

## Engines and processes

The `EngineSupervisor` starts engines on demand and never replays work.

- **Dedicated engines.** A session with built-in tools, every OpenCode, Claude Code and Codex session, and a Claude plan on Goose get an engine process of their own. Its home is `Engines/<account>-<id>` in Agneta's data folder, and it lives as long as the task's history, since `session/load` needs the conversation kept there.
- **Shared engines.** App-only sessions on Goose share one engine per account and engine, in the account's home. Concurrent starts of the same engine are merged into one.
- **The environment is explicit.** Nothing is inherited from Agneta or the user's shell: a private `HOME` and `TMPDIR`, a minimal `PATH` (under developer access, the user's toolchains and the app's cache variables), the provider's settings, and nothing that would load the user's own configuration of that engine.
- **Every engine runs in its own process group** under `sandbox-exec`, and is stopped by its recorded group, never by name. Its stderr goes to `engine.log` in its home, kept under 1 MB.
- **A start has a deadline.** An engine that doesn't answer `initialize` within 60 s is stopped, and its task fails instead of waiting.
- **Crash recovery.** Every engine started is recorded with its pid and process start time. At the next launch, a recorded engine is stopped only if its pid, start time and group leadership all still match, so a reused pid is never touched. Tasks that were running become "Stopped when Agneta quit".

## Security model

Agneta's job is to let an app use the user's AI accounts without the app or the agent getting more than the user allowed. The layers:

### Pairing

An app must be paired before anything else. `agneta/pair` opens Agneta's approval window, where the user ticks the providers (accounts) the app may use. Its engines are all allowed unless the user narrows them under Engines…, so the window asks nothing technical by default. For an app with `workspace` tools, the user also chooses Developer access or Contained. An app may narrow the window to the provider kinds, engines and mode it asks for. Before pairing, an app may call `agneta/catalog` (each kind of provider, whether one is connected, the engines; never the user's accounts) and `agneta/setup` (Agneta's window for connecting a provider).

- **Who is asking.** Agneta finds the process that owns the client end of the established loopback connection to its port (both ends must match), and reads its code signature. It's **verified** only when signed with an Apple-issued certificate (Developer ID or App Store) and a team ID; ad hoc and self-signed code is valid but anyone could sign it with any identifier. A verified app is shown by its signing identifier.
- **When it can't verify,** the app is sent a six-digit code to show, and Agneta's window shows the same code. The user allows the app only if they match.
- **The scope.** The app says at pairing what it will need: the most built-in tools and the user's folders, and optionally the provider kinds, engines and sandbox mode it wants (`GrantScope`). The window shows it in plain words. The grant keeps it, plus a workspace of the app's own beside Agneta's data, and every session's policy must fit inside: no more tools, no folder outside, no more than the grant's sandbox mode. A session can't widen what the user saw.
- **The grant.** The app gets a 32-byte random token. Agneta stores only its SHA-256 hash, with the providers and engines it may use, the scope, its sandbox mode (contained for grants made before modes existed) and the signing identity, and saves it before the token goes out. Allow Once keeps nothing and ends with the connection. When a verified app reconnects, its code signature is checked again: the token alone isn't enough. Pairing again with Always Allow replaces the grant; an app Agneta can't verify gets a fresh one, with a new workspace and no earlier tasks. Remove Access revokes it, stops the app's sessions and closes its open connections; nothing more runs on them. Reset closes every app connection.
- **Browsers can't connect.** The WebSocket server refuses upgrades with an `Origin` header, and the diagnostics server refuses requests with one.

### The session policy

Each session's policy is parsed strictly: an unknown field, a malformed limit, or a folder that would reach somewhere protected is refused, never ignored ([APP_PROTOCOL.md](APP_PROTOCOL.md#agnetapolicy)). Paths are resolved through symlinks before checking. Protected places are the root and the home folder (and anything containing them), other apps' containers and group containers, Agneta's own data, `~/Library/LaunchAgents`, `~/Library/Keychains` and `~/.ssh`.

### Sandbox profiles

macOS's Seatbelt (`sandbox-exec`) confines each engine. Profiles are generated per engine process (`Policy/SandboxProfile.swift`) and passed inline (`sandbox-exec -p`), never written to a file an engine could rewrite. Agneta's own folders (engine homes, scratch folders, build caches, app workspaces) are made real folders before each start and written into profiles literally, never resolved through a link a session planted (`OwnFolder`, `literalRoots`). Writable folders are pinned: a session may work inside them, but can't rename, remove or replace them. Why Seatbelt, how it's checked on each macOS version, and what replaces it if it goes: [CONTAINMENT.md](CONTAINMENT.md).

| | Engine profile | Tool profile (shell commands) |
| --- | --- | --- |
| Writes | Its home, plus the workspace and `writable` folders when the session has `workspace` tools | The workspace and `writable` folders with `workspace` tools; otherwise only a scratch folder |
| Reads | System locations, its home, the workspace and the policy's readable folders, its own program files (for Claude Code and Codex, the user's install); on a Claude or ChatGPT plan also `~/Library/Keychains`, where Claude Code and Codex keep their sign-ins | System locations, the workspace and the policy's readable folders |
| `readOnly`, `denied` | Never written; never read or written | Same |
| Network out | TCP port 443 to any host (for the provider), the app's MCP ports on loopback, Agneta's tool broker socket, DNS. Any loopback port for a shared app-only engine and for OpenCode (its private server) | Only the policy's `toolPorts` and `toolSockets` on this Mac, and no name lookups. Each one held to the app when the session opens, before each command and while commands or background jobs run (`ToolReach`): a socket inside a granted folder or served by the app, a port served by the app |
| Listening | None (OpenCode: loopback only, for its private server) | None |
| Other processes | Can't signal processes outside its sandbox or read their state (though macOS lets it read their arguments and environment), send Apple Events, have LaunchServices open anything, or run a program from a folder it can't read | Same, and no Keychain access |

What each part of a task can reach, in one place:

| What runs | Confined by | Files | Network |
| --- | --- | --- | --- |
| The engine itself (talking to the model, its own bookkeeping) | Engine profile | As in the table above | HTTPS to any host; the app's MCP ports |
| Shell commands on every engine (Goose's and OpenCode's shells, Claude Code's Bash, Codex's through Agneta's MCP shell) | Tool profile, through the broker | The workspace (with `workspace` tools), or a scratch folder | None, beyond `toolPorts` and `toolSockets`: the app's own servers, and sockets in its granted folders |
| Other built-in tools of Claude Code and Codex (reading, editing, fetching), which run inside the engine | Engine profile, plus Agneta refusing their `fetch` while `network` is `none`, and edits unless tools are `workspace` | The engine's | The engine's, which is why fetches are refused |
| The app's own MCP tools | Not by Agneta: they run in the app, with the app's own permissions | The app's | The app's |

A socket or port reaches whatever serves it (Docker's socket starts containers that mount the home folder), so a contained session's `toolSockets` and `toolPorts` are held to the grant before any profile is written (`Policy/ToolReach.swift`, `GrantScope.reach`). A socket inside a folder the app was granted is allowed, as the approval window showed that folder; the profile names it as it was checked, so a link put in its place reaches nothing. Any other socket, and every port, must be served by the app, and who serves it is the kernel's answer: Agneta connects to it as a command would. A socket's listener comes with the connection's audit token (`LOCAL_PEERTOKEN`); a port's is whoever holds the far end of that connection (found by its two ports, on `127.0.0.1` and `::1`), or, when the server doesn't accept within about 170 ms or closes at once, whoever holds the listening socket for that address or its wildcard (the kernel's record of port and address, which another user can't bind beside). Nothing answering, or an answer that can't be identified (root's servers can't be inspected), refuses it. A scan of the processes (`proc_listallpids`, each one's socket descriptors) only narrows: everything it finds bound there must be the app too. It never counts for the app, since the path a process bound with is its own string, which a change of folder or a link swapped in can point elsewhere (measured). For a verified grant the app is an Apple-anchored signature from its team, read through the audit token when there is one; otherwise the process holding the app's connection to Agneta, or one of its descendants (parents followed with `PROC_PIDTBSDINFO`). Processes are compared as instances (pid and start time, or the audit token). It runs only when a contained policy names such an endpoint (at most 16), with every endpoint probed at once on threads of its own under one 3 s deadline, awaited off the router's actor, so one app's silent servers never hold up another app. What it found is kept with the session's policy, so a changed grant is checked again without connecting. The broker asks again before each command and, while a session's commands or background jobs run, about every second, trying a failed endpoint once more after half a second. An endpoint the app no longer serves refuses the command, stops the session's commands and jobs and stops the session (`agneta/sessionStopped`, `stoppedBy: "reach"`; [APP_PROTOCOL.md](APP_PROTOCOL.md#tool-ports-and-sockets)). The remaining gap (up to about 1.5 s after a server is replaced) closes only with Agneta serving the socket itself and passing connections on: future work.

These are the contained profiles. Under developer access both are widened as a terminal is: the home folder readable apart from credentials and Agneta's data, the internet, every loopback port, the user's toolchains read-only, and the app's own build caches writable ([APP_PROTOCOL.md](APP_PROTOCOL.md#sandbox)). The tool profile still keeps the engine's sign-in out.

Two consequences to be clear about:
- **Seatbelt filters network by address and port, not by host name.** The engine needs HTTPS to reach its provider, so it can reach any HTTPS server. That's why a host allowlist for tools isn't offered: it couldn't be enforced the same way.
- **macOS won't nest a sandbox inside another.** That's why shell commands go through the tool broker rather than running inside the engine, and why Codex's own shell is off and its commands go through Agneta's MCP shell instead ([ENGINES.md](ENGINES.md#codex)).

### The tool broker

Every engine's commands reach it through `agneta-shell`: Goose's and OpenCode's shell, Claude Code's shell prefix (`CLAUDE_CODE_SHELL_PREFIX`), and for Codex an MCP server (`agneta-shell --mcp`) whose `shell` tool replaces its own. It forwards each command over a Unix socket (owner-only) to Agneta's tool broker, with a per-engine token read from a file only that engine reads (an environment can be read by other processes). The broker:
- refuses a command whose working directory is outside the session's workspace;
- runs it with `/bin/bash -c` under the session's tool profile, in its holder's process group, with `HOME` and `TMPDIR` set to the scratch folder (`HOME` and `USER` are the user's under developer access), the selected Xcode's own tools on `PATH` and `SDKROOT`, and the app's `toolEnvironment` last, so its values win;
- keeps what the command started in the background running, as in a terminal, in a process group led by a holder (`agneta-shell --hold`), and ends that group when the engine ends, its session is revoked, or Agneta quits (the holder ends it too if Agneta dies). A command that starts a session or group of its own leaves it, and can outlive its engine (a known limit);
- records the command, exit status, timing and output sizes in the task's trace.

Claude Code and Codex run their other tools themselves. For them Agneta checks every permission request against the policy before anything runs, and refuses modes that would stop the engine asking ([APP_PROTOCOL.md](APP_PROTOCOL.md#permissions)).

### Credentials

| Kind | Where it lives | Who refreshes it |
| --- | --- | --- |
| API keys | Agneta's Keychain items (service = the app's bundle identifier) | Nobody; passed to the engine in its environment, which other processes of the user's can read (a known limit) |
| ChatGPT plan on Codex | Codex's own entry in the login Keychain ("Codex Auth", keyed by the account's `CODEX_HOME`) | Codex |
| Claude plan | Claude Code's own login Keychain entry, keyed by the account's configuration folder | Claude Code |
| Diagnostics token | Agneta's Keychain items | The user, in Settings |

Each account's folder is used only by that account's engines. Claude Code's transcripts of other tasks are denied to each Claude Code engine ([ENGINES.md](ENGINES.md#claude-code)). What Claude Code and Codex would act on outside any sandbox (Claude Code's settings files, hooks and skills; Codex's `.env`, `AGENTS.md`, hooks, skills, rules and prompts) is read-only to their engines. Before sign-in, status or sign-out runs either outside the sandbox, Agneta makes the account folder a real folder again and clears those files; Codex's are cleared before each start too.

## Providers, engines and access

Three things decide where a task runs, each kept in one place:

- **Which engines can serve which provider** is a fixed table, `ProviderEngines` (below, and [ENGINES.md](ENGINES.md)). A provider names no engine of its own; each kind has a default the user can change in Settings → Engines.
- **What this Mac can run** is the `EngineCatalog`: each engine's state (ready, downloading, downloadable, failed, unavailable and why) and the providers' defaults. Only the host knows where engines come from (the bundle, the user's Claude Code and Codex installs, downloads), so the menu bar app's `EngineLibrary` builds the catalog whenever any of that changes and hands the whole snapshot to the runtime; the router, the supervisor and every window read the same one. It builds it from one description per engine (`EngineSource.all`: how it gets onto this Mac, what it downloads, which of the user's programs it runs through), and also runs the downloads and checks each downloaded runtime's whole tree against its pin at launch, off the main thread.
- **What an app may use** is its grant: a list of providers and a list of engines (`all`, or some), independent of each other, and a sandbox mode.

What each engine can do (steer, fork, run its own tools) is its adapter's (`EngineCapabilities`); what an app sees of it is typed (`AccessReport`, `SessionCapabilities`).

`Access` combines them: a task's provider must be in the grant, and its engine in the grant, supported by the provider, and in the catalog. The engine must also be able to provide the task's sandbox mode (`ProviderEngines.sandboxLevels`), decided with the grant's mode and the app's request in one place (`SandboxResolution`). The app picks both per task, from what `agneta/access` lists, and gets the provider's default engine when it names none. Every check (session/new, load, fork, initialize, the approval window, Settings) goes through it ([APP_PROTOCOL.md](APP_PROTOCOL.md#access)).

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
| `agneta.sqlite` | Accounts, grants (by token hash, with the limits the user set), each app's usage by hour, task history, turns, recorded engines, settings |
| `Accounts/<id>/` | Each account's engine home and sign-in |
| `Engines/<account>-<id>/` | Dedicated engines' homes |
| `Runtimes/` | Downloaded runtimes (OpenCode, `claude-agent-acp`, and in releases Codex's runtime) |
| `Traces/` | Task traces ([DIAGNOSTICS.md](DIAGNOSTICS.md)) |
| `Tokens/` | One owner-only file per running engine, holding its broker token |

Beside it, `… Workspaces/<grant>` holds each app's own workspace, and `… Workspaces/.build-caches/<grant>` each app's build caches under developer access.

- **The database** is SQLite through GRDB. **Before 1.0 there's no compatibility promise.** The schema may change in place, and a database made with another schema is refused, untouched, so the user resets. Small forward migrations are added where they're cheap, as the sandbox modes did (grants made before them migrate as contained). Compatibility starts at 1.0.
- **Retention.** Task history, traces and engine homes are kept 30 days by default (or a week, 90 days, or none), pruned at launch and daily. Each app's usage by hour (what its tasks on API keys cost, tokens, turns and new tasks, for its limits) is kept 35 days whatever history keeps, so clearing history doesn't reset a limit; Remove Access deletes it.
- **Reset** deletes Agneta's Keychain items, data, caches and logs, the apps' workspaces and build caches, preferences and the login item. A marker file beside the data folder makes an interrupted reset resume at the next launch.
- **Isolated instances.** A build started with `AGNETA_HOME=<folder>` and `AGNETA_PORT=<port>` keeps its data, Keychain items (a service of its own, derived from the folder), logs and Reset inside that folder, so tests never touch the user's own Agneta or each other. The port is required, and it and the diagnostics port two above it must stay clear of the user's own Agneta (47321, 47323, 47331, 47333); otherwise the instance listens on nothing and says why.

## The app

A menu bar app (`LSUIElement`) with no Dock icon. Its own `NSStatusItem` and a borderless glass panel show the accounts, running tasks with Stop, and anything needing attention. Settings has panes for general settings, providers, engines (each kind of provider's default engine, and each engine's source, version, install and download), apps (each app's providers, its sandbox mode, its limits with its usage today, and under Advanced its engines), activity with task details, privacy and retention, advanced diagnostics, and about. Approval and sign-in open as their own windows. Reduce Motion and Reduce Transparency are respected, and every control is labelled for VoiceOver.

Release builds update themselves with Sparkle, from the latest published GitHub release; development builds never do ([RELEASING.md](RELEASING.md#3-updates-in-the-app-sparkle-2)).

Releases are built, signed with a Developer ID and notarized on GitHub ([RELEASING.md](RELEASING.md)); development builds are signed ad hoc.
