# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## Unreleased

- The menu bar panel is frosted glass: what's behind it no longer reads through its text.
- Settings and task details keep their title bar, so scrolled content no longer runs into the title.
- Run a Test Task's pairing code opens as a normal, centred dialog that closes itself once you answer in Agneta.
- Check for Updates is always in the panel's ⋯ menu; a build that doesn't update itself says why.
- Every account shows the engine it runs on, in the panel, the approval window and Settings. New accounts start on a sensible default engine, and adding one asks nothing about engines.
- Choose the engine per app: when an app asks for access, each account you allow can run that app's tasks on another engine than its default, changeable later in Settings → Apps. Apps see that engine's abilities in `initialize`.
- An app icon: the two linked rings in ice white on winter-sea blue, a Liquid Glass icon on macOS 26.
- OpenCode is no longer bundled: it downloads (pinned and checked) the first time an account is set to it. The download of Agneta itself falls from about 175 MB to about 60 MB.
- Quit Agneta from the panel's menu quits: in 0.1.0 it hung and left the app unresponsive until force-quit.

## 0.1.0 (2026-11-18)

The first public release, for macOS 14 or later on Apple silicon and Intel (tested on macOS 15 and 26). Download the DMG for your Mac below, or `brew install olofd/tap/agneta`. It is signed with a Developer ID and notarized by Apple.

- **For people:** connect ChatGPT or Claude plans (through your own Codex and Claude Code) and OpenAI or Anthropic API keys; approve which apps may use them, with the tools and folders each asks for, once or always; see and stop every task; Pause an account; remove an app's access; Reset everything.
- **For apps:** the Agent Client Protocol over a loopback WebSocket, with pairing, per-session policies (tools, folders, network, approval, limits) enforced or refused, steering, forking, resuming, usage in every result, and the task's trace, live or later ([APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/v0.1.0/docs/APP_PROTOCOL.md)).
- **Engines:** Goose and OpenCode bundled, Claude Code and Codex from your own installs, each confined by a macOS sandbox profile, under one contract for the built-in tools each policy permits.
- **Diagnostics:** a structured trace per task, `agneta-diag`, and an optional local MCP server for tools.
- **Updates:** once you allow it, Agneta checks GitHub for new releases about once a day and installs one only when no task is running. Settings → General turns checks or automatic installs off.
