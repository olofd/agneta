# Privacy and threat model

What leaves your Mac when an app runs a task through Agneta, what stays on it and for how long, what each button removes, and what Agneta defends against and what it doesn't.

## What leaves your Mac

| What | Where it goes | Why |
| --- | --- | --- |
| The task's prompts and instructions, the conversation so far, and what its tools returned (including the files an engine read) | Your AI provider (OpenAI or Anthropic), through the engine, over HTTPS | That is how the model sees the task |
| Tool calls to the app's own tools | The app, on this Mac (loopback) | The app's tools run in the app |
| A request for the public model catalog, with nothing of yours in it | models.dev, from Goose when it starts | Goose looks up model names and limits there and has no setting to stop it ([ENGINES.md](ENGINES.md#goose)) |
| Update checks, once you allow them: a request for the update feed, which carries Agneta's version and nothing of yours; and the update itself, when one installs | GitHub (`github.com` and its download host), from release builds only | Agneta asks before its first check and checks about once a day; Settings → General turns checks off. Sparkle's system profile, which would send the Mac's model and macOS version, stays off ([RELEASING.md](RELEASING.md#3-updates-in-the-app-sparkle-2)) |
| Downloads of components you choose: Claude Code's adapter when you add a Claude plan, OpenCode when it becomes a provider's default or a task asks for it, Codex's runtime (Node and codex-acp) when Codex is first used | GitHub (`github.com` and its download host) | Each is a pinned release file, checked against its SHA-256 before use; the request carries nothing of yours |
| Under developer access: whatever commands and the engines' web tools send | Any host they connect to; web searches go through OpenAI's or Anthropic's servers | The app's grant allows a terminal's reach ([APP_PROTOCOL.md](APP_PROTOCOL.md#sandbox)) |
| Nothing else from Agneta | | Agneta has no servers and sends no telemetry |

Engines are run with their own telemetry, update checks, analytics and feedback turned off where they allow it ([ENGINES.md](ENGINES.md)). On Codex, the features that bring tools of their own (the ChatGPT account's connectors, plugins, browser and computer use) are off. When contained, Codex's web search (which runs on OpenAI's servers) is off too. Under developer access, Codex's web search and Claude Code's web fetch and search are on, as in a terminal. What your provider keeps, and for how long, is set by your account with them.

## What stays on your Mac

| What | Where | Kept |
| --- | --- | --- |
| Task history: titles, apps, accounts, turns, usage, outcome | Agneta's database | As long as task history (30 days by default; Settings → Privacy) |
| Each task's trace: prompts, tool calls and results, model calls, decisions, timing | `Traces/`, one owner-only file per task | As long as its history |
| An engine's own record of the conversation, so the task can resume | The engine's home (`Engines/`), Claude Code's transcripts in the account's folder, Codex's sessions in the account's `CODEX_HOME` | As long as its history: each goes with its task. A task that ran on Goose without built-in tools shares its account's engine: Agneta asks that engine to delete the task's session, then rewrites its database so no file keeps the deleted words |
| Agneta's own log: events, ids, names, counts and timing, never content, tokens or keys | `~/Library/Logs/Agneta/` | 7 days |
| Downloaded components (Claude Code's adapter, OpenCode, Codex's runtime) | `Runtimes/` in Agneta's data folder | Until Reset; an update keeps them while their pin is unchanged |
| Update settings, the last check's time, and an update downloaded but not yet installed | Agneta's preferences; `~/Library/Caches/com.objectivecoder.agneta/` | Until the update installs, or Reset |
| API keys and the diagnostics token | Agneta's Keychain items | Until removed |
| Plan sign-ins | Codex's and Claude Code's own entries in the login Keychain, one per account | Until signed out (Sign Out and Reset run each one's logout; when one can't run or fails, Agneta says which entries may remain and how to delete them in Keychain Access) |
| What tasks wrote | The workspace the app named, or the app's own workspace (`… Workspaces/<grant>`) | Until you delete it, or Reset for the app's own workspace |
| Each app's build caches (developer access) | `… Workspaces/.build-caches/<grant>` | Until Reset |

Everything Agneta writes is readable only by your user account (folders `0700`, files `0600`).

## What each action removes

| Action | Effect |
| --- | --- |
| **Stop** (a task) | The task and its engine stop now. Its history and trace stay. |
| **Pause** (an account) | Nothing new starts on the account; a running turn finishes. Nothing is removed. |
| **Remove Access** (an app) | The app's token stops working, its tasks stop and its connections close; the grant is deleted. Its tasks' history, its own workspace and its build caches stay. |
| **Sign Out** (an account) | Its key or sign-in is deleted (Claude Code and Codex sign out of their own entries), and so are the account's folder and its engines' homes. Its tasks' history and traces stay until they expire. |
| **Clear History** | Every finished task's history row, trace and engine home is deleted, and so are Claude Code's transcripts and Codex's session files of those tasks. A task that shared its account's Goose has its conversation deleted from Goose's storage; until Goose has done so, Agneta keeps a list of those conversations (account, engine and session id, nothing of their content) and asks again each time it starts and whenever history is cleared. If Goose can't delete one, Agneta says so. |
| **Reset Agneta** | Everything above, and every account, grant, setting, log, cache, download, the apps' workspaces and build caches, Agneta's Keychain items and its login item. Downloads under way stop first. Plan sign-ins need Claude Code's or Codex's own logout: if one isn't installed or its logout fails, Reset finishes the rest and then names the Keychain entries that may remain. |

## The diagnostics token

Off until you create it (Settings → Advanced → Diagnostics). A tool holding it, such as Claude Code, can read **every task's trace on this Mac, prompts and tool results included**, through a local MCP server on loopback that refuses browsers. It can't start tasks, change settings or reach accounts. Turning diagnostics off, or making a new token, stops the old one at once.

## Sharing a trace

`agneta-diag export <task> --out <file> --redact-content` (or Export Diagnostics in a task's details, with "Leave out content, names and paths" on) writes a copy fit to attach to a bug report. It keeps the trace's structure, timings, sizes, token counts and costs, and what's structural: record kinds, statuses, decisions, model and engine names. Everything else is removed and replaced with its size: prompts, tool input and output, instructions, error text, app and account names, identifiers and every path. Tool and server names become tokens, the same within one export and different in the next. Without `--redact-content` the export is the whole trace: share it only with someone you'd show the task to.

## Threat model

What Agneta protects: your AI accounts (credentials and spend), your files, and what your tasks contain.

| Who | What Agneta does | Status |
| --- | --- | --- |
| **An app you allowed** | It gets the accounts you picked, at most the tools and folders it asked for and you saw, in the sandbox mode you chose, and a token. Every session is held to that grant; anything beyond it is refused. You see and can stop each task. A verified app's token works only for that app's signature | Defended |
| **A program you didn't allow** (another app, a sandboxed app, a script) | It can't use Agneta without pairing, and pairing needs your approval in Agneta's own window. Before pairing it can learn which kinds of provider you've connected (a Claude plan, an OpenAI key) and which engines are on this Mac, never which accounts, and ask Agneta to show its add-provider window. An app Agneta can't verify must show a code you compare | Defended |
| **The model, or text it reads** (a prompt injection in a file, a web page an app fetched, a tool result) | When contained, the engine and its commands run sandboxed: only the policy's folders, no network for commands, nothing launched outside, and built-in tools beyond the policy refused. Under developer access, a terminal's reach (below) | Defended, with the limits below |
| **A web page in your browser** | Agneta's ports refuse requests carrying an `Origin`, which browsers always send | Defended |
| **Other users of this Mac** | Everything Agneta stores is owner-only; it listens on loopback only | Defended |
| **Someone on your network** | Nothing listens beyond loopback; engines reach providers over TLS | Defended |
| **Unsandboxed code running as you** | It can already read your files and drive your apps. Pairing slows it down (it must get past the approval window) but can't stop it | Out of scope |
| **Your AI provider** | It sees what the model is sent, under your agreement with it | Out of scope |

### Limits

- **Goose on a Claude plan isn't held to the policy's tool rules.** Its Claude Code uses all its own tools and your claude.ai connectors, as in Terminal; only the folders it can reach are limited. Agneta offers it as a choice and says so where engines are chosen; Claude Code directly is held to the policy. So it provides developer access only, and a contained task can't run on it.
- **An engine can reach any host on port 443.** macOS's sandbox filters by port, not host, and engines need HTTPS for their provider. A tool can't use that, but the engine process itself could ([CONTAINMENT.md](CONTAINMENT.md#known-limits)).
- **Other programs' environments are readable,** to any process of yours, sandboxed or not (macOS doesn't let a sandbox hide them). A command can read what your own programs were started with, and the key of an engine on an API-key account. Plan sign-ins stay in the Keychain.
- **On a ChatGPT plan, Codex's saved sessions are the account's:** every task on it, other apps' included, can read and change them (a session's rollout is in the account's Codex folder, which its engines write). Claude Code's other tasks are kept out.
- **The app's own tools run in the app,** with the app's permissions: Agneta doesn't confine them.
- **Claude Code's and Codex's other built-in tools (reading, editing, fetching) run inside the engine's sandbox,** checked by Agneta from their permission requests; their commands go through the stricter command sandbox.
- **Developer access is a terminal's reach,** the default for apps that edit files and run commands, unless you choose Contained: your home folder apart from a list of known credential and private-data locations, sandboxed apps' containers and Agneta's data, the internet, your toolchains and every local server. It's a list: another app's own data that it doesn't name (an unsandboxed app's folder under `~/Library/Application Support`) is readable, as in Terminal. Something the agent reads could get it to send your files online, as with a command you approve in a terminal. A command can also detach from its process group and outlive its task, in either mode. Builds use each app's own caches, never yours. Apps paired before sandbox modes existed stay contained. Choose Contained for an app that doesn't need more ([APP_PROTOCOL.md](APP_PROTOCOL.md#sandbox)).
- **Development builds are signed ad hoc,** so an app built that way can't be verified; it pairs with a code.
- **The sandbox relies on `sandbox-exec`,** which macOS marks deprecated ([CONTAINMENT.md](CONTAINMENT.md)).
