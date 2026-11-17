# Changelog

Notable changes to Agneta, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, the app protocol may change between minor versions, and each change says how.

## Unreleased: 0.1.0

The first public release.

- **For people:** connect ChatGPT or Claude plans (through your own Codex and Claude Code) and OpenAI or Anthropic API keys; approve which apps may use them, with the tools and folders each asks for, once or always; see and stop every task; Pause an account; remove an app's access; Reset everything.
- **For apps:** the Agent Client Protocol over a loopback WebSocket, with pairing, per-session policies (tools, folders, network, approval, limits) enforced or refused, steering, forking, resuming, usage in every result, and the task's trace, live or later ([APP_PROTOCOL.md](docs/APP_PROTOCOL.md)).
- **Engines:** Goose and OpenCode bundled, Claude Code and Codex from your own installs, each confined by a macOS sandbox profile, under one contract for the built-in tools each policy permits.
- **Diagnostics:** a structured trace per task, `agneta-diag`, and an optional local MCP server for tools.
