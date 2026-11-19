# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## Unreleased

**For you**

- **Set limits for each app,** in Settings → Apps: what it may spend on your API keys a day, a week or a month (at API prices), how many of its tasks run at once, and how many new tasks it starts an hour or a day. Its usage today is shown first, so you see what a limit would mean. At a limit its tasks stop and the app is told why; extra tasks at once wait their turn. Plans aren't charged per call, so their tasks aren't counted, and Codex, which reports no cost, doesn't run on an OpenAI key while spending is limited. The panel says when an app reaches its limit. Your limits stay with the app when it pairs again.
- **OpenCode's usage is complete.** A turn with several steps recorded only its last, so cost on OpenCode, and a `maxCostUSD` limit, counted too little. Each step's usage is now read once OpenCode has finished writing it.

- **Clearing history removes a Codex task completely:** Codex deletes its own session, including its copies in Codex's databases, not only its session file.
- **Deleting a task deletes all of its conversation:** a task that ran on an API key without built-in tools shares its account's Goose, which kept the conversation until you signed out. Now Agneta asks Goose to delete it, then rewrites Goose's database so no file still holds the words.
- **Model and Effort… names the engine's own choice:** "Codex's default (its model)" rather than just "Codex's default", so leaving it to the engine says what that means.
- **Choose how far each app reaches:** **Developer access** (as in a terminal: the internet, your home folder and your toolchains, with credentials and Agneta's data kept out) or **Contained** (the task's folders, no internet for commands), when you allow an app and later in Settings → Apps. Apps you allowed before stay contained.
- **Reset tells you when a sign-in may remain.** A plan's sign-in is in the login Keychain, and only Claude Code's or Codex's own logout removes it. When one isn't installed or its logout fails, Reset (and Sign Out) now says which sign-ins may still be there and how to delete them in Keychain Access, instead of reporting a full reset. A reset interrupted and finished at the next launch now finds your Claude Code and Codex first.
- **Reset stops downloads.** An engine download under way when you reset could finish afterwards and put its files back; it's now stopped before anything is deleted.
- **Clearing history keeps trying.** A conversation in an account's shared Goose that couldn't be deleted at once (Goose not there, failing, or Agneta quitting) was lost track of. Agneta now keeps a list of them until Goose deletes each, asks again at launch and after each clear, and says when it couldn't, with **Try Again**.
- **A changed model takes effect on the next task.** An account's shared Goose kept the model it started with, so clearing a custom model (or changing the model, key or defaults) didn't apply until Agneta restarted. Now its shared engines restart for the next task; one busy with a task finishes it first.
- **A tidier approval window:** one Access card with the app's tools, folders and mode, **Engines…** in its header, and an unverified app's code on one row. It shows only what the app asked for, with a **Connect** row for a provider you haven't connected yet.

**Security**

