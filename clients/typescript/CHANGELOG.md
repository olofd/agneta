# Changelog

Notable changes to `@agneta/client`, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0, a minor version may change the API, and each change says how. Agneta's own changes are in [its changelog](https://github.com/olofd/agneta/blob/main/CHANGELOG.md).

## 0.1.0 (unreleased)

The first version: Agneta's whole app protocol ([docs/APP_PROTOCOL.md](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md)), typed.

- **Connecting:** the release and Agneta Dev ports or any address; `NotRunningError` with the URL that opens Agneta, `launch` to ask the user and open it, `ConnectionRefusedError` for a refused upgrade, `ConnectionClosedError` for a connection that went; quiet reconnecting with backoff.
- **Before pairing:** `catalog()`, `setup()`, `waitForProvider()`, and `connect({ setup })`.
- **Pairing:** the scope's `tools`, `folders`, `providers`, `engines` and `sandbox`, the pairing code, Allow Once and Always Allow, `unmet`; token stores in memory, in a file, and encrypted with Electron's `safeStorage`; a token Agneta no longer accepts is forgotten.
- **Access:** the access report kept current by `agneta/accessChanged`, with `chooseProvider` and `providerEngines`.
- **Sessions:** new, load (with the replayed history), fork and close, with the account, engine, every policy field, task, instructions, live trace and MCP servers; engine downloads waited out with progress.
- **Turns:** a turn is a promise and an async iterable of its events (updates, queued, rate limited, stopped), with its text, thought, merged tool calls, usage and limit; cancel, steer, and a signal to cancel.
- **Settings:** model, effort and mode by ACP category; instructions between turns.
- **Permissions:** answered per session or per client, declined without a handler.
- **Traces:** live records, overflow, and reading page by page.
- **Errors:** a class and `kind` for every code and data Agneta sends, with `advice`.
- **The raw layer:** any request or notification, typed for Agneta's methods, and every frame both ways.
