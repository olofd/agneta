# Agent capabilities: the plan

> "I want agents to be as powerful as possible through Agneta." (the maintainer, 2026-11-19)

An agent running through Agneta should be able to do what the same agent does in a terminal: build, test, run servers, fetch what it needs, use subagents. The difference should be only that Agneta can prove what it reached. This plan lists what holds agents back today, then the work that removes each limit, in order.

**The rule every step keeps:** power comes from widening what Agneta enforces, never from trusting the engine. Each widening is something the app asks for in its policy and the user sees when pairing. A policy Agneta can't enforce is still refused, never quietly weakened ([APP_PROTOCOL.md](APP_PROTOCOL.md#agnetapolicy)).

## Where agents are held back today

| Capability | Goose, OpenCode | Claude Code | Codex |
| --- | --- | --- | --- |
| Shell commands | Yes, through the broker | Refused: they'd run in the engine's sandbox, which reaches port 443 | Fail: its own `sandbox-exec` can't nest inside Agneta's |
| Commands reach the network | Never (only `toolPorts`, `toolSockets`) | – | – |
| Commands listen on loopback (a test server, `cargo test` binding a port) | Never (`network-bind` denied) | – | – |
| Commands leave something running (a dev server, a watcher) | Ended when the command exits | – | – |
| Developer toolchains (`~/.cargo`, `~/.rustup`, `/opt/homebrew`, pyenv) | Only if the policy grants them as readable; `HOME` is a scratch folder, so `~/.cargo/bin` isn't found by default | – | – |
| Web fetch | No | Refused (`WebFetch` off) | Off |
| Web search | No | Off (`WebSearch`) | Off (`web_search = "disabled"`) |
| Subagents | – | Off (`Task`) | – |
| Skills, slash commands | Off | Off (`Skill`, `SlashCommand`) | – |
| Folders | The workspace and the folders granted at pairing; a task can't ask for more | Same | Same |

## The work, in order

### 1. Commands on every engine (the brokered shell)

All three engines' commands go through the same broker and sandbox, so one network rule covers them all, and every command is in the trace.

- **Claude Code.** Set `CLAUDE_CODE_SHELL_PREFIX` to `<agneta-shell> -c`, with the broker's socket and token in the environment. Read in the pinned Claude Code: the prefix is split at its last ` -`, and the whole command, snapshot sourcing and current-folder bookkeeping included, runs as `'agneta-shell' -c '<command>'`, which is agneta-shell's existing usage. Claude keeps its own Bash tool, background commands included.
  - The broker's profile must read Claude's shell snapshot and write its current-folder file, both in the engine's temporary folder: give each Claude Code engine a temporary folder that the session's tool profile may use.
  - `BuiltinTools.nativeRunnerMayUse` then allows `execute` on Claude Code, since it runs through the broker. Codex stays refused until step 2.
  - Grep and Glob still run ripgrep inside the engine; they only read, which the policy already allows.
- **Codex.** Turn its own shell off (`shell_tool = false`, `unified_exec = false` under `[features]`, both real flags in Codex 0.167) and give it Agneta's: `agneta-shell --mcp`, a small stdio MCP server with one `shell` tool that sends each command to the broker. That is the first engine-agnostic shell tool: any future engine that can't hand over its shell gets the same one.
  - Agneta adds it to the session's MCP servers itself. It's Agneta's, not the app's, so the rule that refuses stdio servers from apps still holds.
- **Measured, on the real engines, with the network off:** `cargo build --offline` works, `curl https://example.com` fails, and the trace shows the broker ran each command. The adapter versions are pinned, so this test reruns at every pin bump. A Claude Code that stops honouring the prefix fails it.
- **Docs:** ENGINES.md says the adapter has client-backed `mcp__acp__…` tools, but the pinned `claude-agent-acp` 0.107.2 has none (its terminal methods are only for sign-in). Correct that with this change.

### 2. Commands that work the way a developer's do

Inside the same sandbox, nothing about these widens what a command can send off the Mac.

- **Toolchains readable by default.** Add the standard developer locations to the tool profile's read-only system list when they exist: `~/.cargo` and `~/.rustup` (read-only; a build's `target` stays in the workspace), `/opt/homebrew`, and the common Python and Node managers. Point `CARGO_HOME`, `RUSTUP_HOME` and `PATH` at them, so `cargo` is found although `HOME` is the scratch folder. Downloading crates still needs step 3; a vendored or already-fetched build works offline.
- **Loopback servers inside a command.** Let a command listen on loopback and connect to what it listens on, as the engine profile's `ownLoopbackServer` already does for OpenCode. Tests that start a local server and builds that start a helper then work. Nothing outside the sandbox can reach it except another process of the same session.
- **Session-lived background jobs.** Today the broker ends anything a command leaves running when the command exits. Add a background mode: a job started with `&` or by an explicit flag keeps running until the session ends, is listed in the task's trace, and is stopped with its process group when the session ends, is cancelled or hits a limit.

