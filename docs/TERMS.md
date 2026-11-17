# Accounts, provider terms and trademarks

Agneta is a tool that runs on your Mac with your own accounts. It doesn't provide AI service, resell access, or pool accounts between people. This page says plainly how each kind of account is reached, so you can judge it against your provider's terms. It isn't legal advice, and the terms are yours to follow.

## How each account is reached

| Account | How Agneta reaches it | Whose client the provider sees |
| --- | --- | --- |
| OpenAI or Anthropic API key | The key is kept in your Keychain and passed to the engine, which calls the provider's public API | The engine (Goose, OpenCode, Claude Code or Codex) |
| Claude plan, on Claude Code | Your own installed Claude Code, signed in with its own login (`claude auth login --claudeai`) in a folder of its own. Claude Code keeps and refreshes the credential; Agneta never handles it | Claude Code |
| Claude plan, on Goose | Goose's `claude-acp` provider runs `claude-agent-acp`, which runs your installed Claude Code (`CLAUDE_CODE_EXECUTABLE`), under the same sign-in | Claude Code |
| ChatGPT plan, on Codex | Your own installed Codex, signed in with `codex login` in a folder of its own. Codex keeps and refreshes the credential | Codex |
Agneta never signs in as another program, and never holds a plan's tokens: each plan is signed in by your own Codex or Claude Code, which keep and refresh their credentials themselves. ChatGPT plans therefore need Codex installed. OpenAI's Sign in with ChatGPT for open-source apps, which would let Agneta sign in under its own name, isn't supported yet.

**Consumer plans.** ChatGPT and Claude plans are meant for the person who pays for them. Agneta keeps it that way: every account is used only on the Mac it was signed in on, only by apps you allowed, and you see and can stop every task. Whether using your plan through an engine or an app is allowed is decided by your provider's terms, which can change. Anthropic's terms for its Agent SDK, for example, restrict third parties from offering claude.ai login in their products; Agneta runs your own Claude Code with its own login rather than offering one.

**API keys** are billed by the provider per call, under its API terms. The costs Agneta shows for them are estimates from the engine's own pricing, not the provider's bill.

## What Agneta ships and downloads

- Agneta's own code is Apache-2.0 ([../LICENSE](../LICENSE)).
- Goose, OpenCode, `codex-acp` and Node are open source and bundled, each under its own licence ([../THIRD_PARTY.md](../THIRD_PARTY.md)).
- `claude-agent-acp`'s released binary embeds Anthropic's proprietary Agent SDK, so Agneta doesn't redistribute it: it's downloaded from its own release on first use and checked against a pinned hash.
- Claude Code and Codex are never bundled or modified. Agneta uses the copies you installed.

## Trademarks

ChatGPT and OpenAI are trademarks of OpenAI. Claude and Anthropic are trademarks of Anthropic. Other names belong to their owners. Agneta isn't affiliated with or endorsed by any of them, or by the maintainers of the Agent Client Protocol or the engines it runs.

Agneta doesn't ship the providers' logos. Their use needs the provider's permission (Anthropic's [trademark guidelines](https://www.anthropic.com/legal/trademark-guidelines) allow it only as approved beforehand), so the app marks each account with a neutral glyph in the provider's colour, beside its name.
