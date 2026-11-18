# Third-party components

Agneta's own code is Apache License 2.0. These components keep their own licences. Bundled engines are pinned by version and SHA-256 in `Engines/*.lock`, and codex-acp's npm dependencies by `Engines/codex-acp.package-lock.json` (installed with `npm ci`). `scripts/fetch-engines` and `scripts/fetch-codex` verify every download, and use a cached copy only while its content still hashes to what was installed. Binaries are never committed.

The app bundle carries each component's licence text in `Contents/Resources/Licenses/` (from [Licenses/](Licenses/README.md); npm packages keep theirs inside `codex-acp/node_modules/`) and a CycloneDX bill of materials, `Contents/Resources/sbom.cdx.json`, written by `scripts/dev/sbom`.

| Component | Version | Licence | How Agneta uses it |
| --- | --- | --- | --- |
| [Goose](https://github.com/aaif-goose/goose) (`goose-acp`) | 1.59.2 | [Apache 2.0](https://github.com/aaif-goose/goose/blob/main/LICENSE) | Agent engine, bundled in the app |
| [OpenCode](https://github.com/anomalyco/opencode) | 2.3.0 | [MIT](https://github.com/anomalyco/opencode/blob/dev/LICENSE) | Agent engine. Not bundled: downloaded from its GitHub release the first time an account is set to it, and checked against `Engines/opencode.lock` |
| [codex-acp](https://github.com/agentclientprotocol/codex-acp) | 2.7.0 | Apache 2.0 | ACP adapter for the user's own Codex, bundled |
| codex-acp's npm dependencies | As locked | MIT (18), ISC (2), BSD-3-Clause (1), Apache 2.0 (1) | Bundled with codex-acp: `@agentclientprotocol/sdk`, `bundle-name`, `cross-spawn`, `default-browser`, `default-browser-id`, `define-lazy-prop`, `diff`, `is-docker`, `is-in-ssh`, `is-inside-container`, `is-wsl`, `isexe`, `open`, `path-key`, `powershell-utils`, `run-applescript`, `shebang-command`, `shebang-regex`, `vscode-jsonrpc`, `which`, `wsl-utils`, `zod` |
| [Node.js](https://nodejs.org) | 24.19.0 | [MIT, with bundled notices](https://github.com/nodejs/node/blob/main/LICENSE) | Runs codex-acp; the `node` binary is bundled |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.9.0 | [MIT](https://github.com/groue/GRDB.swift/blob/master/LICENSE) | SQLite store, linked into Agneta |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 | [MIT, with bundled BSD-2-Clause and zlib notices](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) | Updates, bundled as a framework in release builds' `Contents/Frameworks` |
| [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp) | 0.107.2 | [Apache 2.0](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/LICENSE) | ACP adapter for the user's own Claude Code. Downloaded from its GitHub release on first use and checked against `Engines/runtimes.lock`, not bundled: its binary embeds Anthropic's proprietary Agent SDK |
| Claude Code | The user's install | Proprietary (Anthropic) | Never bundled, downloaded or modified by Agneta |
| [Codex](https://github.com/openai/codex) | The user's install (0.166.0 or later) | Apache 2.0 | Never bundled by Agneta |

Source licences don't grant access to a provider's service, trademark rights, or the right to redistribute proprietary runtimes. See [docs/TERMS.md](docs/TERMS.md).
