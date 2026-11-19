# Agneta for apps: the protocol

How a Mac app runs AI work through Agneta. Agneta speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP, JSON-RPC 2.0) and adds a few namespaced extensions, each listed in `initialize`. An app that ignores them still gets plain ACP.

**In TypeScript or JavaScript, use [`@agneta/client`](../clients/typescript/README.md),** the official client: it implements everything on this page (connecting and opening Agneta, pairing and the token, access, sessions, streaming, permissions, traces and every error, typed) and keeps a raw layer for anything else. Two runnable Electron examples are built on it: [Project Chat](../examples/project-chat/README.md), with pairing, streamed replies, and app-owned MCP tools, and [Replica Bench](../examples/replica-bench/README.md), which runs demanding work on every engine in both sandbox modes.

Every step on this page is exercised by the test suite: `Tests/AgnetaKitTests/AppScenarioTests.swift` runs it against a real engine, and `RouterContractTests.swift` pins each decision. How Agneta works inside is in [ARCHITECTURE.md](ARCHITECTURE.md); what each engine can do is in [ENGINES.md](ENGINES.md).

## Connecting

- **Address:** `ws://127.0.0.1:47321/acp` for releases, `47331` for development builds. Loopback only, one JSON-RPC message per text frame, frames up to 16 MB.
- **Before it has a grant** (until pairing or `initialize` succeeds), a connection is anything on this Mac and gets little: at most 16 such connections at once, messages up to 256 KB, and 10 minutes to pair. Past any of these, Agneta closes it.
- **Browsers can't connect:** a WebSocket upgrade with an `Origin` header is refused, so a web page can't drive Agneta.
- **Sandboxed (Mac App Store) apps** need `com.apple.security.network.client` to connect to Agneta, and `com.apple.security.network.server` as well if they serve their own MCP server on loopback.
- **Folders for sandboxed apps.** A folder inside an app container (`~/Library/Containers`, `~/Library/Group Containers`) can't be a session's folder: Agneta keeps apps' private storage out of reach. Ask in the pairing scope for folders the user chose (an open panel or a security-scoped bookmark gives the real path, outside the container), or let tasks work in the workspace Agneta makes for the app and hand results back through the app's MCP tools: the sandbox keeps the app itself out of that workspace.
- **When Agneta isn't running,** the connection is refused. Ask the user whether to open it, and when they say yes, open `agneta://open` (`agneta-dev://open` for a development build), wait for its port, and connect. Never open it without asking: quitting Agneta is how the user stops all of it. Opening the URL only launches Agneta; nothing in the URL is acted on.

## Before pairing: what Agneta offers

Two calls work on a connection that hasn't paired, so an app can find out whether there's anything to ask for, and help the user set it up when there isn't.

- **`agneta/catalog {}`** returns what this Agneta offers any app:
  - each provider kind (`claude`, `chatgpt`, `anthropic-key`, `openai-key`), with its name, whether one is `connected`, and the engines it runs on, each with the modes it can provide (`sandboxLevels`) and `uncontained` where it can't be contained;
  - the engines on this Mac (`id`, `name`, `state`, `reason`);
  - `connected`: whether any provider is.

  It never names the user's accounts (labels, addresses, how many): pairing guards those. An unpaired connection also gets `agneta/catalogChanged {"catalog"}` when a provider is connected or removed, or an engine changes.

  ```json
  {"providers": [{"kind": "claude", "name": "Claude plan", "connected": true,
                  "engines": [{"id": "claude-code", "sandboxLevels": ["contained", "developer"]},
                              {"id": "goose", "sandboxLevels": ["developer"], "uncontained": true}]}, …],
   "engines": [{"id": "claude-code", "name": "Claude Code", "state": "ready"}, …],
   "connected": true}
  ```
- **`agneta/setup {"name"?, "kind"?}`** asks Agneta to help the user connect a provider. Agneta comes forward with its add-provider window, naming your app, narrowed to `kind` when given. It answers `{"shown": true}` at once; wait for `agneta/catalogChanged`. Ask only when the user asked to connect, as with opening Agneta.

**A smooth first run.** On Connect, call `agneta/catalog`. If no provider of a kind you need is connected, say so and offer to set it up (`agneta/setup`), then pair once one is. Or pair straight away: with nothing connected, the approval window lets the user connect a provider in place, and the request waits for it (within the 5 minutes the window waits). An unpaired connection is closed after 10 minutes, time spent in `agneta/setup` included: connect again if the user took longer.

## Pairing, once per app

