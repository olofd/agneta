# Engines

Agneta doesn't run the agent loop itself. An **engine** does: an agent program that speaks ACP over stdio, calls the model, and calls tools. Agneta starts it in a sandbox, configures it for the session, and routes its stream to the app. 

**Providers and engines.** Which engines can serve which kind of provider is one fixed table (`ProviderEngines`):

| Provider | Engines, most preferred first | Why |
| --- | --- | --- |
| ChatGPT plan | Codex | The plan's sign-in is Codex's own |
| Claude plan | Claude Code, Goose | The sign-in is Claude Code's own; Goose runs that same Claude Code |
| OpenAI API key | Goose, OpenCode, Codex | Any engine that speaks OpenAI |
| Anthropic API key | Goose, OpenCode, Claude Code | Any engine that speaks Anthropic |

- **The app picks** each task's provider and engine, among what its grant allows: the providers the user ticked, and the engines (all of them unless the user narrowed them under Advanced). The pair must be in this table and on this Mac ([APP_PROTOCOL.md](APP_PROTOCOL.md#access)).
- **The default** is the provider's, set per kind of provider in Settings → Engines (saved as `engine.<kind>`), else the most preferred one here; when the grant doesn't allow it, the first allowed one. A task that names no engine runs on it.
- **A resumed or forked task** always runs on the engine that saved it, which the grant must still allow.
- **Downloads.** An engine that downloads first (OpenCode, Claude Code's adapter, Codex's runtime in releases) starts downloading when it becomes a provider's default for a provider in use, or a task asks for it; tasks meanwhile are told to try again shortly (`-32015`, with the progress). Once installed, it's checked against its pin at each launch before it runs.

Accounts name no engine, and adding one asks nothing about engines.

Everything an engine does its own way lives behind one adapter (`Sources/AgnetaKit/Engine/*Adapter.swift`, protocol `EngineAdapter`): how it starts and what its sandbox must allow, the shape of `session/new` and `session/load`, how instructions and steering are sent, how a tool's identity is read, how a conversation is exported for a fork, and where per-call usage is recorded. Apps see one contract; the `capabilities` on each session say which extras its engine has ([APP_PROTOCOL.md](APP_PROTOCOL.md#the-result)).

| | Goose | OpenCode | Claude Code | Codex |
| --- | --- | --- | --- | --- |
| Version | `goose-acp` 1.59.2 | 2.3.0 | The user's install (2.1.x measured), through `claude-agent-acp` 0.107.2 | The user's install (0.166 or later), through `codex-acp` 2.7.0 on Node 24.19.0 |
| Shipped | Bundled, pinned (`Engines/goose.lock`) | Downloaded when first picked or asked for, pinned (`Engines/opencode.lock`) | Adapter downloaded on first use, pinned (`Engines/runtimes.lock`); Claude Code is the user's own | Adapter and Node pinned (`Engines/codex.lock`): bundled in development builds, downloaded on first use in releases; Codex is the user's own |
| Accounts | Claude plan, OpenAI key, Anthropic key | OpenAI key, Anthropic key | Claude plan, Anthropic key | ChatGPT plan, OpenAI key |
| Processes | One per session with built-in tools; app-only sessions share one per account | One per session | One per session | One per session |
| Built-in tools run by | Agneta's tool broker | Agneta's tool broker | The engine (Agneta checks each call) | The engine (Agneta checks each call) |
| Steering | `_goose/unstable/session/steer` | `_session/steering` | `_session/steering` | `_session/steering` |
| Instructions | System prompt, replaceable between turns | The session agent's system prompt, at launch | `_meta.systemPrompt`, at `session/new` | Appended to Codex's own, at `session/new` |
| Fork | Export and import | Not offered | Not offered | Not offered |
| Per-call usage | Its session database | Its session database | Its stream (`_claude/sdkMessage`) | Its rollout files |
| Cost | Per call | Per call | List-price, at the turn's end | None |

## Goose

