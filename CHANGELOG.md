# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## Unreleased

A new look, and a website.

**For you**

- **A new icon:** Agneta's linked rings in white, on a Swedish summer evening going coral to rose to violet. Agneta's windows take the same colours, quietly: a deep rose for links, checkboxes and toggles, the rings in the evening's gradient, a faint glow along the top of the panel and dialogs, and the one main button in each window as a subtle coral-to-violet gradient.
- **Agneta and Agneta Dev side by side:** a development build keeps its own port, data, Keychain items and logs, and now shows a small hammer on its icon and menu bar mark, so the two tell apart.
- **[agneta.dahlbom.io](https://agneta.dahlbom.io):** Agneta's website, with the documentation, built from this repository's own documents.
- **Smaller fixes:** a finished task's line in Activity wraps instead of being cut short.

**For apps**

- **Project Chat**, the example app, picks the Agneta it uses (**Use**: Agneta or Agneta Dev), remembers the choice, and names it in what it shows ([examples/project-chat](https://github.com/olofd/agneta/tree/main/examples/project-chat)).

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
