# Security

Agneta keeps AI credentials, runs agent engines on people's Macs, and decides what those engines and their commands may reach. A security fault here can expose accounts or files, so please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this repository, then **Report a vulnerability**. Don't open a public issue for it.

If that form isn't available, open an issue titled "Security contact" with no details. A maintainer will reply with a private way to send the report.

Fixes go into the latest release, which installed copies update to; older versions aren't patched.

Please include what you did, what you expected, what happened, and the Agneta version or commit. A trace exported with `agneta-diag export <task> --out <file> --redact-content` often helps. That export removes content, names and paths and keeps structure and timing ([docs/PRIVACY.md](docs/PRIVACY.md#sharing-a-trace)); look it over before you send it.

You'll get an acknowledgement within a week. Fixes are released as soon as they're ready, and you're credited unless you'd rather not be.

## In scope

What Agneta defends, and against whom, is in the threat model in [docs/PRIVACY.md](docs/PRIVACY.md#threat-model). A fault is in scope when it breaks a defence listed there as defended, for example:

- Escaping the engine or tool sandbox: reading or writing outside what a session's policy allows, or reaching the network when the policy says none
- A program the user didn't allow (another app, a sandboxed app, a web page) using Agneta, or an allowed app going beyond its grant: accounts it wasn't given, tools or folders beyond its scope, another app's tasks or traces
- Credentials (API keys, sign-in tokens, tool-server bearers) leaking into traces, logs, exports or other processes
- Crashing or hanging Agneta from a local connection before it's authenticated
- The diagnostics MCP server answering without its token

## Out of scope

- Faults in the engines themselves (Goose, OpenCode, Claude Code, Codex) that Agneta's sandbox contains. Please report those upstream as well.
- Unsandboxed code already running as the same macOS user. It can read the user's files and drive their apps, so Agneta's approval window slows it down but can't stop it. A sandboxed app, or a program running as another user, is in scope
- A provider's own terms or account decisions
