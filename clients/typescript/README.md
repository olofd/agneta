# @agneta/client

The official TypeScript client for [Agneta](https://github.com/olofd/agneta), the Mac menu bar app that lets other apps run AI work on the user's own plans and API keys (a ChatGPT or Claude plan, an OpenAI or Anthropic key) through Claude Code, Codex, Goose and OpenCode.

It speaks [Agneta's app protocol](https://github.com/olofd/agneta/blob/main/docs/APP_PROTOCOL.md) (the Agent Client Protocol over a local WebSocket, with Agneta's extensions) so your app doesn't have to: connecting, offering to open Agneta, pairing, keeping the token, reconnecting, access changes, sessions, streaming, permissions, traces and every error, typed. Nothing of the protocol is hidden: a raw layer sends any request and shows every message.

- **No dependencies.** ESM, with type declarations.
- **Node 22 or later, and Electron's main process.** Agneta refuses connections from web pages and Electron renderers (anything that sends an `Origin` header), so the client says so rather than failing as "not running".
- **Before 1.0**, like Agneta's protocol: minor versions may change the API, and the [changelog](CHANGELOG.md) says how.

The package isn't on npm yet. Until its first release, build it from this repository:

```sh
cd clients/typescript && npm install && npm run build
```

and depend on it by path (`"@agneta/client": "file:../agneta/clients/typescript"`).

## Quick start

```js
import { AgnetaClient } from '@agneta/client';
import { fileTokenStore } from '@agneta/client/node';

const client = new AgnetaClient({
  name: 'Example App',                            // shown in Agneta's approval window
  tokens: fileTokenStore('/path/to/agneta-token') // keeps Always Allow's token (use the Keychain in a real app)
});
client.on('pairingCode', (code) => console.log(`Check that Agneta shows ${code}`));

await client.connect();                           // pairs the first time, then reuses the token

const session = await client.newSession({ policy: { tools: 'app-only', approval: 'never-ask' } });
const turn = session.prompt('Sort these notes by topic.');
for await (const text of turn.textStream()) process.stdout.write(text);
const { stopReason, usage } = await turn;
await session.close();
client.close();
```

That's all of it: `connect()` opens `ws://127.0.0.1:47321/acp`, pairs (Agneta's approval window), keeps the token if the user chose **Always Allow**, and initializes; `newSession()` opens a task in your app's own workspace; `prompt()` returns a turn you can both stream and await. [`examples/quickstart.mjs`](examples/quickstart.mjs) is the same as a script.

## Contents

