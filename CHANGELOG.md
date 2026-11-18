# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## Unreleased

- **Start fresh.** This version reads none of 0.2.0's data: after updating, Agneta asks you to reset, then to connect your providers and allow your apps again. Until 1.0, versions don't carry data or protocol details over.
- **Apps choose the engine; you choose what they may use.** The approval window asks only which providers (your plans and API keys) an app may use. Every engine is allowed unless you narrow them under Advanced, and Settings → Apps changes both later. The app picks a provider and an engine for each task among those; without one it gets the provider's default, set in Settings → Engines (renamed from Accounts' engine menu, with each engine's source, version, install and download). Settings → Accounts is now Providers.
- **App protocol** ([APP_PROTOCOL.md](docs/APP_PROTOCOL.md)): `agneta/access` returns the providers and engines an app may use (each engine's state on this Mac: ready, downloading, downloadable, failed or unavailable, and why), the same object `initialize` (`_meta.agneta.access`) and pairing return, and `agneta/accessChanged` says when it changes. `session/new` takes `_meta.agneta.engine`; a refusal carries the current access. Extension names lose their `@1` (`agneta/policy`, `agneta/task`, `agneta/usage`, …). `_meta.agneta.accounts`, `scope` and `workspace` in `initialize` moved into `access`; `engineUnavailable` and `engineChanged` are gone (a saved task whose engine stores sessions differently now reports `stateChanged`). A resumed task keeps the engine that saved it.

- **ChatGPT plans: sign in again once.** Codex now keeps each account's sign-in in the login Keychain instead of a file in the account's folder, which Codex's own file tools could read inside a task. After updating, the ChatGPT account asks you to sign in again; Sign Out and Reset also remove the Keychain entry.

- **Downloads you can follow.** OpenCode, Claude Code's adapter and Codex's runtime show their progress (bytes of total) in the panel and in Settings, whatever started them; a failed download says why, with Try Again, and can be put away. An app whose task needs an engine that isn't here starts its download and is told so (`-32015`, with the progress) until it's ready. A downloaded engine is checked against its pin at each launch, and Codex's runtime is named by its contents, so a release that changes it is downloaded again.
- **A 19 MB download** (59 MB in 0.2.0). Releases no longer bundle Codex's runtime (Node and codex-acp): it's a download of its own on each release, pinned and checked, fetched the first time a ChatGPT plan or an app set to Codex needs it. Settings shows the progress.

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
