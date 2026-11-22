# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## 0.8.0 (2026-11-22)

0.7.0 was not published as a release of its own: updating from 0.6.0 brings its changes too, listed under [0.7.0](https://github.com/olofd/agneta/blob/v0.8.0/CHANGELOG.md#070-2026-11-21) below (no engine output in another app's task, crash cleanup of engine homes, a paused account checked again while a session opens, traces read without holding up other apps, and client fixes).

**For apps**

- **Structured results** (`agneta/result`, in `initialize`'s extensions). A session declares JSON Schemas when it opens; a prompt asks for one by name, or every prompt does; the model submits the value through a tool Agneta serves, Agneta checks it against the schema the same way on every engine and answers the model with what's wrong, and the prompt's reply carries `_meta["agneta/result"]`: `valid` with the value, or `invalid` or `missing` with why ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.8.0/docs/APP_PROTOCOL.md#structured-results)). Schemas are a documented subset of JSON Schema 2020-12; anything outside it is refused, never ignored. Additive: an app that doesn't use it sees nothing new, and Agneta listens on nothing new until a session declares results.
- **App server names starting like Agneta's result server's** (`agneta-result`, `agneta_result`, `agneta.result`, `agneta-result__…`, any case) are refused with `-32602`, as engines' own server names already are.
- Sessions that declare results load the app's tools up front (`agneta/appTools` `always`) on every engine. `initialize` says what structured results can do in `_meta.agneta.results`. A request over the result server's 1 MB cap is answered `413`.
- Structured results measured on real models ([ENGINES.md](https://github.com/olofd/agneta/blob/v0.8.0/docs/ENGINES.md)): Claude Code with Sonnet, and Codex with Luna and Terra, each pass every call on to Agneta; all 36 runs of the probe's cases ended valid and correct, Codex's on the constrained case after one correction.
- The result tool's description lists the schema's limits in words (counts, lengths, numeric bounds, patterns). Luna and Terra then met `maxItems` on the first call in 12 of 12 runs, against 0 of 6 before, halving that case's model calls and time. The words are read from the compiled schema, once, within a budget, and are said only for the kinds of value they apply to.

**Fixes**

- **A message nested more than 128 levels deep no longer stops Agneta.** Decoding it recursed past the stack: an app, an engine or a model's tool call could crash Agneta with under 1 KB. It's refused before decoding; a request that deep is answered with `-32600`, and a reply that deep fails the request it answers instead of leaving it waiting.
- **Agneta's local HTTP servers** give a request 2 s to arrive and then hold its connection until it's answered, so idle connections can't block real requests, and refuse malformed header names. The diagnostics server answers MCP's version negotiation and malformed requests as the spec says.

## 0.7.0 (2026-11-21)

**For you**

- **One app's task no longer shows another's engine output.** A shared engine's error output went into every task's trace on that engine, whichever app ran it; it now stays in Agneta's log.
- **Engine homes left by a crash are cleaned up again.** A crash or a full disk before a task's trace was complete stopped the cleanup of unused engine homes for good; now a trace whose owner can't be read only defers it while it may still be written.
- **A task whose trace can't be made says so** to whatever watches the task, as a trace that fails later does.
- **`agneta-diag tasks` reads the task database without changing it,** and waits out a moment the host holds it; `agneta-diag tail -f` follows a resumed task to its current end.

**For apps**

- **A paused account starts nothing new, even mid-open.** An account paused while a session was opening or loading could still get that session; Agneta now checks again before replying and refuses with `-32013`, as a prompt is.
- **Reading a trace never holds up other apps.** A large trace's page was read on the router; it now reads in bounded steps beside it, and the owner check still runs.
- **Trace exports keep a call's token counts** (`input` in a model call and in a turn's ledger) when content is redacted; tool inputs are still removed.
- **`@agneta/client`:** a `close()` that fails or times out leaves the session open, so it can be closed again; a later `loadSession` ends the earlier handle and takes over, its replay going to the new one. An ended handle refuses `prompt`, `steer`, `setMode`, config and instructions, and a finished turn's `steer` rejects with `NoTurnRunningError`.
- **The examples:** Project Chat streams a reply as it's written and says why Agneta stopped a session; Replica Bench keeps a stopped session's reason on screen.

## 0.6.0 (2026-11-21)

0.5.0 was not published as a release of its own: updating from 0.4.0 brings its changes too, listed under [0.5.0](https://github.com/olofd/agneta/blob/main/CHANGELOG.md#050-2026-11-20) in the changelog (per-app limits, sandbox modes for each app, moving to Applications, and more).

**For you**

- **Clearing history gets through when Goose answers late.** A shared Goose that deleted a conversation only after Agneta had stopped waiting kept it on the list for good: asked again, Goose said the session wasn't there, and Try Again couldn't clear it. Agneta now reads Goose's database first and only clears what's left of one it no longer has.
- **A Goose that stops answering costs one wait per clear,** not 10 s for every conversation on the list: the rest wait for the next try.
- **Claude Code's usage is complete call by call.** Each model call's output was the count at the start of its stream (a few tokens), so a task's live usage on Claude Code showed far too little until its turn ended. Agneta now reads each call's final usage from Claude Code's own session transcript, its subagents' calls too, as each call ends.

**For apps**

- **A fork or load right after a task starts finds it.** The task's record reached the disk a moment after `session/new` replied, so on a busy Mac an `agneta/fork` or `session/load` sent at once could be refused with "Unknown session". The record is now written before the reply.

- **Your MCP tools up front, on every engine** ([`agneta/appTools`](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md#agnetaapptools)), additive. Claude Code defers MCP tools behind its tool search: the model sees only their names, and loads each with `ToolSearch` before its first call, so an app whose tool descriptions are the instructions for its job saw them used less than when Claude Code ran with tool search off. `_meta["agneta/appTools"]: {"load": "always"}` on `session/new`, `session/load` or `agneta/fork` turns tool search off for that Claude Code session and leaves `ToolSearch` out, so every tool's description and schema is in the first request; so does Goose on a Claude plan, whose model is Claude Code. Codex defers them too, on every model it lists (its default `gpt-6.1-sol` included): there `always` names your servers in Codex's `direct_only_tool_namespaces`, which bypasses deferral. OpenCode and Goose on an API key already send them all. Without it nothing changes. A load or fork keeps the original's unless its `_meta` sets another; a malformed value is refused with `-32602`. The reply's `_meta.agneta.appTools` says what the session got (`load`, and `upfront`: whether the tools are in the model's first request). `@agneta/client` takes it as `appTools: 'always'` and reads `session.appTools`.
- **A model call's usage on Claude Code is final when it arrives** (`model-call` in the trace, live delivery included): `outputPartial` is `false` and `basis` is `engine-transcript`. It arrives when the call ends rather than at its first content block, and a turn's result waits for its last call's, about 25–50 ms. When the transcript doesn't give a call's final usage in time (5 s after its next call began, or within 1 s of the turn's end), the stream's count is recorded as before, `outputPartial: true`, `basis: engine-stream`; when it gives none at all, calls are recorded from the stream at once. A turn stopped by a limit or cancelled isn't waited for. The turn's ledger is still Claude Code's own totals (`engine-turn-totals`), which include side calls; `callLedger` now adds up the final counts ([ENGINES.md](https://github.com/olofd/agneta/blob/main/docs/ENGINES.md#claude-code)).
- **Only some of the engine's own tools** ([`builtins`](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md#narrowing-the-built-in-tools) in `agneta/policy`), additive. Under developer access an engine brings its whole set (Claude Code's web fetch and search, subagents, skills, plan mode, schedules), and an app had no way to say "developer access, but without these". `"builtins": ["read", "edit", "execute"]` keeps only those groups of the engine's own tools, named the same on every engine (`read`, `edit`, `execute`, `web`, `subagents`, `skills`, `planning`), contained or not; it never gives more than `tools` and `sandbox` do. Claude Code gets the exact tool list, still without what reaches the claude.ai account, Monitor and PowerShell; Codex turns off each group left out; Goose and OpenCode enable only the kept tools. An engine that can't honour a narrowing is refused with `-32602` and why: Goose always offers its skills, and on a Claude plan runs Claude Code; Codex always offers `apply_patch`; both read files only through their shell, so `read` needs `execute` there. Permission requests outside the kept groups are refused, under developer access too. A load or fork keeps it with the policy; the reply's `_meta.agneta.builtins` and the trace's `meta` say what the session has. Without it nothing changes. `@agneta/client` takes it as `policy.builtins` and reads `session.builtins`.
- **Codex's own shell is off in app-only sessions too.** They got no Codex settings of their own, so Codex offered the model its own command tools (`exec_command`, `write_stdin`), which bypass Agneta's broker (inside Agneta's sandbox their commands fail, since Codex's own sandbox can't nest there). Measured on Codex 0.167.0, they're now gone, as in every other session.

## 0.5.0 (2026-11-20)

**For you**

- **Set limits for each app,** in Settings → Apps: what it may spend on your API keys a day, a week or a month (at API prices), how many of its tasks run at once, and how many new tasks it starts an hour or a day. Its usage today is shown first, so you see what a limit would mean. At a limit its tasks stop and the app is told why; extra tasks at once wait their turn. Plans aren't charged per call, so their tasks aren't counted, and Codex, which reports no cost, doesn't run on an OpenAI key while spending is limited. The panel says when an app reaches its limit. Your limits stay with the app when it pairs again.
- **OpenCode's usage is complete.** A turn with several steps recorded only its last, so cost on OpenCode, and a `maxCostUSD` limit, counted too little. Each step's usage is now read once OpenCode has finished writing it.
- **Agneta moves itself to Applications.** Started from its disk image (or from a download macOS runs from a temporary place), Agneta offers to move to Applications and open again from there (a download it was started from goes to the Trash). When the same or a newer Agneta is already there, it offers to open that one instead, and never replaces it. A copy run from the disk image ended when the image was ejected, and apps that open Agneta found it gone.
- **One window on first run.** When an app asks you to connect your AI, or asks for access, while Agneta's welcome window is up, the welcome window closes: the app's window does the same job and says who asked.
- **Homebrew points to the website,** and after installing says to open Agneta from Applications and find it in the menu bar.
- **Clearing history removes a Codex task completely:** Codex deletes its own session, including its copies in Codex's databases, not only its session file.
- **Deleting a task deletes all of its conversation:** a task that ran on an API key without built-in tools shares its account's Goose, which kept the conversation until you signed out. Now Agneta asks Goose to delete it, then rewrites Goose's database so no file still holds the words.
- **Model and Effort… names the engine's own choice:** "Codex's default (its model)" rather than just "Codex's default", so leaving it to the engine says what that means.
- **Choose how far each app reaches:** **Developer access** (as in a terminal: the internet, your home folder and your toolchains, with credentials and Agneta's data kept out) or **Contained** (the task's folders, no internet for commands), when you allow an app and later in Settings → Apps. Apps you allowed before stay contained.
- **Reset tells you when a sign-in may remain.** A plan's sign-in is in the login Keychain, and only Claude Code's or Codex's own logout removes it. When one isn't installed or its logout fails, Reset (and Sign Out) now says which sign-ins may still be there and how to delete them in Keychain Access, instead of reporting a full reset. A reset interrupted and finished at the next launch now finds your Claude Code and Codex first.
- **Reset stops downloads.** An engine download under way when you reset could finish afterwards and put its files back; it's now stopped before anything is deleted.
- **Clearing history keeps trying.** A conversation in an account's shared Goose that couldn't be deleted at once (Goose not there, failing or not answering, its database in use, or Agneta quitting) was lost track of. Agneta now keeps a list of them until Goose has deleted each and no file of its database holds the words, asks again at launch and after each clear, and says when it couldn't, with **Try Again**.
- **A changed model takes effect on the next task.** An account's shared Goose kept the model it started with, so clearing a custom model (or changing the model, key or defaults) didn't apply until Agneta restarted. Now its shared engines restart for the next task; one busy with a task finishes it first.
- **The approval window highlights what Return does:** Allow Once for a verified app, and nothing for an app Agneta can't verify, so nothing draws the eye to letting it in. Always Allow is one click, as before.
- **Clearer details and panel:** a task's details say which account it ran on ("Claude plan", "OpenAI API key") and what its commands could reach, by the mode it ran in; Activity names only an unusual ending (Stopped, Didn't finish); a failed download's Try Again sits under its message.
- **A tidier approval window:** one Access card with the app's tools, folders and mode, **Engines…** in its header, and an unverified app's code on one row. It shows only what the app asked for, with a **Connect** row for a provider you haven't connected yet.

**Security**

- **A contained task can no longer be given a socket or port beyond the app's own and its granted folders.** A policy's `toolSockets` and `toolPorts` weren't held to the grant, nor shown when you allowed the app, so an app could hand a contained task Docker's socket (which starts containers that mount your home) or any local service's port. Under Contained a socket must now be inside a folder you granted the app or served by the app itself, and a port served by the app itself: Agneta connects to it and the kernel says who answered, which must be a process signed by the app's developer (any of its programs), or, for an app Agneta can't verify, the app or a process it started. Otherwise the session is refused when it opens, naming the socket or port and why. It's checked again before each command and about every second while commands or background jobs run, and a session whose app no longer serves one stops (`stoppedBy: "reach"`, with why); in between, a running command can still reach a program that took the app's place, for about 1.5 s (3.5 s if that program is slow to answer, longer under load). At most 16 such sockets and ports per session. Developer access is unchanged. **For apps:** start the server your commands reach before opening the session, and keep it running ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.5.0/docs/APP_PROTOCOL.md#tool-ports-and-sockets)).
- **A token is never issued if the random generator fails.** Apps' tokens, the diagnostics token, the tool broker's token and the trace redactor's salt ignored the system generator's status, so a failure would have left a guessable all-zero value; Agneta now stops instead. The tool broker's token, two UUIDs before, is now 32 random bytes like the rest, and an unverified app's pairing code is drawn uniformly from all six-digit codes.
- **An app that passes its connection on can't borrow another app's identity.** Agneta verifies a connecting app by its code signature; a connection held by more than one process (passed to a signed app the program launched) now counts as unverified, with a code to compare.
- **Claude Code asked about nothing.** The adapter starts every session in `auto`, where Claude Code decides its own permissions: measured, Bash and Monitor ran without a single permission request, so Agneta couldn't refuse commands while a task had no network. Every Claude Code session is now set to the mode that asks, on new and on resume.
- **Resumed Claude Code tasks lost their settings.** A resumed or forked task was opened without Agneta's options, so the adapter fell back to its defaults and loaded the workspace's own `.claude/settings.json`, which the agent can write (hooks, environment, permissions). Measured: a planted hook ran and its environment reached commands. Resume and fork now send the same options as a new session, and Claude Code reads no MCP configuration of its own.
- **Claude Code offers only the tools a policy names.** Agneta passes the exact built-in set, so a tool a new Claude Code adds (Monitor, which runs commands, was one) stays off until Agneta allows it. Read-only commands, which Claude Code ran without asking inside the engine's own sandbox, now go through Agneta's broker like every other.
- **Permission requests are judged by tool name, not only kind.** A request of kind `other` passes only for a tool known to run nothing.
- **A task's sockets follow the folder rules.** A policy's `toolSockets` weren't checked like its folders, so a session could be handed a socket in another app's private storage, Agneta's data or `~/.ssh`. They are now; and a folder not made yet under `/tmp` is checked against its denied parent like any other.
- **Contained commands can't look names up.** A lookup of a made-up host name could carry data out; a contained command now reaches no resolver, only its loopback ports.
- **No command outlives Agneta.** Commands still running, background jobs included, end when their engine ends, when Agneta quits, and when Agneta itself dies. One that starts a session or process group of its own can still outlive them (see the protocol's known limits).
- **Folders swapped for links grant nothing.** A session can replace a folder it may write (its engine's home, its scratch folder, its app's workspace or caches) with a link elsewhere. Agneta now puts its own folders back before each start, never follows such a link, and checks granted folders without following their last link.
- **Writable folders are pinned:** a session can work inside them, but can't rename, remove or replace them.
- **Profiles pass inline** (`sandbox-exec -p`), never as a file an engine could rewrite.
- **Sign-in and sign-out act only on Agneta's own folders.** Before Claude Code or Codex runs on an account folder outside the sandbox, Agneta makes it a real folder again and clears anything an engine planted there.
- **Codex's trusted files** (`.env`, `AGENTS.md`, hooks, skills, rules, prompts) are cleared before each start and read-only to its engines, and so are **Claude Code's account settings files** (`settings.json`, hooks, skills, agents, commands, `CLAUDE.md`).
- **Broker tokens aren't in environments.** Any process of yours can read another's environment, so each engine reads its token from a file of its own. An API-key account's key is still in its engine's environment (a known limit).

**For apps**

- **Quitting Agneta disconnects apps first.** An app with a task open could hear `agneta/sessionStopped` with `stoppedBy: "engine"`, as if its engine had crashed, because Agneta stopped the engines before closing the apps' connections. Apps now see the connection close (the client library's `disconnected`), and their sessions end with it.
- **Limits the user sets** ([the protocol](https://github.com/olofd/agneta/blob/v0.5.0/docs/APP_PROTOCOL.md#limits-the-user-sets)), additive: the extension `agneta/appLimits`; `limits` in the access report and each provider's `uncounted` engines; the error `-32016` when a limit is reached, with `data.agneta.appLimit`; `agneta/limit`'s `"limit": "appSpend"` and `setBy` (`app` for the policy's limits, `user` for the user's); `agneta/queued`'s `waitingFor`; `agneta/usage`'s `app`. `@agneta/client` types them all (`AppLimitError`).
- **Getting Agneta** ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.5.0/docs/APP_PROTOCOL.md#getting-agneta)): how an app tells whether Agneta is installed, running or neither, and takes its user from nothing installed to a working connection, through a stable install page, [agneta.dahlbom.io/get](https://agneta.dahlbom.io/get/).
- **`@agneta/client`, the official TypeScript client** ([clients/typescript](https://github.com/olofd/agneta/blob/v0.5.0/clients/typescript/README.md)): the whole app protocol, typed, in Node 22+ and Electron's main process, with no dependencies. It connects, helps the user get and open Agneta, pairs and keeps the token, follows access changes, opens, loads and forks sessions, streams turns, answers permission requests, reads traces, and maps every error code to a typed error; a raw layer sends anything else. Project Chat and Replica Bench now run on it. Published to npm separately, from `client-typescript-v*` tags.
- **A task stopped mid-turn answers its prompt as cancelled,** as the protocol says, even when the engine never answers it (Stop, a removed provider, narrowed access). Before, the prompt could wait on a shared engine indefinitely, or fail as "The engine stopped".
- **`maxCostUSD` is checked before a prompt is sent:** a task already over its limit spends nothing more.
- **Fewer false rate limits:** an error that merely says "429" or "limit reached" (a token count, a context window, a tool's output) is no longer reported as `agneta/rateLimited`.
- **`agneta/trace/read` no longer reports `complete` before a task's last records are written.**
- **A request answered with a malformed error ends.** An error without a message, or with a string code, was dropped as unreadable, so the request it answered (a turn, a permission request) waited until the connection closed. It now ends as an error, keeping a usable code.
- **A new pairing with `workspace` tools now defaults to developer access.** A session that doesn't send `"sandbox"` runs with the grant's mode, and under developer access `network: "none"` doesn't apply: commands reach the internet and read the home folder. Send `"sandbox": "contained"` to keep the old behaviour. Grants made before this stay contained.
- **Codex reserves the tool server name `agneta`** (its shell): a server of yours with that name is refused on Codex.
- **New fields:** the pairing reply's `unmet`, each provider's `sandboxLevels` and `scope.sandbox` in the access report, and `_meta.agneta.sandbox` in each session's reply.
- **Ask for exactly what you need.** A pairing scope can name the `providers` (kinds, or `"all"`), the `engines` and the `sandbox` (`contained`, `developer` or `any`), and the approval window is narrowed to them. The reply's `unmet` says what wasn't given, and why.
- **Before pairing:** `agneta/catalog` says what Agneta offers (each provider kind, whether one is connected, its engines and their modes) and its `version`, and `agneta/setup` asks Agneta to help the user connect a provider. With nothing connected, the approval window lets the user connect one in place.
- **Claude Code and Codex run commands on the contained path.** Claude Code's Bash goes through Agneta's broker, as Goose's does, and so do Codex's commands, through Agneta's own `shell` tool in place of Codex's: under the session's command sandbox, with no network, every command in the trace. Monitor stays off.
- **Background jobs live on, as in a terminal.** A command's background job keeps running after the command returns, and ends with its engine.
- **`toolEnvironment`** sets variables for commands: your toolchain's `PATH` (inside the session's folders, ahead of everything else), `CARGO_HOME`, `PYTHONPATH`, winning over developer access's own. Empty `PATH` entries are refused. Commands also find the selected Xcode's own `cc`, `git` and `python3`, wherever Xcode is installed.
- **Sandbox per app.** Each app's grant has a mode the user picks at pairing and in Settings → Apps: **Developer access** (the default: full power, as in a terminal, with known credential stores, sandboxed apps' data and Agneta's own kept out) or **Contained** (the session's folders, no internet for commands). A session may ask for less (`"sandbox": "contained"`), never more. Each engine says what it can provide (`sandboxLevels` in the access report): Goose on a Claude plan provides developer access only, and is refused, with why, for a contained task. The reply says what each task got (`_meta.agneta.sandbox`). Apps paired before this, and apps granted fewer than workspace tools (which the approval window offers no choice), stay contained. Under developer access each app builds with caches of its own, never yours; Claude Code keeps its own tools (web fetch and search, subagents, skills) apart from those that reach your claude.ai account or devices, and Monitor and PowerShell; Codex gets web search and still asks before edits (`workspace-write`). See [the protocol](https://github.com/olofd/agneta/blob/v0.5.0/docs/APP_PROTOCOL.md#sandbox).

## 0.4.0 (2026-11-18)

A new look, a website, and a default model and effort for each provider.

**Updating from 0.3** keeps your providers, apps and history. As a new minor version, the update is shown with these notes rather than installed silently.

**For you**

- **A new icon:** Agneta's linked rings in white, on a Swedish summer evening going coral to rose to violet. Agneta's windows take the same colours, quietly: a deep rose for links, checkboxes and toggles, the rings in the evening's gradient, a faint glow along the top of the panel and dialogs, and the one main button in each window as a subtle coral-to-violet gradient.
- **A proper installer:** the DMG opens on a dusk background with an arrow from Agneta to Applications and what to do next, and the disk carries Agneta's icon.
- **Downloads show their progress:** signing in to a Claude plan shows how much of Claude Code's adapter has arrived, and so do the panel and Settings for every engine download. Before, they showed nothing until the download was done.
- **Nothing left of an unfinished sign-in:** one cancelled, failed or cut short by quitting no longer leaves its folder behind; Agneta removes any at launch.
- **Agneta and Agneta Dev side by side:** a development build keeps its own port, data, Keychain items and logs, and now shows a small hammer on its icon and menu bar mark, so the two tell apart.
- **[agneta.dahlbom.io](https://agneta.dahlbom.io):** Agneta's website, with the documentation, built from this repository's own documents.
- **Default model and effort, chosen from a list:** each provider's menu in Settings → Providers has **Model and Effort…**, with the models and effort levels its engine actually offers. With none seen yet, Agneta asks the engine once, without sending a prompt. New tasks start with them unless the app picks its own. They replace the old free-text default model, which only Goose and OpenCode on an API key ever used.
- **Smaller fixes:** a finished task's line in Activity wraps instead of being cut short.

**For apps**

- A new session arrives with the provider's default model and effort already set, where the user chose them; the app can still change both ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md)).
- **Project Chat**, the example app, picks the Agneta it uses (**Use**: Agneta or Agneta Dev), remembers the choice, and names it in what it shows ([examples/project-chat](https://github.com/olofd/agneta/tree/v0.4.0/examples/project-chat)).

## 0.3.1 (2026-11-18)

Fixes from an outside review of 0.3.0's access rules: what an app may do now follows your choices at every moment, and less is left behind on disk.

**Updating from 0.3.0** keeps your providers, apps and history. From 0.2.0, Agneta asks you to reset, as 0.3.0 does; from this version on, an update across a minor version is always shown with its notes, never installed silently, even when Agneta downloads updates automatically.

**For you**

- **Pairing again is stricter.** An app Agneta can't verify gets new access when it pairs again with Always Allow, with a new workspace and none of its earlier tasks: it's known only by its name, which another program could give. A verified app keeps its access, and its other open connections get what you just allowed at once.
- **Remove Access cuts the app off first.** If Agneta then can't delete the saved access, the app stays listed and Agneta says so.
- **Clear History deletes Claude Code's transcripts and Codex's session files** of the tasks it removes, which were kept in the provider's folder until sign-out ([PRIVACY.md](https://github.com/olofd/agneta/blob/v0.3.1/docs/PRIVACY.md)).
- **Stuck engines stop.** A limit's 10 s grace starts even when the engine isn't reading, and an engine that doesn't answer within 60 s of starting is stopped instead of keeping its task waiting.

**For apps** ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.3.1/docs/APP_PROTOCOL.md))

- A session that opens while the app's access changes is checked against the access as it is then; one that no longer fits is refused with `-32602` and `data.agneta.accessChanged`.
- On Claude Code and Codex, a permission request with no tool kind, or one ACP doesn't define, is refused. An app's "always" answer is declined where the engine offers no "once" option, instead of being kept.
- A policy field of the wrong type (`"tools": 5`) is refused instead of read as left out.
- Until a connection has a grant, it gets small limits: 16 such connections at once, messages up to 256 KB, and 10 minutes to pair.

## 0.3.0 (2026-11-18)

You choose which of your plans and API keys an app may use; the app picks the engine. A 19 MB download, downloads you can follow, and calmer windows.

**Updating from 0.2.0:** this version reads none of 0.2.0's data. After the update Agneta asks you to reset; then connect your plans and keys again, and apps ask for access again. Until 1.0, versions don't carry data or protocol details over.

**For you**

- **Apps choose the engine; you choose what they may use.** The approval window asks only which providers (your plans and API keys) an app may use. Every engine is allowed unless you narrow them under Advanced, and Settings → Apps changes both later. Settings → Engines sets each provider's default engine, used when an app doesn't pick, and shows each engine's source, version, install and download. Settings → Accounts is now Providers.
- **No provider yet?** An app that asks before any is connected gets a window to connect one there, and it's ticked. A provider whose engine isn't installed yet can still be allowed; its row says what it needs.
- **One grant per app.** Always Allow for an app that has access already renews it, keeping its workspace and tasks, instead of listing it twice; the window says so.
- **Downloads you can follow.** OpenCode, Claude Code's adapter and Codex's runtime show their progress in the panel and in Settings; a failed download says why, with Try Again, and can be put away. Downloads are checked against their pins at every launch, whole, off the main thread.
- **A 19 MB download** (59 MB in 0.2.0). Codex's runtime (Node and codex-acp) is a download of its own, fetched the first time a ChatGPT plan or an app needs Codex.
- **Steadier engines.** A default engine whose download failed no longer keeps tasks waiting while another engine can run.
- **ChatGPT sign-ins stay in the Keychain,** not in a file Codex's own tools could read during a task. Sign Out and Reset remove them.
- **Calmer windows.** Dialogs keep their close button and buttons clear of their rounded corners, and filled buttons are easier to read in dark mode; the menu bar panel no longer shows a square outline; Agneta says provider, not account, for what it connects.

**For apps** ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.3.0/docs/APP_PROTOCOL.md))

- `agneta/access` returns the providers and engines an app may use, each engine's state on this Mac (ready, downloading, downloadable, failed or unavailable, and why); `initialize` (`_meta.agneta.access`) and pairing return the same, and `agneta/accessChanged` says when it changes. `session/new` takes `_meta.agneta.engine`; a refusal carries the current access. An engine that isn't here starts downloading when asked for (`-32015`, with the progress).
- Pairing's result says whether access is `remembered`: keep that token and reconnect with it; `-32001` means the user removed access.
- Model and reasoning effort: each engine's own settings, found by their ACP categories (`model`, `thought_level`), set with `session/set_config_option`. Tried on Codex, Claude Code, Goose and OpenCode.
- When Agneta isn't running, ask the user and open `agneta://open` (`agneta-dev://open` for a development build).
- Breaking: extension names lose their `@1` (`agneta/policy`, `agneta/task`, `agneta/usage`, …); `_meta.agneta.accounts`, `scope` and `workspace` in `initialize` moved into `access`; `engineUnavailable` and `engineChanged` are gone (a saved task whose engine stores sessions differently reports `stateChanged`).
- The Project Chat example shows all of it: it keeps its access, offers to open Agneta, and has provider, engine, model and effort pickers.

## 0.2.0 (2026-11-18)

A smaller download, a choice of engine per app, an app icon, and fixes. Agneta is now about 60 MB to download instead of about 175.

**Updating from 0.1.0:** 0.1.0 can hang when it quits, and installing an update quits it. If the update seems stuck, quit Agneta from Activity Monitor (Force Quit): the update then installs, and 0.2.0 quits normally from then on.

- **Choose the engine per app.** When an app asks for access, each account you allow can run that app's tasks on another engine than the account's default, and Settings → Apps changes it later. Every account shows the engine it runs on, in the panel, the approval window and Settings. New accounts start on a sensible default (Codex for a ChatGPT plan, Claude Code for a Claude plan when it's installed, Goose for an API key), and adding one asks nothing about engines. Apps see the abilities of the engine they actually run on in `initialize`; if that engine can't run, `session/new` says so (`engineUnavailable`) ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.2.0/docs/APP_PROTOCOL.md)).
- **OpenCode downloads when you choose it** (pinned and checked), instead of being bundled. If an account used OpenCode in 0.1.0, it downloads in the background after the update, and Settings shows the progress.
- **An app icon:** the two linked rings in ice white on winter-sea blue, a Liquid Glass icon on macOS 26.
- **Quit Agneta quits.** In 0.1.0 it could hang and leave the app unresponsive until force-quit.
- **Check for Updates** is always in the panel's ⋯ menu; a build that doesn't update itself says why.
- The menu bar panel is frosted glass, so what's behind it no longer reads through its text; Settings and task details keep their title bar, so scrolled content no longer runs into the title.
- Run a Test Task's pairing code opens as a normal, centred dialog that closes itself once you answer in Agneta.
- **Security and robustness:**
  - A session's folders go into its sandbox exactly as they were checked, so a folder an app swaps for a symlink afterwards can't widen it.
  - Policy limits are hard limits: an engine that ignores the cancel has its session ended after 10 s ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.2.0/docs/APP_PROTOCOL.md)).
  - A limit outside the range of whole numbers is refused instead of crashing Agneta.
  - Agneta never signals a process group once its engine's process number could belong to another program.

## 0.1.0 (2026-11-18)

The first public release, for macOS 14 or later on Apple silicon and Intel (tested on macOS 15 and 26). Download the DMG for your Mac below, or `brew install olofd/tap/agneta`. It is signed with a Developer ID and notarized by Apple.

- **For people:** connect ChatGPT or Claude plans (through your own Codex and Claude Code) and OpenAI or Anthropic API keys; approve which apps may use them, with the tools and folders each asks for, once or always; see and stop every task; Pause an account; remove an app's access; Reset everything.
- **For apps:** the Agent Client Protocol over a loopback WebSocket, with pairing, per-session policies (tools, folders, network, approval, limits) enforced or refused, steering, forking, resuming, usage in every result, and the task's trace, live or later ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.1.0/docs/APP_PROTOCOL.md)).
- **Engines:** Goose and OpenCode bundled, Claude Code and Codex from your own installs, each confined by a macOS sandbox profile, under one contract for the built-in tools each policy permits.
- **Diagnostics:** a structured trace per task, `agneta-diag`, and an optional local MCP server for tools.
- **Updates:** once you allow it, Agneta checks GitHub for new releases about once a day and installs one only when no task is running. Settings → General turns checks or automatic installs off.
