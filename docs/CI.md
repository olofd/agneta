# Continuous integration

`.github/workflows/ci.yml` builds and tests every push to `main` and every pull request, once the repository is on GitHub.

| Job | Runner | Why |
| --- | --- | --- |
| macOS 26, Apple silicon | `macos-26` | The newest macOS, where the app's glass look and most users are |
| macOS 15, Apple silicon | `macos-15` | The previous major version |
| macOS 15, Intel | `macos-15-intel` | Intel Macs: the engines and the sandbox differ by architecture |

Each job:

1. selects Xcode 26 (Swift 6.2, the macOS 26 SDK);
2. fetches the pinned engines with `scripts/fetch-engines --engine all`, checking their SHA-256;
3. builds, then runs the whole test suite with `AGNETA_REQUIRE_ENGINES=1`. That makes the real-engine suites mandatory: Goose and OpenCode against the fake model (`RouterIntegrationTests`, `AppScenarioTests`, `GooseIntegrationTests`) and the sandbox acceptance test (`ContainmentTests`, [CONTAINMENT.md](CONTAINMENT.md)). Without the variable, those suites skip when an engine is missing, which suits a first local build but not CI;
4. builds the app bundle with `scripts/dev/build-app`, which also fetches Codex's adapter and checks the bundle's signature;
5. uses the bundled Node to [test Project Chat](../examples/project-chat/README.md#check-it-without-an-account), including a session against Goose and a fake provider.

The only actions used are GitHub's own `actions/checkout`. Nothing else is downloaded except the pinned engines and the npm lockfile's packages.

## Not covered yet

- **macOS 14.** The app is built for macOS 14 and later, but Xcode 26 doesn't run on macOS 14, so the suite can't be built there. Covering it needs the test products built on a newer Mac and run on a macOS 14 machine. Until then, the README lists macOS 14 as untested.
- **Claude Code and Codex.** Their engines need the user's own install and a signed-in account, so CI checks their adapters against the engine contract (`EngineContractTests`) but doesn't run them. The real probe (`AGNETA_REAL_PROBE=1`, [CONTRIBUTING.md](../CONTRIBUTING.md)) does, on a maintainer's Mac.
- **Signing and notarization**, which need a Developer ID ([RELEASING.md](RELEASING.md)).

## Running the same checks locally

```bash
scripts/fetch-engines --engine all
swift build
AGNETA_REQUIRE_ENGINES=1 swift test
scripts/dev/build-app
cd examples/project-chat
npm test
npm run test:integration
```
