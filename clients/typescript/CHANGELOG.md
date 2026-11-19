# Changelog

Notable changes to `@agneta/client`, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, a minor version may change the API, and each change says how. Agneta's own changes are in [its changelog](https://github.com/olofd/agneta/blob/main/CHANGELOG.md).

## 0.1.0 (unreleased)

The first version: Agneta's whole app protocol ([docs/APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md)), typed.

- **Connecting:** the release and Agneta Dev ports or any address; `ConnectionRefusedError` for a refused upgrade, `NetworkBlockedError` for an app that may not connect at all (a sandbox without `network.client`), `ConnectionClosedError` for a connection that went; quiet reconnecting with backoff.
- **Getting Agneta:** an environment (`nodeEnvironment()`, `electronEnvironment({ app, shell })`, or your own) to find Agneta through LaunchServices; `presence()` (running, installed and where, on its disk image, not installed); `connect({ guide, onProgress })`, which asks the user each question (get Agneta, open it, update it, connect a provider), opens the install page `https://agneta.dahlbom.io/get/` and Agneta itself only on a yes, waits while the user installs, and reports every step in words; `NotInstalledError`, `NotRunningError`, `OutdatedError` and `DeclinedError` without one; `minimumVersion`; and the parts (`openInstallPage`, `openAgneta`, `waitForAgneta`, `isAgnetaInstalled`).
- **Before pairing:** `catalog()`, `setup()`, `waitForProvider()`, and `connect({ setup })`.
- **Pairing:** the scope's `tools`, `folders`, `providers`, `engines` and `sandbox`, the pairing code, Allow Once and Always Allow, `unmet`; token stores in memory, in a file, and encrypted with Electron's `safeStorage`; a token Agneta no longer accepts is forgotten.
- **Access:** the access report kept current by `agneta/accessChanged`, with `chooseProvider` and `providerEngines`.
- **Sessions:** new, load (with the replayed history), fork and close, with the account, engine, every policy field, task, instructions, live trace and MCP servers; engine downloads waited out with progress.
- **Turns:** a turn is a promise and an async iterable of its events (updates, queued, rate limited, stopped), with its text, thought, merged tool calls, usage and limit; cancel, steer, and a signal to cancel.
- **Settings:** model, effort and mode by ACP category; instructions between turns.
- **Permissions:** answered per session or per client, declined without a handler.
- **Traces:** live records, overflow, and reading page by page.
- **Errors:** a class and `kind` for every code and data Agneta sends, with `advice`; `AppLimitError` for `-32016`, a limit the user set for the app.
- **Limits the user sets:** `access.limits`, each provider's `uncounted`, `agneta/limit`'s `appSpend` and `setBy`, `agneta/usage`'s `app`, and the `queued` event's `waitingFor`.
- **The raw layer:** any request or notification, typed for Agneta's methods, and every frame both ways.