1. Send `agneta/pair {"name": "Example App", "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"]}}`. Agneta opens its approval window, which shows what the scope asks for; the user ticks the providers the app may use (one is ticked to start with), then **Allow Once** or **Always Allow**. For an app with `workspace` tools, the user also chooses **Developer access** or **Contained** ([Sandbox](#sandbox)). Every engine is allowed too, unless the user narrows them under **Engines…**: your app picks the provider and engine of each task, among what it may use ([Access](#access)).
   - **`scope`** is what the app will need: `tools`, the most built-in tools its sessions will use (`app-only`, `read` or `workspace`, as in the [policy](#agnetapolicy)), `folders`, the user's folders its sessions will work in (absolute paths, under the policy's folder rules), and optionally the providers, engines and sandbox mode (below). Without a scope the app gets app-only tools and no folders of the user's. Either way it also gets a workspace of its own, made by Agneta. Ask for what the app's features need, and no more: the user sees it all before deciding.
   - **Ask for exactly what you need.** The scope can also name the providers, engines and mode, and the approval window is narrowed to them:
     - `providers`: `"all"` or a list of kinds (`["claude"]`). It shows only providers of those kinds, ticked (all of them for `"all"`, the first of each kind for a list). A kind not connected gets a **Connect** row: the request waits while the user connects it, and it's ticked once connected. Left out, the user picks among all providers, with one ticked to start.
     - `engines`: `"all"` or a list of engine ids (`["claude-code"]`). The window names them. Left out, every engine.
     - `sandbox`: `"contained"`, `"developer"` or `"any"`. With `"contained"`, the window shows it fixed: you asked for no more, so no more is offered. With `"developer"` or `"any"` (the same as leaving it out), the picker starts on Developer access, and the user may choose Contained. The mode applies only with `workspace` tools: with fewer, tasks stay contained whatever `sandbox` says.
     - The user can still give less than you asked. A provider that can't be given as asked (contained, but none of its engines can keep it so) says why, and can't be ticked.

     For example, the smallest grant for a task that needs a Claude plan on Claude Code, contained: `{"tools": "workspace", "providers": ["claude"], "engines": ["claude-code"], "sandbox": "contained"}`. Everything: `{"tools": "workspace", "providers": "all", "engines": "all", "sandbox": "any"}`.
   - Allowed: `{"token": "…", "remembered": true, "access": {…}, "unmet": […]}` ([Access](#access)). Agneta stores only the token's hash. `unmet` lists what of your ask wasn't given, each with a `reason`: `{"provider": "chatgpt", "reason": "not connected in Agneta"}` (or "the user didn't allow it"), `{"engine": "codex", …}`, `{"sandbox": "developer", "reason": "the user chose contained"}` (or "developer access needs workspace tools", for a scope with fewer), or `{"provider": "claude", "sandbox": "contained", …}` when none of its engines can keep it contained. It's empty when you got everything you asked for.
   - **Always Allow** (`remembered: true`): keep the token in the app's Keychain and connect with it next time (`initialize`), without asking again. When `initialize` answers `-32001` (`needsPairing`), the user removed the app's access: forget the token, and pair again when the user asks to connect. Agneta also closes the app's open connections when its access is removed.
   - **Allow Once** (`remembered: false`) grants this connection only: the token stops working when it closes, and Agneta keeps nothing. Pair again next time.
   - **Pairing again** with Always Allow, for an app that has remembered access already, replaces that access instead of adding to it, and the old token stops working. The approval window says so.
     - A **verified** app (the same signing identity) keeps its grant: its workspace and tasks to resume, with what the user just allowed. Its other open connections get the new access at once, as `agneta/accessChanged`; their sessions outside it stop, with `agneta/sessionStopped`.
     - An app Agneta **can't verify** is known only by its name, which another program could give, so its new grant starts afresh: a new workspace, and none of the earlier tasks to resume. The earlier grant is removed, and connections still using it are closed.
   - A scope Agneta can't accept (a folder it protects, an unknown field, kind or engine) is refused with `-32602` before the user is asked; the reason lists what there is.
   - Don't Allow: error `-32002`. Closing the approval window, or leaving it unanswered for 5 minutes, is the same.
   - Several apps asking at once are shown one at a time. An app that disconnects while waiting withdraws its request.
2. Agneta identifies the connecting process by its code signature (see [ARCHITECTURE.md](ARCHITECTURE.md#pairing)). An app signed with an Apple-issued certificate and a team ID is shown as verified, by its signing identifier (for example `com.example.app`).
3. If Agneta can't verify the app (ad hoc or unsigned builds), it first sends `agneta/pairingCode {"code", "name"}` with six digits. Show the code prominently while the request waits. Agneta's approval window shows the same code, and the user allows the app only if the two match.
4. **Every session must fit the grant.** No more built-in tools than granted, no more than the grant's [sandbox](#sandbox), and every folder a session names (`cwd`, `readable`, `writable`, `readOnly`) inside a granted folder or the app's own workspace. Anything else is refused with `-32602`, `data.agneta.unenforceable` naming the field. To need more, pair again with a wider scope.

## Every connection

`initialize`:

```json
{"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"agneta": {"token": "…"}}}
```

- **Result:** standard `agentCapabilities` (`loadSession: true`, images in prompts, HTTP MCP servers, `session/close`), plus:
  - `_meta.agneta.extensions`: the extensions below;
  - `_meta.agneta.access`: what the app may use ([Access](#access)).
- **Error `-32001`** with `data.agneta.needsPairing: true` means the token is unknown, access was removed, an Allow Once grant has ended, or (for a verified app) the connecting program isn't the one that paired. Pair again.

### Access

What the user allows an app is two lists: the **providers** (each an account: a ChatGPT or Claude plan, an API key) and the **engines** (Goose, OpenCode, Claude Code, Codex; all of them unless the user narrowed them). Each task runs on one provider and one engine, which your app picks; the pair must be one the provider supports ([ENGINES.md](ENGINES.md)) and this Mac can run. `agneta/access {}` returns, at any time, what that means now, the same object `initialize` and pairing return:

```json
{
  "providers": [{"id": "a1b2c3d4", "label": "Claude", "kind": "claude", "paused": false, "needsSignIn": false,
                 "engines": ["claude-code", "goose"], "defaultEngine": "claude-code", "uncontained": ["goose"],
                 "sandboxLevels": {"claude-code": ["contained", "developer"], "goose": ["developer"]}}],
  "engines": [{"id": "claude-code", "name": "Claude Code", "state": "ready", "capabilities": {…}},
              {"id": "goose", "name": "Goose", "state": "ready", "capabilities": {…}},
              {"id": "opencode", "name": "OpenCode", "state": "downloadable", "size": 113000000}],
  "allowedEngines": "all",
  "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"], "sandbox": "developer"},
  "workspace": "/Users/me/Library/Application Support/com.objectivecoder.agneta Workspaces/<grant>"
}
```

- **`providers`:** each provider the app may use. `engines` are those its tasks there may run on now or after a download, the default first (`defaultEngine`: the provider's default in Agneta's settings when allowed, else the first allowed). A paused provider starts nothing new (**Pause**, under [Turns](#turns)); one that `needsSignIn` waits for the user in Agneta. `uncontained` lists the engines here whose own tools Agneta's policy doesn't confine: Goose on a Claude plan runs Claude Code as its model, with all of Claude Code's own tools and the claude.ai account's connectors, as in a terminal. Agneta still keeps that engine to the session's folders, but not to the policy's tool, network or approval rules, so it provides developer access only: a contained task on it is refused. Offer it as a choice, and say so to your users where they pick an engine. `sandboxLevels` gives, for each engine, the modes it can provide here ([Sandbox](#sandbox)).
- **`engines`:** each engine the app may use, with its `state` on this Mac: `ready` (with its `capabilities`, as in [the session result](#the-result)), `downloading` (`received`, `total`), `downloadable` (`size`: it downloads when first needed), `failed` (`reason`; asking for it tries again) or `unavailable` (`reason`, such as "Install Codex 0.166 or later").
- **`allowedEngines`:** `"all"` (including engines Agneta adds later) or the engine ids the user ticked.
- **`scope`** and **`workspace`:** what the user allowed, and the app's own workspace within it.
- **`agneta/accessChanged {"access"}`** arrives when any of it changes: the user changes the app's providers, engines or sandbox mode in Agneta's settings (sessions that no longer fit stop, with `agneta/sessionStopped`), a provider is paused, resumed, signed out or needs signing in, or an engine arrives, starts downloading or goes away. Download progress doesn't send it: `agneta/access` and `-32015` carry it.

| Extension | What it adds |
| --- | --- |
| `agneta/policy` | The session policy: tools, folders, sandbox, network, approval, command environment and ports, limits |
| `agneta/access` | `agneta/access` and `agneta/accessChanged`: the providers and engines the app may use ([Access](#access)) |
| `agneta/catalog` | `agneta/catalog` and `agneta/catalogChanged`: what Agneta offers, before pairing too ([Before pairing](#before-pairing-what-agneta-offers)) |
| `agneta/setup` | `agneta/setup`: Agneta's add-provider window, for the user to connect one |
| `agneta/task` | A title and a stop warning shown in Agneta's menu |
| `agneta/instructions` | Instructions at start, and `agneta/instructions/set` between turns |
| `agneta/steer` | `agneta/steer` during a turn |
| `agneta/usage` | Each prompt result's usage: model calls, tokens, cost, and what the numbers mean |
| `agneta/limit` | Which policy limit stopped a turn |
| `agneta/queue` | `agneta/queued` when a turn waits for room |
| `agneta/fork` | `agneta/fork`: a new task that starts with a copy of an earlier one's conversation |
| `agneta/rateLimited` | `agneta/rateLimited` and structured error data when a provider's limit stops a turn |
| `agneta/trace` | The task's full trace, live and afterwards ([DIAGNOSTICS.md](DIAGNOSTICS.md)) |

## A session

`session/new`:

```json
{
  "cwd": "/Users/me/Documents/Example Project/Workspace",
  "mcpServers": [{"type": "http", "name": "app", "url": "http://127.0.0.1:<port>/mcp",
                  "headers": [{"name": "Authorization", "value": "Bearer <per-session token>"}]}],
  "_meta": {
    "agneta": {"account": "<account id>"},
    "agneta/policy": {"tools": "workspace", "network": "none", "approval": "never-ask",
                        "readable": [], "writable": [], "readOnly": [], "denied": [],
                        "limits": {"maxTurns": 200, "maxSeconds": 1800}},
    "agneta/task": {"title": "Tidying the project notes", "stopWarning": "Example App keeps the work so far"},
    "agneta/instructions": {"text": "You are Example App's assistant…"},
    "agneta/trace": {"live": true}
  }
}
```

**`cwd`** is the workspace: the folder the agent works in. It must be an absolute path, and the same rules as the policy's folders apply to it.

**`_meta.agneta.account`** chooses the provider, one of `access.providers`. If it's omitted, the first one is used.

**`_meta.agneta.engine`** (optional) chooses the engine, one of that provider's `engines`; without it the session runs on its `defaultEngine`. An engine the provider doesn't support, the app may not use, or this Mac can't run is refused with `-32602` and the current access in `data.agneta.access`. One that downloads first starts downloading, and the session is refused with `-32015` and `data.agneta.engineDownloading {"engine", "received", "total"}` until it's done: show the progress and try again shortly. A loaded or forked session always runs on the engine that saved it. A session that was opening while the app's access changed (in Settings, or by pairing again) is checked against the access as it is then: one that no longer fits is refused with `-32602` and `data.agneta.accessChanged: true`.

**`mcpServers`** are the app's own tools: Streamable HTTP on loopback, with a bearer token.
- Only `type: "http"` with a `127.0.0.1`, `localhost` or `::1` URL is accepted. Anything else is refused with `-32602` and `data.agneta.unenforceable: ["mcpServers"]`: a stdio server would be a command run inside the engine's sandbox, and a remote one a host the policy didn't allow.
- The engine's sandbox may reach exactly those loopback ports (any port under developer access). The exceptions: an app-only session on Goose shares one engine per account, which may reach any loopback port, and OpenCode may reach any loopback port (it runs a private server of its own).
- Your tools run in your app, with your app's own permissions: Agneta's sandbox confines the engine that calls them, not what they do.
- Header values are masked in traces.
- In tool events, the server's `name` comes back as the tool's `extension`, and the tool's own name as `tool`.

### `agneta/policy`

| Field | Values |
| --- | --- |
| `tools` | `app-only`: only the app's MCP tools. `read`: plus the engine's read-only built-ins. `workspace` (the default): plus editing and a shell, confined to the workspace when contained ([Sandbox](#sandbox)) |
| `network` | `none` (the default): shell commands reach nothing but the policy's `toolPorts` and `toolSockets` (not even a name lookup), and the engines' own fetch and web search are refused. It applies to `contained` sessions: under developer access commands reach the internet whatever it says ([Sandbox](#sandbox)). The engine itself can reach any host on port 443, since it needs HTTPS for its provider and macOS's sandbox filters by port, not host name. A list of allowed hosts (`{"allow": [hosts]}`) isn't supported yet and is refused; `{"allow": []}` means `none` |
| `sandbox` | `contained` or `developer` ([Sandbox](#sandbox)): what this session should get, no more than the grant's. Without it, the grant's for `workspace` tools, `contained` for fewer. `developer` needs `workspace` tools. Asking for more than the grant is refused with `-32602`, `unenforceable: ["sandbox"]` and the reason |
| `approval` | `ask-app` (the default): tool permission requests reach the app as `session/request_permission`. `never-ask`: the policy is the permission, and Agneta answers |
| `readable`, `writable`, `readOnly`, `denied` | Absolute paths. `readOnly` stays read-only even inside the workspace; `denied` is neither readable nor writable, even inside allowed folders |
| `toolEnvironment` | Variables for shell commands, which run through Agneta's broker on every engine: your toolchain's `PATH` (each entry an absolute path inside the session's folders, no empty entries; it goes ahead of everything else), `CARGO_HOME`, `PYTHONPATH`, your kit's settings. Your values win over the ones developer access sets. Refused: `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `SHELL`, `BASH_ENV`, `ENV`, `ZDOTDIR`, `PROMPT_COMMAND`, `IFS`, and anything starting `DYLD_`, `LD_`, `AGNETA_`, `CLAUDE_CODE_`, `CODEX_`, `GOOSE_` or `OPENCODE_`. Commands also get the selected Xcode's own tools on `PATH` and `SDKROOT` |
| `toolPorts`, `toolSockets` | Loopback ports and Unix sockets that shell commands may reach (every engine's commands run through Agneta's broker) |
| `limits` | `maxTurns`: model calls within one prompt (default 200). `maxSeconds`: a prompt's wall time (default 4 hours). `maxCostUSD`: the task's known cost so far, across resumes (no default) |

- **Nothing is weakened silently.** A policy Agneta can't enforce is refused with `-32602` and `data.agneta.unenforceable: ["<field>"]`. That covers:
  - unknown fields, fields of the wrong type (`"tools": 5`), and malformed or non-positive limits;
  - relative paths, and folders that contain the home folder, other apps' containers, Agneta's own data, `~/Library/LaunchAgents`, `~/Library/Keychains` or `~/.ssh`;
  - a writable folder inside a denied one, or a denied workspace;
  - `maxCostUSD` on an engine that doesn't report cost per call (Claude Code, Codex).
- **Sending no policy** gives `workspace` tools in `cwd`, the grant's sandbox and `ask-app` approval.

### Sandbox

How far an app's tasks reach is the user's choice for that app, its **grant**: they pick it in the approval window and can change it in Settings → Apps. Two modes, the same for every engine:

- **`developer`** (Developer access): full power, as in a terminal, apart from what the table below keeps out: credentials, Agneta's data, and writes outside the session's folders and the app's caches. It's the default for an app with `workspace` tools. Grants made before sandbox modes existed stay contained.
- **`contained`**: the session's folders only, commands with no internet, every command through Agneta's broker.

Three things decide what a task gets, in one place:

1. **The grant's mode is the ceiling.** A session may ask for less (`"sandbox": "contained"` in its policy), never more: an app that asks for `developer` under a `contained` grant is refused, with the reason.
2. **The engine must be able to provide it.** Each engine declares what it can provide on each provider (`sandboxLevels` in the [access report](#access)). Goose on a Claude plan can't contain its tools (its Claude Code uses all its own tools and the claude.ai connectors): it provides `developer` only, and a contained task on it is refused with why. A task that names no engine gets one that can provide its mode, where the app may use one.
3. **Fewer tools stay contained.** Developer access is a terminal's commands, so it applies to `workspace` tools. The approval window offers the choice only to an app that asks for `workspace` tools: an app granted `read` or `app-only` tools stays contained, and an engine that can't contain them is refused. Under a developer grant, a session asking for fewer tools runs contained, except on an engine that can't be.

The reply to `session/new`, `session/load` and `agneta/fork` says what the task really got, in `_meta.agneta.sandbox`. If the user narrows the grant to `contained`, its tasks running with more stop.

Under each mode:

| | `contained` | `developer` |
| --- | --- | --- |
| Commands | Through Agneta's broker: Goose's and OpenCode's shells, Claude Code's Bash (behind its shell prefix), and Codex's through Agneta's MCP shell (`mcp__agneta__shell`, its own shell off) | Through the broker too, with a command sandbox widened like a terminal's (your home as `HOME`, the internet), which keeps the engine's sign-in out |
| Engine's own tools | The policy's tools only, each permission request checked | Claude Code's own tool set (web fetch and search, subagents, skills), apart from those that reach your claude.ai account or devices (artifacts, projects, designs, messages and files sent to the user, notifications, remote triggers) and Monitor and PowerShell, which would run commands outside Agneta's broker; Codex's, with web search. Both still ask before acting, in the `default` and `workspace-write` modes |
| Internet | None for commands | Any host and port. The sites reached aren't listed yet |
| Files read | The workspace and the policy's folders | Also the whole home folder, except credentials and private data (`~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker/config.json`, `~/.netrc`, `~/.git-credentials`, `~/.config/gh`, `~/.npmrc`, `~/.pypirc`, cargo credentials, `~/.claude*`, `~/.codex`, other agents' sign-ins such as Goose's and OpenCode's, shell histories, the Keychains folder, Cookies, Mail, Messages, Safari and other browsers' profiles, other apps' containers and group containers, `~/Library/LaunchAgents`) and all of Agneta's own data: every build's data, caches, logs and preferences, and other apps' workspaces |
| Files written | The workspace and `writable` | The same, plus the app's own build caches: one folder per app, kept across its sessions so its builds stay warm. Cargo, pip, uv, npm, yarn, bun, go, gradle, deno, clang, Homebrew and tools that follow `XDG_CACHE_HOME` are pointed there; a tool that keeps its cache in `~/Library/Caches` or `~/.cache` with no variable to move it (SwiftPM, poetry, Playwright and the like) can't write it. Never the user's own caches, where a planted entry would later run as the user, outside any sandbox |
| Toolchains | Only what the policy's folders hold | The user's own: `PATH` has `~/.cargo/bin`, `~/.local/bin`, `~/.volta/bin`, `/opt/homebrew/bin` and the like, with `RUSTUP_HOME` set (your `~/.cargo/config.toml` isn't read: the app's cargo folder is its own). The toolchains are read-only: a project that pins a toolchain you haven't installed can't install it |
| Loopback | `toolPorts` only | Any port (every local server, as in a terminal), and commands may listen on loopback |
| Still never | | Credentials, opening apps or Apple Events, the user's own Claude Code settings, skills, hooks and MCP servers, writes outside the session's folders and the app's caches |

Something the agent reads could try to get it to send files online, exactly as with an approved command in a terminal: ask for `contained` where your app doesn't need more, and tell your users what developer access means. Every tool call is still in the task's trace.

In both modes, a command's background jobs live on after it returns, as in a terminal, and end with its engine. Nothing outlives Agneta, except as below.

Known limits, each the same as in a terminal:
- **Loopback reaches every local server** under developer access, not only your app's.
- **A command can leave the job list,** in both modes. Agneta ends a command's process group with its engine; one that starts a session or group of its own (`setsid`, `set -m`, a detached child) can outlive it, and Agneta. The sandbox can't refuse it without breaking ordinary tools (measured: a refused `setsid` is still reached through `posix_spawn`).
- **Other processes' environments are readable,** in both modes. macOS lets any process of the user's, sandboxed or not, read the environment of another one that isn't Apple's own (measured: no sandbox rule stops it). So a command can read what the user's own programs were started with, and the provider key of an engine on an API-key account. Plan sign-ins are in the Keychain, and Agneta's broker tokens are in files, so neither is exposed.

**Changing the engine's mode** (`session/set_mode`, or `session/set_config_option` with `configId: "mode"`) is refused where the mode would leave what Agneta set up: on Claude Code and Codex, a mode that stops the engine asking permission, since Agneta checks each tool call from those questions; on OpenCode, any agent but Agneta's, which carries the session's instructions.

### Instructions

`agneta/instructions.text`, or ACP's `systemPrompt`, sets the session's instructions. Goose, OpenCode and Claude Code use them as the system prompt; Codex appends them to its own instructions, which say how to use its tools ([ENGINES.md](ENGINES.md)).

### The result

- `sessionId`: Agneta's id, never the engine's.
- `_meta.agneta`: `account`, `dedicatedEngine` (whether the session has an engine process of its own), `sandbox` (the mode the task really got, [Sandbox](#sandbox)), and `capabilities`:

| Field | Meaning |
| --- | --- |
| `engine` | `goose`, `opencode`, `claude-code` or `codex` |
| `steer` | `agneta/steer` works |
| `fork` | `agneta/fork` works |
| `instructionsBetweenTurns` | `agneta/instructions/set` works |
| `reportsCost` | Per-call cost is known while the turn runs, so `maxCostUSD` can be enforced |

- `configOptions` and `modes`: the engine's own, passed through (model, thinking effort, mode, …).

**Only Agneta's methods.** An app calls only the methods on this page. Anything else, including an engine's own methods, is refused with `-32601`, and notifications other than `session/cancel` are dropped: an engine's methods would bypass the checks made when the session started. Engine extras are reached through Agneta's methods (`agneta/steer`, `agneta/instructions/set`), which each engine's adapter maps.

Features differ by engine on purpose. Each engine's extras are offered where it has them, never trimmed to what all engines share. Check `capabilities` before offering a feature; a call the engine can't serve fails with `-32014`.

| | Goose | OpenCode | Claude Code | Codex |
| --- | --- | --- | --- | --- |
| Steering | Yes | Yes | Yes | Yes |
| Instructions between turns | Yes | No | No | No |
| Fork | Yes | No | No | No |
| Resume (`session/load`) | Yes | Yes | Yes | Yes |
| Cost | Per call | Per call | At the turn's end | No |

## Model and thinking

A session's settings are the engine's own ACP config options, in `session/new`'s result (`configOptions`), each with its choices and current value. Find them by their standard category rather than an engine's own ids, which differ:

| Category | What | Seen |
| --- | --- | --- |
| `model` | The model (every engine also uses the id `model`) | Codex, Claude Code, Goose, OpenCode. Goose on a Claude plan offers one: Claude Code's own, `current` |
| `thought_level` | Reasoning effort (ids differ: `reasoning_effort` on Codex, `effort` on Claude Code, `thinking_effort` on Goose) | Codex, Claude Code, Goose on a Claude plan; Goose and OpenCode with an API key for models that have it |

- Change one with `session/set_config_option {"sessionId", "configId", "value"}`, before the first prompt or between turns. The answer is the options as they are now: another model may offer other efforts, or none.
- To let people choose before they type, open the session first (it starts the engine but calls no model). Choices may come in groups; a current value may be missing from the choices (Goose reports its configured model without always listing it).
- **The user's defaults come first.** Where the user chose a default model or effort for the provider (Settings → Providers → Model and Effort), a new session already has it: `configOptions` in the result shows it as current. A loaded or forked session keeps what it had. The app can still set its own.
- Changing provider or engine means a new session.

## Turns

`session/prompt {"sessionId", "prompt": [content blocks]}`. Text and images are supported in prompts and in MCP tool results.

While the turn runs, the engine's `session/update` notifications arrive unchanged, with Agneta's session id:
- `agent_message_chunk` and `agent_thought_chunk`;
- `tool_call` and `tool_call_update` (upserts by `toolCallId`; the first sighting may be a placeholder);
- `usage_update` (cumulative context size and used);
- `plan`;
- `session_info_update`.

The result:

```json
{"stopReason": "end_turn", "usage": {"inputTokens": 42, "outputTokens": 7, "totalTokens": 49},
 "_meta": {"agneta/usage": {"modelCalls": 2, "models": ["gpt-x"], "inputTokens": 84, "outputTokens": 14,
                              "cacheReadTokens": 0, "cacheWriteTokens": 0, "cost": null, "costKind": "estimated",
                              "taskCost": null, "billing": "api-key", "account": "…", "ms": 196.4, "msToFirstToken": 147.1,
                              "basis": "engine-ledger"},
           "agneta/limit": {"limit": "maxSeconds", "value": 1800}}}
```

- **`agneta/usage`** comes from the engine's own records, one entry per model call, summed over the turn. Nothing is counted from stream items.
  - `basis` says where the numbers come from: `engine-ledger` (the per-call records) or `engine-turn-totals` (the engine's own totals for the turn, which Claude Code needs; see [ENGINES.md](ENGINES.md#claude-code)).
  - `costKind` is `estimated` for API keys, and `plan-equivalent` for subscriptions, where the plan pays and nothing is charged per call.
  - Unknown values are `null`, never guessed.
  - `usage` is the engine's own figure for the turn, passed through.
- **`agneta/limit`** appears only when a policy limit stopped the turn. `maxTurns` ends with ACP's `max_turn_requests`; time and cost end as `cancelled`, with this field saying why. Limits are checked twice a second. A limit is a hard limit: if the engine hasn't stopped the turn 10 s after Agneta cancels it (stuck in a tool, or ignoring the cancel), Agneta ends the session (which stops its engine), sends `agneta/sessionStopped` with `stoppedBy: "limit"`, and answers the prompt the same way with `"sessionEnded": true` in this field. Load the session again to go on.
- **One turn at a time per session.** A prompt while one runs is refused with `-32011`. To add to a running turn, steer it.

| Method | Effect |
| --- | --- |
| `agneta/steer {"sessionId", "prompt": [blocks]}` | Adds input to the running turn. Returns `{"delivery": "accepted", "runId"}`. Error `-32010` when no turn is running, or it ended before the input arrived |
| `agneta/instructions/set {"sessionId", "text", "mode": "replace" \| "append", "key"?}` | `replace` (the default) sets the instructions; `append` adds a named part (`key`, default `app`) that a later append with the same key replaces |
| `session/cancel` (notification) | Ends the running turn with `cancelled` |
| `session/close` | Ends the session and, if it has one of its own, its engine |

**Waiting for room.** At most 8 turns run at once, and at most 3 per account; up to 32 more wait. A turn waits only behind earlier turns on the same account, so a busy account never holds up another. A waiting turn's app gets `agneta/queued {"sessionId", "position"}`, and the prompt simply returns later. `session/cancel` takes a waiting turn out at once (`cancelled`). A prompt when the queue is full fails with `-32012`.

**Resuming.** `session/load {"sessionId", "cwd", "mcpServers", "_meta"?}` reopens one of the app's earlier tasks after a close or an Agneta restart, within the history retention.
- Pass the tool servers again, since their bearers are per session. The policy and instructions default to the original ones; `_meta` may set new ones, and ask for live trace delivery.
- The engine returns to the same engine home and replays the conversation as `session/update`s before the result. The next turn sees the whole history, and the trace continues with the next sequence numbers.
- The result's `_meta.agneta.resumed` is true.
- It passes the same checks as `session/new`: the provider (granted, not paused), the engine (still allowed), the policy against the grant, the tool servers and the cost limit.
- Loading a session that's already open, or another app's, fails with `-32602`. A task that ran without built-in tools must be resumed without them.
- A task resumes only on the engine that saved it, whatever the provider's default is now. If the app may no longer use that engine, or it isn't on this Mac any more, loading fails with `-32602` and the current access in `data.agneta.access`; if it stores sessions differently now, with `data.agneta.stateChanged {"engine", "saved", "current"}`. Start a new task instead.
- Its cost goes on from where it was, so `maxCostUSD` counts the whole task, and so do the trace's turn and model-call numbers.
- Instructions appended with `agneta/instructions/set` aren't restored. Set them again after loading.

**Forking.** `agneta/fork {"sessionId", "mcpServers", "cwd"?, "_meta"?}` starts a new task with a copy of one of the app's tasks, open or finished: for example, to ask about a run without changing it.
- The new task has its own id, engine and trace. Its result's `_meta.agneta.forkOf` names the source. Prompts to it never touch the original.
- Its policy is `_meta`'s if given; otherwise it's the original's with `tools: "read"`.
- It keeps the original's instructions unless `_meta["agneta/instructions"]` sets new ones.
- It passes the same checks as `session/new`, and like a load it needs the engine that saved the original. Its cost starts from zero: it's a task of its own.

**Pause.** The user can pause an account in Agneta's menu. Then nothing new starts on it: `session/new`, `session/load`, `agneta/fork` and `session/prompt` fail with `-32013` and `data.agneta.paused`, and so does a prompt that was waiting in the queue. A turn already running finishes. Open sessions stay open and take turns again once the user resumes the account.

**Provider limits.** The engine first retries a provider's 429 itself. If the limit holds, the turn fails with the engine's error, and Agneta adds `data.agneta.rateLimited {"account", "message", "resetsAt"}`. It also sends `agneta/rateLimited` with the same fields and the `sessionId`, and Agneta's menu marks the account. `resetsAt` (UTC) is read from the provider's own words, such as "try again in 20s" or "resets 3pm", and is null when they give none. Retry after it, or use another account.

**Signed out.** When the engine says the account isn't signed in, the error keeps the engine's code (usually `-32000`, ACP's `auth_required`) and gains `data.agneta.needsSignIn: "<account id>"`. Agneta's menu asks the user to sign in again; tell the user to open Agneta.

**Stopped by the user.** Someone may press Stop in Agneta's menu. The app then gets `agneta/sessionStopped {"sessionId", "stoppedBy": "user"}`, and the running turn ends as cancelled. Show it as stopped by the user, not as an error.

**Engine stopped.** If the engine process ends on its own (it crashed, or was killed), its sessions end at once: the app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "engine"}` and a running turn fails. Resume the task with `session/load`, which starts a fresh engine.

## Permissions

With `approval: "ask-app"`, the engine's `session/request_permission` requests reach the app with Agneta's session id. Agneta applies two rules:
- **"Always" becomes "once".** An engine may keep an "always" answer beyond the session (OpenCode keeps it for the whole project), so Agneta answers with the matching "once" option. Where the engine offers no "once" option, the call is declined.
- **Native runners are checked first.** Claude Code and Codex run their own tools, so Agneta answers each request for a built-in tool by its contract with every engine (`BuiltinTools`), before the app is asked: nothing built in under `app-only`; reading and searching (`read`, `search`) under `read`; also editing (`edit`, `delete`, `move`) under `workspace`; and never `fetch` while the network is `none`, nor `execute` apart from Claude Code's Bash, whose commands run through Agneta's broker. Under developer access the request goes to the app (or the policy answers) whatever its kind. Kinds that run nothing of their own (`think`, `switch_mode`) pass. `other` passes only for a tool known by name to run nothing (finding deferred tools, a to-do list, a question, plan mode): adapters report every tool without a reporter of their own as `other`, Claude Code's Monitor (which runs commands) among them. A request with no kind, or one ACP doesn't define, is refused, since Agneta can't tell what it would run.
- **Claude Code offers only the tools the policy names.** Agneta passes the exact built-in set (`tools`): none but tool search under `app-only`; `Read`, `Glob`, `Grep` under `read`; also `Edit`, `Write`, `NotebookEdit` under `workspace`; plus `Bash` (with `TaskStop` and `Agent`) whenever tools go beyond `app-only`, its commands run through Agneta's broker by Claude Code's shell prefix, never inside the engine's sandbox; Claude Code's own set under developer access, without the tools that reach the claude.ai account or devices, and Monitor and PowerShell. Every session, a resumed one included, is set to the `default` mode, which asks (the adapter starts in `auto`, which doesn't), and gets the same options on resume.
- **The app's own tools are the app's.** A request for a tool of one of the app's MCP servers isn't refused by that contract (Codex asks for those as `execute`). Agneta trusts only what the engine's adapter vouches for: Codex's own MCP approval marker, Claude Code's tool names. A server can't take a name an engine uses for its own tools (Claude Code's `workspace` and `acp`; Codex's `codex_apps` and `agneta`, its shell): `session/new` refuses it with `-32602` and `unenforceable: ["mcpServers"]`.

Every decision is in the trace's `permission` records: who decided (`asked-app`, `allowed-by-policy`, `refused-by-policy`), the answer, and how long it took.

## The trace

Agneta writes a full trace of every task ([DIAGNOSTICS.md](DIAGNOSTICS.md), format `agneta/trace`). An app can read its own tasks, and only those.

- **Live:** with `"agneta/trace": {"live": true}` on `session/new` (or `session/load`), records arrive as `agneta/trace {"sessionId", "records": [...]}` notifications. They come in sequence order, batched every 100 ms in groups of up to 64, from `meta` to `end`. An app that reads too slowly to keep up (10,000 records waiting) gets one last `agneta/trace {"sessionId", "records": [], "overflow": {"after": <seq>}}`, and live delivery for that task stops; read on from `after` with `agneta/trace/read`. `"include": ["acp"]` adds the raw JSON-RPC frames of both connections.
- **Afterwards, or after a reconnect:** `agneta/trace/read {"sessionId", "after": <last seq>, "types"?: [...], "limit"?: 500}` returns `{"records", "next", "complete"}`. Page until `complete`. It works for running and finished tasks within the history retention, up to 5,000 records or about 8 MB a page (always at least one record).

Every record has `v`, `seq` (gapless), `t` (UTC with microseconds), `mono` (nanoseconds since the trace was opened or resumed), `task`, `turn` and `type`. Secrets are masked. The record types are listed in [DIAGNOSTICS.md](DIAGNOSTICS.md#record-types).

## Errors

| Code | Meaning |
| --- | --- |
| `-32000` | Usually the engine's "sign in first"; with `data.agneta.needsSignIn`, the account needs signing in again in Agneta |
| `-32001` | Not paired, or access removed (`data.agneta.needsPairing`) |
| `-32002` | The user didn't allow the app |
| `-32010` | `agneta/steer` with no turn running |
| `-32011` | A turn is already running in this session |
| `-32012` | Too many turns waiting; try again shortly |
| `-32013` | The account is paused in Agneta (`data.agneta.paused`); a turn already running finishes |
| `-32014` | This session's engine can't do that (`data.agneta.engine`); check `capabilities` first |
| `-32015` | What the engine needs is still downloading (`data.agneta.engineDownloading`: `engine`, `received`, `total` bytes); try again shortly |
| `-32601` | Not a method Agneta offers; engines' own methods aren't reachable |
| `-32602` | Invalid parameters. For a policy, server list or mode, `data.agneta.unenforceable` names the field. "Unknown session" also uses it: another app's session, or an ended one |
| `-32603` | Agneta couldn't do it: the engine didn't start (no answer within 60 s) or stopped, or the app disconnected meanwhile |