- [Connecting](#connecting)
- [Before pairing](#before-pairing)
- [Pairing and tokens](#pairing-and-tokens)
- [Access](#access)
- [Sessions](#sessions)
- [Turns](#turns)
- [Model, effort, mode and instructions](#model-effort-mode-and-instructions)
- [Permissions](#permissions)
- [Traces](#traces)
- [Errors](#errors)
- [Events](#events)
- [The raw layer](#the-raw-layer)
- [Electron](#electron)
- [Reference](#reference)
- [Releasing](#releasing)

## Connecting

```js
const client = new AgnetaClient({
  name: 'Example App',
  build: 'release',        // or 'dev' for Agneta Dev (port 47331); or port: 47341, or url: 'ws://…'
  tokens,                  // a TokenStore (below); memory only by default
  scope: { tools: 'workspace', folders: ['/Users/me/Documents/Example Project'] },
  launch: async ({ name, openURL }) => askUser(`Open ${name}?`) && openAgneta('release'),
  permissions: (request) => 'allow',
  reconnect: true
});
```

`client.connect(options)` resolves with the [access report](#access). Its options:

| Option | Meaning |
| --- | --- |
| `pair` | `'if-needed'` (the default) pairs when there's no usable token. `'never'` stops with `NeedsPairingError` instead: a quiet connect at launch, which never opens the approval window. `'always'` pairs even with a usable token, to change the scope |
| `setup` | `true` or a provider kind: before pairing, when no provider (of that kind) is connected in Agneta, show Agneta's window for connecting one (`agneta/setup`) and wait until one is (event `setup`). Off by default: the approval window lets the user connect one in place too |
| `scope` | A scope for this pairing instead of the client's |
| `signal` | An `AbortSignal` |

**When Agneta isn't running**, the connection is refused and `connect()` rejects with `NotRunningError` (`kind: 'notRunning'`, with `openURL`: `agneta://open` or `agneta-dev://open`). Never open Agneta without asking: quitting it is how the user stops all of it. Pass `launch` to ask and open it; when it resolves `true`, the client waits for Agneta (up to `launchTimeout`, 20 s) and connects. `openAgneta(build)` from `@agneta/client/node` opens it with macOS's `open`; in Electron use `shell.openExternal(openURL)`.

A connection that something answered but refused is `ConnectionRefusedError` (`kind: 'refused'`): a web page, an Electron renderer, or a program other than Agneta on the port. One that was open and closed is `ConnectionClosedError` (`kind: 'connectionClosed'`).

`client.state` is `disconnected`, `connecting`, `pairing`, `connected` or `reconnecting` (event `state`). `client.close()` disconnects; open sessions end.

**Reconnecting.** With `reconnect: true` (or `{ delay, maxDelay }`), a dropped connection whose token was remembered reconnects by itself, quietly (it never pairs or calls `launch`), with backoff from 1 s to 30 s: events `reconnecting`, `reconnected`, or `accessRemoved` when Agneta no longer accepts the token. Agneta closes a connection's sessions with it, so sessions don't come back by themselves: load them again with `client.loadSession(id)`.

`@agneta/client/node` also has `isListening(port)`, `waitForPort(port)` and `runningBuilds()` (which of the release and Agneta Dev are running), for choosing which Agneta to use.

## Before pairing

Two calls work on a connection that hasn't paired, so your app can tell whether there's anything to ask for:

```js
const catalog = await client.catalog();          // agneta/catalog
if (!catalog.providers.find((p) => p.kind === 'claude')?.connected) {
  await client.setup({ kind: 'claude' });        // agneta/setup: Agneta's add-provider window, naming your app
  await client.waitForProvider('claude');        // until agneta/catalogChanged says one is connected
}
await client.connect();
```

The catalog lists each provider kind (`claude`, `chatgpt`, `anthropic-key`, `openai-key`) with its name, whether one is `connected`, and its engines with the modes each can provide (`sandboxLevels`, `uncontained`); the engines on this Mac with their `state`; and `connected`. It never names the user's accounts. Event `catalogChanged` follows changes. `connect({ setup: 'claude' })` does the same in one call. Ask for setup only when the user asked to connect.

## Pairing and tokens

The scope says what your app will need; Agneta's approval window shows it to the user, who can give less:

```js
const result = await client.pair({
  tools: 'workspace',                 // app-only | read | workspace: the most built-in tools its sessions will use
  folders: ['/Users/me/Documents/Example Project'],
  providers: ['claude'],              // or 'all'; left out, the user picks
  engines: ['claude-code'],           // or 'all'; left out, every engine
  sandbox: 'contained'                // contained | developer | any
});
result.remembered;   // Always Allow (true) or Allow Once (false)
result.unmet;        // what wasn't given: [{ provider: 'chatgpt', reason: 'not connected in Agneta' }, …]
```

`connect()` calls `pair()` for you when it needs to (with the client's `scope`); `pair()` also initializes. While the window waits, an app Agneta can't verify (ad hoc or unsigned builds) gets a six-digit code: show it (`client.on('pairingCode', …)`, or `client.pairingCode`). The user allows your app only if it matches Agneta's. A scope Agneta can't accept is refused before the user is asked (`UnenforceableError`); **Don't Allow**, closing the window or leaving it for 5 minutes is `NotAllowedError`. Pairing waits up to 310 s.

**Tokens.** A remembered token goes into the client's `TokenStore`, and `connect()` uses it next time. A token Agneta no longer accepts (the user removed your app, or it's another program) is cleared, and `accessRemoved` is emitted. An Allow Once token lives only as long as the connection.

| Store | Where |
| --- | --- |
| `memoryTokenStore()` | Memory only (the default) |
| `fileTokenStore(path)` | A file only the user can read (`@agneta/client/node`) |
| `safeStorageTokenStore(safeStorage, path)` | A file encrypted with Electron's `safeStorage`, whose key is in the login Keychain (`@agneta/client/node`) |
| Your own | Any `{ load, save, clear }`, sync or async: the Keychain through a native module, say |

Keep one store per Agneta build (release, Dev, an isolated instance): each has its own grants. `client.forgetToken()` clears it.

## Access

What the user allows your app: providers (accounts) and engines. Each task runs on one provider and one of its engines, which your app picks.

```js
const access = client.access;        // the same object initialize, pairing and agneta/access return
access.providers;                    // [{ id, label, kind, paused, needsSignIn, engines, defaultEngine, uncontained, sandboxLevels }]
access.engines;                      // [{ id, name, state: 'ready' | 'downloading' | 'downloadable' | 'failed' | 'unavailable', … }]
access.allowedEngines;               // 'all' or engine ids
access.scope;                        // { tools, folders, sandbox }: the grant's mode is the ceiling
access.workspace;                    // your app's own folder

client.on('accessChanged', (access) => updatePickers(access));
await client.refreshAccess();        // agneta/access

import { chooseProvider, providerEngines } from '@agneta/client';
const choice = chooseProvider(access, { kind: 'claude', sandbox: 'contained' });  // { account, provider, engine } | null
const engines = providerEngines(access, access.providers[0]);  // each with name, state, sandboxLevels, uncontained, isDefault
```

An engine listed in a provider's `uncontained` provides developer access only: Agneta's policy can't confine its own tools there. Offer it as a choice, and say so where your users pick an engine.

## Sessions

```js
const session = await client.newSession({
  account: choice.account,           // default: the first provider
  engine: 'claude-code',             // default: the provider's default (one that can provide the sandbox asked for)
  cwd: client.workspace,             // the default
  mcpServers: [httpMcpServer({ name: 'app', url: `http://127.0.0.1:${port}/mcp`, token })],
  policy: {
    tools: 'workspace', sandbox: 'contained', network: 'none', approval: 'ask-app',
    readable: [], writable: [], readOnly: [], denied: [],
    toolEnvironment: { CARGO_HOME: '/…' }, toolPorts: [port], toolSockets: [],
    limits: { maxTurns: 100, maxSeconds: 900, maxCostUSD: 2 }
  },
  task: { title: 'Tidying the project notes', stopWarning: 'Example App keeps the work so far' },
  instructions: 'You are Example App\'s assistant.',
  trace: true,                       // live trace records; or { live: true, include: ['acp'] }
  permissions: (request) => 'allow'  // this session's permission requests
});
session.id;              // Agneta's id
session.engine;          // 'claude-code'
session.sandbox;         // what the task really got
session.capabilities;    // { engine, steer, fork, instructionsBetweenTurns, reportsCost }: check before offering them
session.configOptions;   // the engine's own settings
```

- **Every option is optional.** With none, the session runs in your app's workspace with `workspace` tools (no more than granted), the grant's sandbox and `ask-app` approval. Anything Agneta can't enforce is refused with `UnenforceableError`, naming the `fields` and the `reason`.
- **Your tools** are MCP servers your app runs on loopback (Streamable HTTP), each with a fresh bearer per session. `httpMcpServer({ name, url, token })` builds the registration.
- **An engine still downloading** (`-32015`) is waited out: the client tries again every 2 s for up to 10 minutes, calling `onDownloadProgress({ engine, received, total })` and emitting `engineDownloading`. `waitForDownload: false` fails at once with `EngineDownloadingError`; a number sets the wait in ms.
- **More `_meta` or params:** `meta` merges keys into `_meta`, and `params` adds top-level params, for anything this API doesn't name.
- Opening a session times out after 180 s per attempt (`timeouts.session`).

**Resuming and forking.**

```js
const again = await client.loadSession(id, { mcpServers: [server] });   // session/load: pass the servers again
again.history;      // the conversation, replayed as session/update before the result
again.resumed;      // true

const review = await session.fork({ mcpServers: [] });   // agneta/fork: a copy, read-only unless a policy says otherwise
review.forkOf;      // the source's id
```

A task resumes only on the engine that saved it: if your app may no longer use it, `EngineRefusedError` (with the current `access`); if the engine stores sessions differently now, `StateChangedError`. Instructions appended with `setInstructions` aren't restored.

**Ending.** `await session.close()` ends it (`session/close`). A session also ends when the user presses Stop in Agneta, when its engine exits, when Agneta enforced a limit (`agneta/sessionStopped`), or when the connection closes: `session.ended` and the `ended` event say which (`{ reason: 'closed' | 'stopped' | 'disconnected', stoppedBy? }`). Show a user's Stop as stopped, not as an error; after an engine stop, load the session again.

## Turns

```js
const turn = session.prompt('Sort these notes by topic.');   // or a content block, or blocks (text, images)

for await (const event of turn) {
  switch (event.type) {
    case 'update':                      // ACP's session/update, discriminated by sessionUpdate
      if (event.update.sessionUpdate === 'agent_message_chunk') render(event.update.content);
      if (event.update.sessionUpdate === 'tool_call') showTool(event.update);
      break;
    case 'queued': showQueued(event.position); break;      // agneta/queued: waiting for room
    case 'rateLimited': showLimit(event.details); break;   // agneta/rateLimited
    case 'stopped': showStopped(event.stoppedBy); break;   // agneta/sessionStopped
  }
}
const result = await turn;
```

A turn is a promise of its result and an async iterable of its events. Events are buffered from the start, so iterating late, or twice, misses nothing; a failed turn's iterator throws its error after its events. `turn.textStream()` yields the reply's text pieces, `turn.updates()` the updates only, and `turn.text`, `turn.thought`, `turn.toolCalls` (each call with its updates merged) and `turn.events` are there at any time.

`result` is `{ stopReason, text, thought, usage, engineUsage, limit, cancelled, stoppedBy, toolCalls, raw }`:

- `usage` is Agneta's `agneta/usage`, from the engine's own records: `modelCalls`, `models`, `inputTokens`, `outputTokens`, cache tokens, `cost`, `costKind` (`estimated` for keys, `plan-equivalent` for plans), `taskCost`, `billing`, `ms`, `msToFirstToken`, `basis`. Unknown values are `null`. `engineUsage` is the engine's own figure.
- `limit` is `{ limit: 'maxTurns' | 'maxSeconds' | 'maxCostUSD', value, sessionEnded? }` when a policy limit stopped the turn. With `sessionEnded`, Agneta ended the session too: load it again to go on.
- `cancelled` is true after `session/cancel`, the user's Stop, or a time or cost limit.

| To | Call |
| --- | --- |
| Stop the turn | `turn.cancel()` or `session.cancel()` (`session/cancel`); or pass `signal` to `prompt` |
| Add input while it runs | `await turn.steer('Also…')` (`agneta/steer`): `{ delivery: 'accepted', runId }`, or `NoTurnRunningError` |
| Wait for room | nothing: a queued turn just returns later (`queued` events say its place) |

One turn at a time: `prompt()` while one runs throws `TurnBusyError`. A prompt has no timeout by default (`timeouts.prompt`); a policy's `maxSeconds` limits it. A provider's limit fails the turn with `RateLimitedError` (`resetsAt`, `account`, `providerMessage`); a paused account with `PausedError`; an account that must sign in again with `NeedsSignInError`.

## Model, effort, mode and instructions

```js
session.model;     // { id, name, current, choices: [{ value, name, group? }] }, found by ACP category 'model'
session.effort;    // the same for 'thought_level', where the engine has one
await session.setModel('opus');                 // session/set_config_option; the reply is the options as they are now
await session.setEffort('high');
await session.setConfigOption('some-id', value);
await session.setMode('plan');                  // session/set_mode; Agneta refuses modes that would leave what it set up
await session.setInstructions('Be brief.', { mode: 'append', key: 'tone' });   // agneta/instructions/set
session.on('configOptions', (options) => …);    // after a set, or the engine's config_option_update
```

Open the session before the user types to show these: it starts the engine but calls no model. The user's own defaults in Agneta come first. `findConfigOption(options, category)` and `configSetting(option)` read `configOptions` the same way, for raw results. A call the engine can't serve fails with `UnsupportedByEngineError`: check `capabilities` first.

## Permissions

With `approval: 'ask-app'`, the engine's permission requests reach your app. Answer them per session (`session.onPermission(handler)` or the `permissions` option of `newSession`), or for all sessions (the client's `permissions`). Without a handler they're declined.

```js
const client = new AgnetaClient({
  name: 'Example App',
  permissions: async ({ session, toolCall, options }) => {
    const ok = await askUser(`${toolCall.title}?`);
    return ok ? 'allow' : 'reject';      // or 'cancel', or { optionId }, or an ACP response
  }
});
```

`'allow'` picks the allow-once option (Agneta turns "always" into "once" anyway), `'reject'` the reject one. A handler that throws declines, and the client emits `error`. Every decision is in the task's trace.

## Traces

```js
const session = await client.newSession({ trace: true });
session.on('trace', (records) => …);            // agneta/trace, batched every 100 ms
session.on('traceOverflow', (after) => …);      // you read too slowly: read on from `after`

for await (const record of session.traceRecords({ after: 0, types: ['event', 'permission'] })) …   // pages of agneta/trace/read
const page = await client.readTrace(id, { after: 120, limit: 500 });   // { records, next, complete }, any of your tasks
```

Records are typed by `type` (`meta`, `config`, `acp`, `event` with its `kind`, `engine.message`, `engine.usage`, `permission`, `shell`, `stderr`, `lifecycle`, `end`); every one has `v`, `seq`, `t`, `mono`, `task` and `turn`. See [DIAGNOSTICS.md](https://github.com/olofd/agneta/blob/main/docs/DIAGNOSTICS.md#record-types).

## Errors

Everything the client throws is an `AgnetaError`, with Agneta's own `message`, an `advice` (what to tell the user, or do) and a literal `kind`, so a `switch` narrows to the class and its typed fields. Errors Agneta sent also have `code`, `data`, `details` (`data.agneta`) and `method`.

```js
import { isAgnetaError } from '@agneta/client';

try { await session.prompt(text); } catch (error) {
  if (!isAgnetaError(error)) throw error;
  switch (error.kind) {
    case 'needsSignIn': return show(`Sign in to your account in Agneta.`);
    case 'rateLimited': return show(`Try again after ${error.resetsAt?.toLocaleTimeString() ?? 'a while'}.`);
    case 'unenforceable': return show(`Agneta refused ${error.fields.join(', ')}: ${error.reason}`);
    default: return show(error.message);
  }
}
```

| `kind` | Class | When | Data |
| --- | --- | --- | --- |
| `notRunning` | `NotRunningError` | Nothing listens on Agneta's port | `url`, `openURL` |
| `refused` | `ConnectionRefusedError` | Something answered but wouldn't upgrade (a browser, a renderer, not Agneta) | `url` |
| `connectionClosed` | `ConnectionClosedError` | The connection was open and closed | `closeCode`, `closeReason` |
| `timeout` | `TimeoutError` | No answer in time; the connection stays open | `method`, `ms` |
| `aborted` | `AbortedError` | Your `AbortSignal` | `method` |
| `unsupportedEnvironment` | `UnsupportedEnvironmentError` | Running in a web page | |
| `protocol` | `ProtocolError` | Agneta's answer wasn't what this client knows (an old Agneta) | `detail` |
| `needsSignIn` | `NeedsSignInError` | Any error with `data.agneta.needsSignIn`: the account must sign in again in Agneta | `account` |
| `rateLimited` | `RateLimitedError` | Any error with `data.agneta.rateLimited` | `account`, `providerMessage`, `resetsAt` |
| `needsPairing` | `NeedsPairingError` | `-32001`: unknown token, access removed, Allow Once ended; or `pair: 'never'` with no token | |
| `notAllowed` | `NotAllowedError` | `-32002`: the user didn't allow the app | |
| `noTurnRunning` | `NoTurnRunningError` | `-32010`: steering with no turn running | |
| `turnBusy` | `TurnBusyError` | `-32011`: a turn is already running | |
| `queueFull` | `QueueFullError` | `-32012`: too many turns waiting; try again shortly | |
| `paused` | `PausedError` | `-32013`: the account is paused in Agneta | `account` |
| `unsupportedByEngine` | `UnsupportedByEngineError` | `-32014`: this engine can't do that | `engine` |
| `engineDownloading` | `EngineDownloadingError` | `-32015`: still downloading (sessions wait it out by default) | `progress` |
| `methodNotFound` | `MethodNotFoundError` | `-32601`: not a method Agneta offers | |
| `unenforceable` | `UnenforceableError` | `-32602` with `unenforceable`: a policy, scope, server list or mode Agneta can't enforce | `fields`, `reason` |
| `engineRefused` | `EngineRefusedError` | `-32602` with `access`: an engine the app may not use there, or not on this Mac | `access` |
| `accessChanged` | `AccessChangedError` | `-32602` with `accessChanged`: access changed while the session opened | |
| `stateChanged` | `StateChangedError` | `-32602` with `stateChanged`: the saved task's engine stores sessions differently now | `engine`, `saved`, `current` |
| `invalidParams` | `InvalidParamsError` | `-32602` otherwise, such as "Unknown session" | |
| `internal` | `InternalError` | `-32603`: the engine didn't start or stopped, or the app disconnected | |
| `rpc` | `UnknownRpcError` | Any other code, such as an engine's own (`-32000`) | |

`fromRpcError({ code, message, data })` makes the typed error from a raw one, and `ErrorCodes` names the codes.

## Events

`on(name, listener)` returns a function that removes the listener; `once` and `next(name, { filter, signal })` (a promise of the next one) work too.

| Client event | Arguments |
| --- | --- |
| `state` | the new `ClientState` |
| `pairingCode` | `code`, `{ code, name }` |
| `setup` | the kind, while Agneta's add-provider window waits |
| `catalogChanged` | the catalog |
| `accessChanged` | the access report (`client.access` is already it) |
| `paired` | the pairing result |
| `accessRemoved` | the `NeedsPairingError`; the token has been cleared |
| `disconnected` | the `ConnectionClosedError` |
| `reconnecting`, `reconnected` | attempt and delay; the access report |
| `engineDownloading` | `{ engine, received, total }` |
| `queued`, `rateLimited`, `sessionStopped` | the notification's params, for every session |
| `notification` | `method`, `params`: every notification |
| `error` | a permission handler's error |

| Session event | Arguments |
| --- | --- |
| `update` | every `session/update`, in a turn or not |
| `queued`, `rateLimited` | position; `{ account, message, resetsAt }` |
| `trace`, `traceOverflow` | records; `after` |
| `configOptions`, `mode` | the options; the mode id |
| `ended` | `{ reason, stoppedBy?, error? }` |

## The raw layer

`client.connection` is the connection itself: JSON-RPC 2.0 over the WebSocket, typed for every Agneta method and open to any other.

```js
const access = await client.request('agneta/access', {});                 // typed params and result
const other = await client.request('agneta/somethingNew', { … });         // any method
client.notify('session/cancel', { sessionId });                           // any notification
client.onNotification('agneta/queued', ({ sessionId, position }) => …);   // one method, typed
client.connection.on('message', (message, direction) => log(direction, message));   // every frame, both ways
client.connection.handle('session/request_permission', (params) => …);    // answer Agneta's requests yourself
```

`Connection.open({ url })` gives a connection without the client, for a client of your own. Requests take `{ timeout, signal }`; a timeout rejects that call only.

## Electron

Run the client in the main process (the renderer sends an `Origin` header, which Agneta refuses), and keep the token in the Keychain with `safeStorage`:

```js
import { app, dialog, safeStorage, shell } from 'electron';
import { join } from 'node:path';
import { AgnetaClient } from '@agneta/client';
import { safeStorageTokenStore } from '@agneta/client/node';

const client = new AgnetaClient({
  name: 'Example App',
  tokens: safeStorageTokenStore(safeStorage, join(app.getPath('userData'), 'agneta-token-47321')),
  launch: async ({ name, openURL }) => {
    const { response } = await dialog.showMessageBox({ message: `${name} isn't running`, buttons: [`Open ${name}`, 'Not Now'] });
    if (response !== 0 || !openURL) return false;
    await shell.openExternal(openURL);
    return true;
  }
});
await client.connect({ pair: 'never' }).catch(() => {});   // at launch: quietly, with the kept token
```

Give the renderer fixed actions through a preload bridge, never the token. [Project Chat](https://github.com/olofd/agneta/tree/main/examples/project-chat) and [Replica Bench](https://github.com/olofd/agneta/tree/main/examples/replica-bench) are complete Electron apps on this library.

## Reference

The package exports:

- **Client:** `AgnetaClient`, `connect(options)` (a client, connected), with `AgnetaClientOptions`, `ConnectOptions`, `ClientEvents`, `ClientState`, `Timeouts`, `ReconnectOptions`.
- **Sessions and turns:** `Session`, `Turn`, `TurnEvent`, `TurnResult`, `SessionEnd`, `NewSessionOptions`, `LoadSessionOptions`, `ForkOptions`, `ToolCallState`, `PromptInput`, `promptBlocks`, `httpMcpServer`.
- **Permissions:** `PermissionHandler`, `PermissionRequest`, `PermissionAnswer`, `permissionResponse`.
- **Access and settings:** `chooseProvider`, `providerEngines`, `engineInfo`, `findConfigOption`, `configSetting`.
- **Tokens:** `TokenStore`, `memoryTokenStore`; from `@agneta/client/node`: `fileTokenStore`, `safeStorageTokenStore`, `openAgneta`, `isListening`, `waitForPort`, `runningBuilds`.
- **The raw layer:** `Connection`, `JsonRpcMessage` and its parts, `RequestOptions`, `WebSocketLike`.
- **The protocol's types:** every method's params and result (`AgnetaRequests`, `AgnetaNotifications`, `AgnetaClientRequests`), `Access`, `Catalog`, `PairingScope`, `PairResult`, `Policy`, `SessionResult`, `PromptResult`, `AgnetaUsage`, `TraceRecord` and the rest; ACP's (`SessionUpdate`, `ContentBlock`, `ToolCall`, `SessionConfigOption`, …); `builds` (ports and open URLs) and `protocolVersion`.
- **Errors:** every class above, `AnyAgnetaError`, `isAgnetaError`, `fromRpcError`, `ErrorCodes`.

Every declaration has its documentation in the types, so an editor shows it.

## Development

```sh
npm ci
npm run build          # dist/
npm run typecheck      # the sources and test/types.test.ts
npm test               # unit tests against a stand-in Agneta
npm run test:integration   # against the real headless host (below)
```

The integration test needs, from the repository root, `scripts/fetch-engines` and `swift build --product agnetad` and `swift build --product agneta-fakes`. It runs its own `agnetad` with Goose and a fake model in a temporary folder, on ports 47800–47899, and leaves your Agneta alone. How it's built is in [DESIGN.md](DESIGN.md).

## Releasing

Maintainers publish from GitHub Actions only (`.github/workflows/client-typescript-release.yml`), with npm's trusted publishing and provenance:

1. Bump `version` in `package.json` and add its notes to [CHANGELOG.md](CHANGELOG.md), on `main`.
2. Push a tag `client-typescript-v<version>` (for example `client-typescript-v0.1.0`).
3. The workflow checks that the tag matches `package.json`, builds, type-checks and tests, then waits in the `npm` environment for a maintainer's approval before `npm publish --provenance`.