- **An app that passes its connection on can't borrow another app's identity.** Agneta verifies a connecting app by its code signature; a connection held by more than one process (passed to a signed app the program launched) now counts as unverified, with a code to compare.
- **Claude Code asked about nothing.** The adapter starts every session in `auto`, where Claude Code decides its own permissions: measured, Bash and Monitor ran without a single permission request, so Agneta couldn't refuse commands while a task had no network. Every Claude Code session is now set to the mode that asks, on new and on resume.
- **Resumed Claude Code tasks lost their settings.** A resumed or forked task was opened without Agneta's options, so the adapter fell back to its defaults and loaded the workspace's own `.claude/settings.json`, which the agent can write (hooks, environment, permissions). Measured: a planted hook ran and its environment reached commands. Resume and fork now send the same options as a new session, and Claude Code reads no MCP configuration of its own.
- **Claude Code offers only the tools a policy names.** Agneta passes the exact built-in set, so a tool a new Claude Code adds (Monitor, which runs commands, was one) stays off until Agneta allows it. Read-only commands, which Claude Code ran without asking inside the engine's own sandbox, now go through Agneta's broker like every other.
- **Permission requests are judged by tool name, not only kind.** A request of kind `other` passes only for a tool known to run nothing.
- **Contained commands can't look names up.** A lookup of a made-up host name could carry data out; a contained command now reaches no resolver, only its loopback ports.
- **No command outlives Agneta.** Commands still running, background jobs included, end when their engine ends, when Agneta quits, and when Agneta itself dies. One that starts a session or process group of its own can still outlive them (see the protocol's known limits).
- **Folders swapped for links grant nothing.** A session can replace a folder it may write (its engine's home, its scratch folder, its app's workspace or caches) with a link elsewhere. Agneta now puts its own folders back before each start, never follows such a link, and checks granted folders without following their last link.
- **Writable folders are pinned:** a session can work inside them, but can't rename, remove or replace them.
- **Profiles pass inline** (`sandbox-exec -p`), never as a file an engine could rewrite.
- **Sign-in and sign-out act only on Agneta's own folders.** Before Claude Code or Codex runs on an account folder outside the sandbox, Agneta makes it a real folder again and clears anything an engine planted there.
- **Codex's trusted files** (`.env`, `AGENTS.md`, hooks, skills, rules, prompts) are cleared before each start and read-only to its engines, and so are **Claude Code's account settings files** (`settings.json`, hooks, skills, agents, commands, `CLAUDE.md`).
- **Broker tokens aren't in environments.** Any process of yours can read another's environment, so each engine reads its token from a file of its own. An API-key account's key is still in its engine's environment (a known limit).

**For apps**

- **Limits the user sets** ([the protocol](docs/APP_PROTOCOL.md#limits-the-user-sets)), additive: the extension `agneta/appLimits`; `limits` in the access report and each provider's `uncounted` engines; the error `-32016` when a limit is reached, with `data.agneta.appLimit`; `agneta/limit`'s `"limit": "appSpend"` and `setBy` (`app` for the policy's limits, `user` for the user's); `agneta/queued`'s `waitingFor`; `agneta/usage`'s `app`. `@agneta/client` types them all (`AppLimitError`).

- **`@agneta/client`, the official TypeScript client** ([clients/typescript](clients/typescript/README.md)): the whole app protocol, typed, in Node 22+ and Electron's main process, with no dependencies. It connects and offers to open Agneta, pairs and keeps the token, follows access changes, opens, loads and forks sessions, streams turns, answers permission requests, reads traces, and maps every error code to a typed error; a raw layer sends anything else. Project Chat and Replica Bench now run on it. Published to npm separately, from `client-typescript-v*` tags.
- **A task stopped mid-turn answers its prompt as cancelled,** as the protocol says, even when the engine never answers it (Stop, a removed provider, narrowed access). Before, the prompt could wait on a shared engine indefinitely, or fail as "The engine stopped".
- **`maxCostUSD` is checked before a prompt is sent:** a task already over its limit spends nothing more.
- **Fewer false rate limits:** an error that merely says "429" or "limit reached" (a token count, a context window, a tool's output) is no longer reported as `agneta/rateLimited`.
- **`agneta/trace/read` no longer reports `complete` before a task's last records are written.**
- **A new pairing with `workspace` tools now defaults to developer access.** A session that doesn't send `"sandbox"` runs with the grant's mode, and under developer access `network: "none"` doesn't apply: commands reach the internet and read the home folder. Send `"sandbox": "contained"` to keep the old behaviour. Grants made before this stay contained.
- **Codex reserves the tool server name `agneta`** (its shell): a server of yours with that name is refused on Codex.
- **New fields:** the pairing reply's `unmet`, each provider's `sandboxLevels` and `scope.sandbox` in the access report, and `_meta.agneta.sandbox` in each session's reply.
- **Ask for exactly what you need.** A pairing scope can name the `providers` (kinds, or `"all"`), the `engines` and the `sandbox` (`contained`, `developer` or `any`), and the approval window is narrowed to them. The reply's `unmet` says what wasn't given, and why.
- **Before pairing:** `agneta/catalog` says what Agneta offers (each provider kind, whether one is connected, its engines and their modes), and `agneta/setup` asks Agneta to help the user connect a provider. With nothing connected, the approval window lets the user connect one in place.
- **Claude Code and Codex run commands on the contained path.** Claude Code's Bash goes through Agneta's broker, as Goose's does, and so do Codex's commands, through Agneta's own `shell` tool in place of Codex's: under the session's command sandbox, with no network, every command in the trace. Monitor stays off.
- **Background jobs live on, as in a terminal.** A command's background job keeps running after the command returns, and ends with its engine.
- **`toolEnvironment`** sets variables for commands: your toolchain's `PATH` (inside the session's folders, ahead of everything else), `CARGO_HOME`, `PYTHONPATH`, winning over developer access's own. Empty `PATH` entries are refused. Commands also find the selected Xcode's own `cc`, `git` and `python3`, wherever Xcode is installed.
- **Sandbox per app.** Each app's grant has a mode the user picks at pairing and in Settings → Apps: **Developer access** (the default: full power, as in a terminal, with known credential stores, sandboxed apps' data and Agneta's own kept out) or **Contained** (the session's folders, no internet for commands). A session may ask for less (`"sandbox": "contained"`), never more. Each engine says what it can provide (`sandboxLevels` in the access report): Goose on a Claude plan provides developer access only, and is refused, with why, for a contained task. The reply says what each task got (`_meta.agneta.sandbox`). Apps paired before this, and apps granted fewer than workspace tools (which the approval window offers no choice), stay contained. Under developer access each app builds with caches of its own, never yours; Claude Code keeps its own tools (web fetch and search, subagents, skills) apart from those that reach your claude.ai account or devices, and Monitor and PowerShell; Codex gets web search and still asks before edits (`workspace-write`). See [the protocol](docs/APP_PROTOCOL.md#sandbox).

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
