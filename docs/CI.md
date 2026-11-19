# Continuous integration

`.github/workflows/ci.yml` builds and tests every push to `main` and every pull request, and runs the [static checks](#static-checks).

| Job | Runner | Why |
| --- | --- | --- |
| macOS 26, Apple silicon | `macos-26` | The newest macOS, where the app's glass look and most users are |
| macOS 15, Apple silicon | `macos-15` | The previous major version |
| macOS 15, Intel | `macos-15-intel` | Intel Macs: the engines and the sandbox differ by architecture |
| Static checks | `ubuntu-24.04` | Whitespace, shell scripts, Python (on 3.9, as Xcode's), JavaScript, workflows and data files: no Mac needed |
| Swift format | `macos-26` | swift-format comes with Xcode: the job selects the Xcode with the pinned version (`swift_format_version` in `scripts/check`) |

Each macOS job:

1. selects Xcode 26 (Swift 6.2, the macOS 26 SDK);
2. fetches the pinned engines with `scripts/fetch-engines --engine all`, checking their SHA-256;
3. builds everything, tests included, with warnings as errors (`-Xswiftc -warnings-as-errors`) and `--force-resolved-versions`, so `Package.resolved` must pin every package; then runs the whole test suite with `AGNETA_REQUIRE_ENGINES=1`. That makes the real-engine suites mandatory: Goose and OpenCode against the fake model and tool server (`RouterIntegrationTests`, `AppScenarioTests`, `GooseIntegrationTests`) and the sandbox acceptance test (`ContainmentTests`, [CONTAINMENT.md](CONTAINMENT.md)). Without the variable, those suites skip when an engine is missing, which suits a first local build but not CI. The fakes (`AgnetaFakes`) are served from the test process: Python servers on GitHub's runners often never accept a loopback connection (measured 2026-11-18);
4. if a test fails, uploads every test's folder (the fakes' request logs, engine logs and traces; `AGNETA_KEEP_TEST_FILES=1` keeps them) as the artifact `test-folders-<runner>`;
5. builds the app bundle with `scripts/dev/build-app`, which also fetches Codex's adapter and checks the bundle's signature;
6. builds the [TypeScript client](../clients/typescript/README.md) and runs its unit tests and its integration test against `agnetad`, Goose and the fake model (`agneta-fakes`);
7. uses the bundled Node to [test Project Chat](../examples/project-chat/README.md#check-it-without-an-account), which runs on the client, including a session against Goose and the fake model;
8. runs [Replica Bench](../examples/replica-bench/README.md)'s unit tests, which use macOS's sandbox.

`.github/workflows/client-typescript.yml` builds, type-checks and unit-tests the client on Linux with Node 22 and 24 for every change to `clients/typescript`, and `client-typescript-release.yml` publishes it to npm from a `client-typescript-v*` tag ([its README](../clients/typescript/README.md#releasing)).

The only actions used are GitHub's own (`actions/checkout`, `actions/setup-node`, `actions/upload-artifact`, and in the release workflows `actions/download-artifact` and `actions/attest-build-provenance`), each pinned to a commit. Nothing else is downloaded except the pinned engines, the npm lockfiles' packages and the static checks' three tools below, each pinned by version and SHA-256.

## Static checks

`scripts/check` runs them, here and on a contributor's Mac alike ([CONTRIBUTING.md](../CONTRIBUTING.md#static-checks)). In CI, `AGNETA_REQUIRE_TOOLS=1` turns a missing tool into a failure instead of a skip.

| Check | Tool | CI job |
| --- | --- | --- |
| `whitespace` | `scripts/dev/check-files`: no trailing whitespace, CRLF, conflict markers or blank lines at the end of a file (`Licenses/` is verbatim) | Static checks |
| `swift` | swift-format 6.3.0 from Xcode (`.swift-format`), on every line; the check's own tests | Swift format |
| `shell` | `bash -n` or `sh -n` on every script, then [ShellCheck](https://github.com/koalaman/shellcheck) 0.11.0 (`.shellcheckrc`) | Static checks |
| `python` | every Python file compiles with warnings as errors on Python 3.9, the file checks' tests pass, then [Ruff](https://github.com/astral-sh/ruff) 0.17.3 (`ruff.toml`) | Static checks |
| `js` | `node --check` on every JavaScript file | Static checks |
| `typescript` | the client's own type check (`npm run typecheck`); in CI, `client-typescript.yml` runs it | locally only |
| `actions` | [actionlint](https://github.com/rhysd/actionlint) 1.7.12 on the workflows, with ShellCheck on their `run` steps | Static checks |
| `data` | every JSON, lock, plist and TOML file parses (TOML from Python 3.11; on 3.9 the check names the files it left) | Static checks |

Every tool's findings fail the job, ShellCheck, actionlint and Ruff included. The job takes about a minute; the macOS test jobs gain only Replica Bench's tests, about ten seconds.

## Not covered yet

- **macOS 14.** The app is built for macOS 14 and later, but Xcode 26 doesn't run on macOS 14, so the suite can't be built there. Covering it needs the test products built on a newer Mac and run on a macOS 14 machine. Until then, the README lists macOS 14 as untested.
- **Claude Code and Codex.** Their engines need the user's own install and a signed-in account, so CI checks their adapters against the engine contract (`EngineContractTests`) but doesn't run them. The real probe (`AGNETA_REAL_PROBE=1`, [CONTRIBUTING.md](../CONTRIBUTING.md)) does, on a maintainer's Mac.
- **Signing and notarization**, which need a Developer ID ([RELEASING.md](RELEASING.md)).

## Running the same checks locally

```bash
scripts/check
scripts/fetch-engines --engine all
swift build --build-tests --force-resolved-versions -Xswiftc -warnings-as-errors
AGNETA_REQUIRE_ENGINES=1 swift test --skip-build
scripts/dev/build-app
cd clients/typescript
npm ci && npm run build && npm test && npm run test:integration
cd ../../examples/project-chat
npm ci --ignore-scripts
npm test
npm run test:integration
cd ../replica-bench
npm ci --ignore-scripts
npm test
```
