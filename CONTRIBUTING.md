# Contributing

Thanks for helping. Agneta is small and opinionated, so a short note first saves everyone time: for anything beyond a bug fix, open an issue describing the problem before writing the change.

## Building and testing

You need Xcode 26 or later (Swift 6.2, the macOS 26 SDK). The round scripts in `scripts/dev` also use `python3`.

```bash
scripts/dev/build-app        # the app bundle, with the pinned engines
scripts/fetch-engines --engine all   # once: the pinned engines the integration tests run
swift build && swift test    # everything, with fake models; no accounts needed
```

- `AGNETA_REQUIRE_ENGINES=1 swift test` fails, rather than skips, when an engine the integration suites need is missing. CI runs it this way ([docs/CI.md](docs/CI.md)).
- `swift test --filter <Suite>` runs one suite. `RouterContractTests` covers the router's decisions against a scripted fake engine, `AppScenarioTests` the whole app flow against the real Goose, and `ToolBrokerTests` the sandbox.
- `AGNETA_REAL_PROBE=1 AGNETA_REAL_PROBE_HOME=<folder> swift test --filter realProbe` runs a short real round on your own accounts. The folder holds the probe's sign-ins, laid out like Agneta's data: sign in once with `swift run agneta-signin claude --home <folder>/Accounts/claude` (and `codex --home <folder>/Accounts/chatgpt`). It never reads the app's own data. It's optional, and it uses your plan's limits or credit.
- Run test instances of the app with their own `AGNETA_HOME` and `AGNETA_PORT`, so nothing touches your own accounts.
- `python3 site/build.py` builds the website from the docs and fails on a broken link between them ([site/README.md](site/README.md)). Run it when you change a document.
- `scripts/check` runs the static checks below in a few seconds. Run it before you push.

## Static checks

`scripts/check` runs the same static checks as CI ([docs/CI.md](docs/CI.md#static-checks)): whitespace, Swift formatting, the shell scripts, Python, JavaScript, the TypeScript client's types, the workflows and the data files. `scripts/check swift shell` runs just those; `scripts/check --fix` repairs what's mechanical (whitespace in tracked files, and Swift formatting around the lines you changed). It needs only Xcode and Node. ShellCheck, actionlint and Ruff are used when they're installed (`brew install shellcheck actionlint ruff`) and skipped with a note when they aren't; CI installs them pinned and requires them.

- **Warnings are errors in CI.** `swift build --build-tests -Xswiftc -warnings-as-errors` builds as CI does. A warning the code needs on purpose, such as a deprecated API used only for design review, is kept in one place (`Snapshots.swift` calls it through a protocol) rather than left warning.
- **Swift formatting.** swift-format, which comes with Xcode, with the repository's `.swift-format`: four-space indentation and 120 columns, the width the comments wrap at. CI formats with swift-format 6.3.0 (`swift_format_version` in `scripts/check`; the check points out a different one). Most of the code predates it, so for now only the lines a change touches must be formatted; `scripts/check swift --fix` formats the statements around them, and the check also reports the whole tree's findings without failing. Once the whole tree has been reformatted in a commit of its own, the check covers every line.
- **ShellCheck, actionlint and Ruff** report without failing until their first findings on `main` are fixed; then they fail like the rest (`AGNETA_CHECK_REPORT_ONLY` in `scripts/check`). A deliberate exception is a `# shellcheck disable=SCxxxx` (or `# noqa: Xnnn`) on its line, saying why.
- `.editorconfig` tells editors the whitespace each kind of file uses.

## Reporting a bug

Open an issue with the bug template, or the engine or provider template when a task fails on one of them: the Agneta version (Settings → About), your macOS and Mac, and for a task a redacted trace (`agneta-diag export <task> --out trace.jsonl --redact-content`). Security problems go privately, as [SECURITY.md](SECURITY.md) says, and conduct is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## What a change should come with

- **A test.** Security and correctness fixes get a regression test that fails without the fix.
- **Measurements, not guesses,** for anything about an engine's behaviour: what you ran, which version, what you saw. [docs/ENGINES.md](docs/ENGINES.md) records what has been measured so far.
- **Docs that match.** If the app protocol, the trace format or the security model changes, update [docs/APP_PROTOCOL.md](docs/APP_PROTOCOL.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) or [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) in the same change. Protocol changes are additive; versioned extensions (`@1`) never change meaning.

## Rules the code keeps

- **Refuse what can't be enforced.** A policy Agneta can't enforce is refused, never weakened silently.
- **Content stays out of Agneta's own log.** The operational log holds events, ids and timing. Content belongs in task traces only, where it can be redacted.
- **Processes are stopped by their recorded group and start time,** never by name.
- **Engines are pinned.** A new engine version means a new lock with its SHA-256, and a real round on it.
- **Swift style:** match the surrounding code. Comments explain why, names are short and plain, and there's no dead code.

## Licence

By contributing, you agree that your contribution is licensed under the Apache License 2.0, like the rest of Agneta.