[Goose](https://github.com/aaif-goose/goose) (Apache-2.0) is ACP-first: `goose-acp` is a small Rust binary for both Mac architectures with no telemetry or updater. One process can serve many sessions, because its per-session settings travel over ACP.

- **Isolation.** A private home (`HOME`, `GOOSE_PATH_ROOT`), an explicit environment with nothing inherited, `GOOSE_TELEMETRY_OFF`, `GOOSE_DISABLE_KEYRING` (credentials come from Agneta), session naming off, and mode `approve`, so tool permissions are asked rather than assumed. No user extensions, skills or recipes are loaded.
- **Model catalog.** Every start, Goose downloads the public model catalog from `https://models.dev/api.json` (6.7 MB) into its home, in the background; Goose 1.59.2 has no setting to turn this off ([`model_catalog.rs`](https://github.com/aaif-goose/goose/blob/v1.59.2/crates/goose/src/model_catalog.rs)). It sends nothing of the task's, but models.dev sees the request. OpenCode's equivalent is off (`OPENCODE_DISABLE_MODELS_FETCH`).
- **Tools per session.** `_meta.enabledExtensions` lists the app's MCP servers plus only the built-ins the policy allows: none for `app-only`; `tree`, `read_image` and `shell` for `read`; plus `write` and `edit` for `workspace`.
- **Shell.** `GOOSE_SHELL` points at `agneta-shell`, which hands each command to Agneta's tool broker. The broker runs it under the session's stricter tool sandbox ([ARCHITECTURE.md](ARCHITECTURE.md#the-tool-broker)). Under `read`, commands can read the workspace but write only a scratch folder.
- **Instructions** go through `_goose/unstable/session/system-prompt/set`, replacing the system prompt or adding a named part.
- **Fork** exports the source conversation (`_goose/unstable/session/export`) and imports it into a fresh engine.
- **Usage.** Goose's session database (SQLite, read-only) has one `usage_ledger` row per model call, with cache tokens and cost, and every message as the model saw it. The schema is Goose's own and is read by a reader pinned to this version; a mismatch is reported in the trace, not guessed at.
- **Plans.** Goose serves Claude plans, not ChatGPT plans (those run on Codex). A Claude plan uses Goose's `claude-acp` provider, which runs the downloaded `claude-agent-acp` with your installed Claude Code (`CLAUDE_CODE_EXECUTABLE`) under the account's own Claude Code configuration folder.
- **Retries.** Goose retries a provider's 429 itself before the turn fails (about a minute).

The `_goose/unstable/*` methods can change with any Goose release, so the engine is pinned and these calls are tested at every version change.

## OpenCode

[OpenCode](https://github.com/anomalyco/opencode) (MIT) has a broad provider catalogue. `opencode acp` speaks ACP by starting a private `opencode serve` and translating to its HTTP API, which it keeps to itself. Over ACP, per-session instructions, permissions and MCP settings can't be set, and `_meta` isn't passed through. OpenCode reads its whole configuration per process, so **every OpenCode session gets its own process**, configured at launch through `OPENCODE_CONFIG_CONTENT`:

| Need | Configuration |
| --- | --- |
| Instructions | An `agneta` agent whose system prompt is the session's instructions, selected right after `session/new`. An app can't switch to another agent (`session/set_mode` or the `mode` option is refused with `-32602`): it would drop the instructions |
| Only what the policy allows | Permission rules: deny everything, then allow the app's tools (`<server>_*`), read tools for `read`, edit and shell for `workspace`; `ask` instead of `allow` when the app decides (`ask-app`) |
| The app's MCP servers | `mcp.servers.<name>` with the bearer headers, called directly (`codemode: false`) |
| Shell through Agneta's broker | `shell: <agneta-shell>` |
| Nothing from the user | A private `HOME` and `XDG_*`, project config off, Claude Code integration off, model catalogue fetch, updates, sharing, plugins, LSP, formatters, snapshots and file watching off |
| No extra model calls | Session titles off (otherwise one extra model call per session) |
| Per-call usage | `OPENCODE_DB` in the engine home: `session_message` rows with model, tokens (cache included) and cost |

Its sandbox may listen on loopback, for the private server only.

**Known limits:**
- **Instructions between turns and fork** exist in OpenCode, but only through its HTTP API. They're not offered, and calls fail with `-32014`.
- **Plans** aren't offered on OpenCode: it keeps credentials in its own database and refreshes them itself, which would race Agneta's refresh of the same sign-in. OpenCode serves API keys.
- `skill` and, in editing sessions, `opencode_worktree_remove` ignore permission rules and stay in the model's tool list. Skills come only from the private home, where there are none, and the sandbox keeps writes inside the workspace.
- OpenCode's "always allow" persists for the whole project; Agneta turns every "always" answer into "once".
- Tool names are `<server>_<tool>`, split at the first underscore, so an app's server name shouldn't contain one.
- The binary is about 238 MB (Bun).

## Claude Code

The user's own Claude Code, driven through [`claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp). The adapter's source is Apache-2.0, but its released binary embeds Anthropic's proprietary Agent SDK, so Agneta doesn't bundle it: it downloads the pinned release on first use and checks it against its SHA-256.

- **Finding Claude Code.** The Claude desktop app's bundled copies (`~/Library/Application Support/Claude/claude-code/<version>/…`) and command-line installs (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local`), newest first. The user can pick one in Settings. The chosen executable is passed as `CLAUDE_CODE_EXECUTABLE`.
- **Accounts.** Each account has its own `CLAUDE_CONFIG_DIR` and temporary folder. A Claude plan signs in with your installed Claude Code's own login (`claude auth login --claudeai`, run in a hidden terminal); without Claude Code installed, a Claude plan can't be added; Claude Code keeps the credential in the login Keychain, keyed by that folder, and refreshes it itself. Agneta never handles the plan's tokens. An Anthropic key is passed as `ANTHROPIC_API_KEY`.
- **Quiet.** `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, no settings from the user's own files (`settingSources: []`), no prompt suggestions, and MCP servers handed over at start rather than as command-line arguments, where other users of the Mac could read the bearer.
- **Tools.** `disallowedTools` by policy: every built-in for `app-only`; all but `Read`, `Glob` and `Grep` for `read`; `WebFetch`, `WebSearch`, `Task`, `SlashCommand` and `Skill` for `workspace`. App tools appear as `mcp__<server>__<tool>`. Claude Code's own sandboxed tools and the adapter's client-backed ones are MCP servers too (`mcp__workspace__…`, `mcp__acp__…`), so an app's server can't use those names.
- **Permissions.** Claude Code runs its own tools inside Agneta's engine sandbox, which can reach port 443 for the model. So Agneta checks every permission request against the policy first: shell commands and fetches are refused while the network is `none`. Only the `default` and `plan` modes are allowed; modes that stop asking (`acceptEdits`, `auto`, `bypassPermissions`) are refused.
- **Other tasks stay private.** The account's `projects/` folder, where Claude Code keeps every session's transcript, is denied to the engine, except the current session's own folder.

**Usage.** `emitRawSDKMessages` makes the adapter send `_claude/sdkMessage` notifications for assistant messages and results.
- Each assistant message is one model call, with its id, model, input and cache tokens exact. **Its output count isn't:** it's the count at the start of the stream, repeated for every content block. On a two-call tool turn on Haiku, the per-call rows held 37–40 output tokens against 210–230 in the turn's result.
- Each result carries `modelUsage`: the session's running totals per model, side calls included, with a list-price `costUSD`. Agneta takes each turn's share of those totals as the turn's ledger (`basis: engine-turn-totals`) and keeps the per-call sums beside it as `callLedger`. Per-call rows are marked `outputPartial`.
- Exact per-call output would need the adapter's `stream_event` messages, which come once per token, so they aren't used.
- Cost arrives only at the turn's end, so `maxCostUSD` can't stop a turn in time and is refused for Claude Code.

## Codex

The user's own Codex (`codex app-server`), driven through [`codex-acp`](https://github.com/agentclientprotocol/codex-acp) (Apache-2.0), with a pinned Node runtime. Development builds bundle both; a release downloads them together, as Codex's runtime (`Agneta-codex-runtime-<version>-<arch>.zip`, attached to the release and pinned by the app's `codex-runtime.lock`), the first time a Codex account or app needs them.

- **Finding Codex** works as for Claude Code (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), passed as `CODEX_PATH`. Codex 0.166 or later is needed for the app-server schema the adapter uses.
- **Accounts.** Each account has its own `CODEX_HOME`, with a `config.toml` Agneta rewrites at every start: credentials in the login Keychain (keyring mode: "Codex Auth", keyed by that folder, never a file the engine's own tools could read; separate from the user's own Codex sign-in), update checks, analytics and feedback off, no network for sandboxed commands. Web search is off (it runs on OpenAI's servers without asking), and so are the features that would bring tools beyond the policy: the ChatGPT account's connectors (`apps`), plugins, browser and computer use, image generation, dependency installs, the background daemon and hooks. Checked against Codex 0.167. A ChatGPT plan signs in with `codex login` in that folder, and Codex refreshes its own sign-in. This is separate from Goose's ChatGPT sign-in, so two programs never refresh the same login. An OpenAI key is passed as `OPENAI_API_KEY`.
- **Modes.** Codex starts in `workspace-write` for `workspace` sessions and `read-only` otherwise. Only those two are allowed. `agent` ("Auto review") hands approval questions to Codex's own model reviewer instead of Agneta, and full access stops asking, so both are refused.
- **Instructions** are appended to Codex's own developer instructions (`systemPrompt` with `mode: "append"`). Replacing them would remove what tells the model how to use Codex's tools.
- **Tools.** App tools appear as `mcp.<server>.<tool>`. Edits ask permission first and work (`apply_patch`).
- **Usage** comes from Codex's rollout files in `CODEX_HOME/sessions`: one `token_usage_record` per model call, with the response id and cached tokens. They carry no cost. On a ChatGPT plan, the same files carry the plan's own limits (used percent, window, reset), which Agneta shows in its menu.

**Known limit: Codex can't run shell commands inside Agneta.** In every allowed mode, Codex runs commands without asking and wraps each in its own `sandbox-exec`, which macOS won't nest inside Agneta's sandbox. The command fails with `sandbox_apply: Operation not permitted`, with no permission request and no tool call in the stream. This fails closed: nothing runs. Today it changes nothing in practice, because Agneta refuses shell commands on Claude Code and Codex while the network is `none`, which is the only network setting supported.

## Adding an engine

An engine is one type that implements `EngineAdapter`. Start from the closest existing adapter, and test it with the scenarios in `Tests/AgnetaKitTests` (`AppScenarioTests` is parameterized by engine). Declare what it can do in `capabilities` honestly: a feature the engine can't do is refused with `-32014`, never faked. Anything that would let the engine act outside the policy (a mode that stops asking, a tool outside the sandbox) is refused in the adapter.
