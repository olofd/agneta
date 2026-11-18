# Contributing

Thanks for helping. Agneta is small and opinionated, so a short note first saves everyone time: for anything beyond a bug fix, open an issue describing the problem before writing the change.

## Building and testing

You need Xcode 26 or later (Swift 6.2, the macOS 26 SDK), and `python3` for Project Chat's smoke test and the scripts in `scripts/dev`.

```bash
scripts/dev/build-app        # the app bundle, with the pinned engines
scripts/fetch-engines --engine all   # once: the pinned engines the integration tests run
swift build && swift test    # everything, with fake models; no accounts needed
```

- `AGNETA_REQUIRE_ENGINES=1 swift test` fails, rather than skips, when an engine the integration suites need is missing. CI runs it this way ([docs/CI.md](docs/CI.md)).
- `swift test --filter <Suite>` runs one suite. `RouterContractTests` covers the router's decisions against a scripted fake engine, `AppScenarioTests` the whole app flow against the real Goose, and `ToolBrokerTests` the sandbox.
- `AGNETA_REAL_PROBE=1 AGNETA_REAL_PROBE_HOME=<folder> swift test --filter realProbe` runs a short real round on your own accounts. The folder holds the probe's sign-ins, laid out like Agneta's data: sign in once with `swift run agneta-signin claude --home <folder>/Accounts/claude` (and `codex --home <folder>/Accounts/chatgpt`). It never reads the app's own data. It's optional, and it uses your plan's limits or credit.
- Run test instances of the app with their own `AGNETA_HOME` and `AGNETA_PORT`, so nothing touches your own accounts.

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