### 3. Network for commands, opt-in

A new policy value, `"network": "any"`, that the app asks for and the user sees when pairing ("may use the internet from commands"). Commands get outbound TCP 443 and 80 to any host, which is no more than the engine already has. Claude Code's `WebFetch` and Codex's network come back under the same value.

This is a real loosening: a prompt injection could make a command send workspace files anywhere. It's offered because some work can't be done without it (installing dependencies, fetching data), and the user decides per app. `none` stays the default.

### 4. A host allowlist that Agneta can enforce: its own proxy

Seatbelt can't filter by host name, but it can restrict a process to one loopback port. So Agneta runs a small HTTPS proxy, and processes are allowed to reach the network only through it:

- **Commands:** `"network": {"allow": ["crates.io", "static.crates.io", "pypi.org", …]}` becomes enforceable. The tool profile reaches only the proxy's port, `HTTPS_PROXY` points at it, and the proxy allows a `CONNECT` only to a listed host. A program that ignores the proxy can't reach anything, so it fails closed.
- **The engine itself:** the same proxy, with the provider's hosts, ends the biggest known limit in [PRIVACY.md](PRIVACY.md#limits): "An engine can reach any host on port 443." Each engine's own network is then only its provider (and its sign-in hosts on a plan).
- **Web fetch for allowed hosts:** `WebFetch`, Codex's network and Goose's fetch can come back for the allowlist alone.
- **Measured:** per engine and per toolchain, that everything works through the proxy and that a host outside the list is refused, with the refusal in the trace. Claude Code, Codex, Goose and OpenCode are each expected to honour `HTTPS_PROXY`. That is unproven, and has to be measured for each before its own traffic is moved.

### 5. The engines' own features

Each one comes back once it's proven to stay inside the policy:

- **Subagents** (Claude Code's `Task`). The pinned Claude Code asks permission for each subagent's tool calls under their own kind, which `BuiltinTools` already treats as checkable. That has to be proven in a test (a subagent's shell command reaches the broker and the policy) before `Task` comes off the disallowed list.
- **Skills and slash commands.** No user settings are read (`settingSources: []`), so there are none today. Let an app supply its own skills as a folder in its policy, read-only, so an app can ship its workflows to the agent.
- **Web search** (Claude Code's `WebSearch`, Codex's `web_search`). These run on the provider's servers, outside any sandbox; what leaves is the query text, which an injection could fill with workspace content. So they come back only as their own opt-in policy field, shown when pairing.

### 6. More folders during a task

A task can only use the folders granted when the app paired. Add a request an engine or app can make mid-task ("this task wants to read ~/Data/samples"), shown in Agneta's own window like pairing. Once approved, it applies to that task alone, unless the user ticks "for this app". The profile is regenerated for the next command; the engine's own sandbox can't widen while running, so the engine restarts with the session resumed.

### 7. Proof that it all works: the capability matrix

The support matrix from the review's product ideas ([FOLLOW_UPS.md](FOLLOW_UPS.md)), as a test: for each provider × engine × policy, an end-to-end run on the real engine that tries each row of the table above (a command, an offline build, a loopback test, a background job, an allowed and a refused host, a subagent). It writes the table in this document from the results, and runs at every release and every pin bump. A row that fails is a bug, never a quiet regression.

## Decisions for the maintainer

1. Step 3, `network: "any"` as an opt-in before the allowlist exists: is a per-app "may use the internet from commands" acceptable, or should commands wait for the proxy?
2. Step 5, web search as its own opt-in: worth offering, given what it can leak through queries?
3. Step 6, folders during a task: should an approval apply to that task only by default, or to the app?

## Status

| Step | Status |
| --- | --- |
| 1. Brokered shell for Claude Code and Codex | Planned; the Claude Code hook and the Codex flags are read in the pinned versions, nothing built |
| 2. Toolchains, loopback, background jobs | Planned |
| 3. Network opt-in | Planned; needs decision 1 |
| 4. Agneta's filtering proxy | Planned |
| 5. Subagents, skills, web search | Planned; web search needs decision 2 |
| 6. Folders during a task | Planned; needs decision 3 |
| 7. Capability matrix | Planned; replaces the support-matrix follow-up |
