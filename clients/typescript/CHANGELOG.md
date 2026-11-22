# Changelog

Notable changes to `@agneta/client`, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, a minor version may change the API, and each change says how. Agneta's own changes are in [its changelog](https://github.com/olofd/agneta/blob/main/CHANGELOG.md).

## 0.1.0 (unreleased)

Hardening from the client review:

- Closing cancels connection and guided-connect work, including a socket upgrade still in flight. An already aborted open creates no socket.
- Both disk token stores write through unique, exclusively created, owner-only temporary files and atomically replace the destination. Concurrent saves cannot share a temporary file; destination symlinks are replaced.
- Malformed JSON-RPC replies fail their call with `ProtocolError`. Message observers receive detached, credential-redacted copies so they cannot change the reply delivered to the app.


The first version: Agneta's whole app protocol ([docs/APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md)), typed.

- **Connecting:** the release and Agneta Dev ports or any address; `ConnectionRefusedError` for a refused upgrade, `NetworkBlockedError` for an app that may not connect at all (a sandbox without `network.client`), `ConnectionClosedError` for a connection that went; quiet reconnecting with backoff.
- **Getting Agneta:** an environment (`nodeEnvironment()`, `electronEnvironment({ app, shell })`, or your own) to find Agneta through LaunchServices; `presence()` (running, installed and where, on its disk image, not installed); `connect({ guide, onProgress })`, which asks the user each question (get Agneta, open it, update it, connect a provider), opens the install page `https://agneta.dahlbom.io/get/` and Agneta itself only on a yes, waits while the user installs, and reports every step in words; `NotInstalledError`, `NotRunningError`, `OutdatedError` and `DeclinedError` without one; `minimumVersion`; and the parts (`openInstallPage`, `openAgneta`, `waitForAgneta`, `isAgnetaInstalled`).
- **Before pairing:** `catalog()`, `setup()`, `waitForProvider()`, and `connect({ setup })`.
- **Pairing:** the scope's `tools`, `folders`, `providers`, `engines` and `sandbox`, the pairing code, Allow Once and Always Allow, `unmet`; token stores in memory, in a file, and encrypted with Electron's `safeStorage`; a token Agneta no longer accepts is forgotten.
- **Access:** the access report kept current by `agneta/accessChanged`, with `chooseProvider` and `providerEngines`.
- **Sessions:** new, load (with the replayed history), fork and close, with the account, engine, every policy field, task, instructions, live trace and MCP servers; engine downloads waited out with progress. `appTools: 'always'` puts the app's MCP tools in the model's context from the first request (`agneta/appTools`), and `session.appTools` says what the session got. `policy.builtins` keeps only the named groups of the engine's own tools, and `session.builtins` says which the session has.
- **Turns:** a turn is a promise and an async iterable of its events (updates, queued, rate limited, stopped), with its text, thought, merged tool calls, usage and limit; cancel, steer, and a signal to cancel.
- **Settings:** model, effort and mode by ACP category; instructions between turns.
- **Permissions:** answered per session or per client, declined without a handler.
- **Traces:** live records, overflow, and reading page by page.
- **Errors:** a class and `kind` for every code and data Agneta sends, with `advice`; `AppLimitError` for `-32016`, a limit the user set for the app.
- **Limits the user sets:** `access.limits`, each provider's `uncounted`, `agneta/limit`'s `appSpend` and `setBy`, `agneta/usage`'s `app`, and the `queued` event's `waitingFor`.
- **The raw layer:** any request or notification, typed for Agneta's methods, and every frame both ways.
- **Structured results** (`agneta/result`): `results` on `newSession`, `loadSession` and `fork` (named schemas with `every`, or `{ schema }`), `session.results`, `prompt`'s `result`, the turn's `structured` report, and the result tool's calls kept apart (`resultCalls`, `resultCallOf`); `session.ask` (an `Ask`: the value, its `turn` and `details`) and the one-shot `client.ask`; schemas as plain JSON Schema typed by `FromSchema`, as a Standard Schema with Standard JSON Schema (checked again, typed as its output), or with the app's own type and `parse`; roots that aren't objects wrapped and unwrapped. New error kinds in `AnyAgnetaError`: `resultMissing`, `resultInvalid` (with `submitted`) and `unsupportedByAgneta`; every Agneta error's `structured`, and `accepted` when `ask`'s turn failed after a value was accepted. A handle opened without `results` reads the declared schemas from the reply (`session.results.schemas`). An open whose caller gave up (signal, timeout) closes the session when Agneta's answer comes. `initialize`'s `_meta.agneta.results` is typed (`ResultCapabilities`), and traces' `result` records and the `allowed-by-agneta` permission decision.
