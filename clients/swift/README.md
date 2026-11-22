# AgnetaClient for Swift

Run agent tasks through the user's Agneta, on their own plan or API key. This is the official Swift client of [Agneta's app protocol](../../docs/APP_PROTOCOL.md), with the same client → session → turn structure as the [TypeScript client](../typescript/README.md).

Swift 6, macOS 14 or later. The library uses Foundation, AppKit and Security; it has no third-party library dependencies. Its mutable state and callbacks are isolated to `MainActor`, ready for SwiftUI and AppKit. Network operations suspend without blocking the main thread.

## Add it to your app

The repository's root Swift package exports the `AgnetaClient` product. Add the repository to Xcode's Package Dependencies, or use:

```swift
.package(url: "https://github.com/olofd/agneta.git", branch: "main")
// In your app target's dependencies:
.product(name: "AgnetaClient", package: "agneta")
```

Use a reviewed revision for a reproducible build while the client is unreleased. The root package also contains Agneta's host: SwiftPM resolves its dependencies, but the `AgnetaClient` product neither links the host nor starts it. To build the client alone without resolving host dependencies, use the standalone package in this folder as a local dependency:

```swift
.package(path: "../agneta/clients/swift")
// In the app target (the local package identity is its folder name):
.product(name: "AgnetaClient", package: "swift")
```

A sandboxed Mac app needs the `com.apple.security.network.client` entitlement to connect to loopback. Your MCP server also needs `com.apple.security.network.server` if your app serves tools. The library does not request entitlements or open files on the agent's behalf.

## Connect and prompt

Run this from a main-actor context, for example a SwiftUI model:

```swift
import AgnetaClient

let client = try AgnetaClient(
    name: "Example App",
    tokens: KeychainTokenStore(service: "com.example.app.agneta", account: "release")
)
let removeListener = client.onEvent { event in
    if case .pairingCode(let code) = event {
        // Show this code so the user can compare it with Agneta's approval window.
        showPairingCode(code)
    }
}

let access = try await client.connect()
let session = try await client.newSession()
let turn = try session.prompt("Summarize this project.")
for try await event in turn.events {
    if case .update(let update) = event,
       update.kind == "agent_message_chunk", let text = update.text {
        appendReply(text)
    }
}
let reply = try await turn.result
print(reply.text)
try await session.close()
removeListener()
client.close()
```

Keep the client alive while using it. The default token store is memory only. A Keychain store uses your app's own service, keeps pairing tokens on this device, and surfaces Keychain failures. Use a different account for each endpoint or build. Provider credentials remain inside Agneta; this library never receives them. Only an Always Allow token is saved. Allow Once is kept for its connection, and rejected stored tokens are cleared.

`connect(ConnectOptions(pair: .never))` is the quiet launch path: it uses a saved token and never pairs. `.ifNeeded` is the default; `.always` asks to pair again. A failed re-pair preserves an existing working connection. Pairing permissions still come from the user in Agneta.

## Getting Agneta

Without a guide, connecting returns typed errors such as `.notInstalled`, `.notRunning`, `.networkBlocked` or `.outdated`. `MacEnvironment` discovers the correct bundle through LaunchServices and the Applications folders, checking its bundle identifier and excluding a disk-image copy when an installed copy exists.

Pass a guide to present each decision in your own UI. Returning true authorizes just that step; accepting installation includes opening Agneta once installed. Cancelling the calling task or calling `close()` ends the flow, and a guide's late answer cannot open anything.

```swift
var connect = ConnectOptions()
connect.guide = { question in
    await showConfirmation(title: question.title, detail: question.detail,
                           confirm: question.confirm, cancel: question.cancel)
}
connect.onProgress = { progress in showStatus(progress.title) }
try await client.connect(connect)
```

The library never opens Agneta or a browser automatically without this agreement. `openAgneta()` and `openInstallPage()` are explicit actions for your own user-initiated buttons. `presence()` inspects availability, and `waitForAgneta()` waits for a running host. Installation has no deadline; waiting after opening defaults to five minutes. Cancel the calling task to stop waiting. `minimumVersion` in `ClientOptions` checks installed and connected versions; development builds are exempt.

For Agneta Dev use `build: .dev` (47331); releases use 47321. `ClientOptions.url` selects an isolated host; guided installation is disabled for a custom URL. `catalog()` works before pairing, `setup(kind:)` shows Agneta's provider window, and `waitForProvider(kind:timeout:)` waits for it. `ConnectOptions.setup` combines those before pairing. `ClientOptions.environment` can replace native discovery and opening.

## Sessions, policy and tools

```swift
var consent = ConnectOptions(pair: .always)
consent.scope = PairingScope(tools: .workspace, sandbox: "contained")
try await client.connect(consent)   // ask for the access this feature needs

var options = SessionOptions()
options.account = chooseProvider(client.access, sandbox: .contained)?.account
options.engine = "goose"
options.policy = Policy(
    tools: .workspace, sandbox: .contained, network: "none", approval: .neverAsk,
    limits: PolicyLimits(maxTurns: 50, maxSeconds: 600)
)
options.title = "Reviewing the project"
options.instructions = "Be concise."
options.appTools = .always
options.mcpServers = [HTTPMCPServer(name: "app", url: toolURL, token: perSessionBearer)]
let session = try await client.newSession(options)
```

`PairingScope` declares the app's tools, folders, providers, engines and sandbox at pairing. A session's policy must fit the grant; Agneta refuses anything it cannot enforce. With no session policy it uses the host's workspace/grant defaults. One-shot `client.ask` below instead defaults to app-only tools and never-ask approval.

`SessionOptions` covers the workspace (`cwd`), account, engine, every policy field, instructions, task title/stop warning, app-tool loading, MCP servers, live traces and result schemas. `meta` overrides convenience metadata; `params` carries other top-level fields, with the client's required routing/session fields taking precedence. Serving MCP tools remains your app's responsibility. Use a fresh bearer when opening or loading a session.

`session.capabilities` tells you whether steering, forking and instructions between turns work. The account, engine, sandbox, app-tools loading, builtins, dedicated-engine status, resume/fork metadata, raw result, model and effort are available on the handle. `chooseProvider` filters paused and signed-out providers and engines that cannot supply the requested sandbox. `refreshAccess()` refreshes usage in user limits; access-change notifications keep the report current when permissions change.

`loadSession(id, options:)` replays the saved conversation into `session.history`. `session.fork(options)` starts a separate task from its conversation. Loading retires the old handle; ended handles cannot submit work to a resumed task. A failed `session.close()` keeps the handle for retry; an `Unknown session` reply reconciles a lost close acknowledgement.

Engine downloads are retried for ten minutes by default, with `onDownloadProgress`. Set `waitForDownload = false` to return `.engineDownloading` immediately. `Timeouts` uses **seconds**, and zero disables a deadline. Ordinary requests default to 30 seconds, pairing to 310, session opening to 180, and prompts have no client deadline. If a session open/load/fork times out or is cancelled after being sent, the client closes that connection and ends all its sessions: the host might have created an engine whose id the app never received. Ordinary raw request timeouts leave the connection open.

## Turns and events

`prompt` returns a turn immediately, with one turn allowed per session. `turn.result` accumulates text, reasoning, merged tool calls, usage, engine usage, policy/user limits, stop reason and the raw response. Every access to `turn.events` creates an independent stream that replays its history. Unknown content/update fields survive in `raw`; `ContentBlock` has text, image, audio, resource-link and resource helpers.

Use `try await turn.cancel()` or `session.cancel()` to stop a turn. Cancelling a task awaiting `turn.result` sends cancel and waits for the host's result. A prompt timeout also sends cancel before releasing the local turn. Cancelling only an event-stream consumer removes its subscription; call cancel explicitly if the work should stop too. `turn.steer` supplies input to a running turn and refuses a completed turn.

`session.onEvent` reports updates, queue position and what it waits for, rate limits, trace records/overflow, config/mode changes and the session ending. `client.onEvent` reports lifecycle, pairing codes, progress, access/catalog changes, reconnecting and every raw notification. Subscriptions return an unsubscribe closure. Callbacks run synchronously in wire order; incoming requests run independently so an asynchronous permission dialog cannot block responses.

Replay buffers are bounded by count and estimated payload bytes (`ClientOptions.buffers`): 100,000 events/64 MB per turn, and 16 opening sessions, 10,000 events per opening session/16 MB combined. Exceeding a budget fails with `.bufferOverflow` and closes the connection and its sessions. Native WebSocket frames are limited to 16 MB. Raise the replay budgets for workloads that need more retained history; callbacks allow you to consume and persist updates as they arrive.

## Structured results

Agneta checks JSON Schema before accepting the model's submission. Decode only an accepted value into your app's type:

```swift
struct Invoice: Decodable, Sendable {
    let number: String
    let total: Double
}
let schema: JSONValue = [
    "type": "object",
    "properties": ["number": ["type": "string"], "total": ["type": "number"]],
    "required": ["number", "total"], "additionalProperties": false
]
let answer = try await client.ask("Extract the invoice.", schema: schema, as: Invoice.self)
let invoice = answer.value
```

One-shot `client.ask` creates a session, asks once and closes it on success, failure or cancellation. For a conversation, set `SessionOptions.results = ResultDeclaration(schemas: ["invoice": schema], every: "invoice")`, then `let answer = try session.ask("Extract it", as: Invoice.self)`. Await `answer.value` or `answer.details`, and use `answer.turn` for streaming/cancellation. `name` selects among declared schemas and `attempts` sets the host's budget (1–10). Ordinary prompts can opt out with `result: .disabled`.

Non-object roots are wrapped and unwrapped, including local references; saved schemas let a loaded/forked handle reconstruct this. The extension is checked before sending. `ResultFailure` distinguishes missing submissions, host-invalid values and Swift decoding failures, retaining the report and turn result. A later engine failure remains an `AgnetaError`; its `structured` report preserves any accepted value. Decoding cannot override a host-invalid result. Schema-valid does not mean factually correct; review values before acting on them. The [protocol](../../docs/APP_PROTOCOL.md#structured-results) defines the supported schema subset.

## Settings, permissions and traces

`setModel`, `setEffort`, `setConfigOption`, `setMode` and `setInstructions` change a session between turns, where its engine supports it. `ConfigOption.choices` flattens grouped choices and includes an unlisted current value. Raw settings and unknown categories remain available.

Set `ClientOptions.permissions` or `SessionOptions.permissions` to an async handler returning `.allow`, `.reject`, `.cancel` or `.option(id)`. Once-options are preferred. Without a handler, or if it throws, permission is rejected. The library installs no filesystem or terminal handlers; unsupported incoming requests get JSON-RPC `-32601`.

`session.readTrace`/`client.readTrace` read a page; `client.traceRecords(id, after:types:limit:)` is a lazy paged sequence. Nonadvancing pages fail instead of looping. Set `SessionOptions.trace` for live records, attach `onEvent` before opening to receive early records, and recover a live overflow from its cursor. Trace timestamps/sequence integers stay 64-bit integers.

## Raw access and reconnection

`client.connection` is the same JSON-RPC connection used by the higher layers:

```swift
let raw = try await client.request("agneta/newMethod", params: ["example": true])
let catalog: Catalog = try await client.connection!.request(
    "agneta/catalog", params: JSONValue.object([:]), as: Catalog.self
)
client.connection?.handle("custom/request") { params in params }
```

`Connection.open()` also works independently. `request`, `notify`, incoming request handlers and a redacted message event expose the whole protocol. Tokens in pairing replies and initialize requests are masked in the message observer; raw results, pairing return values and your own content can still contain sensitive data, so log selectively. The native transport has no cookie/credential storage or proxy and refuses redirects.

`AgnetaError.kind` identifies transport and RPC failures. `code`, `data`, `method`, structured sign-in/rate-limit/download information and the host's original message remain available. Swift task cancellation uses `CancellationError`. A `.needsPairing` failure clears a stored token during connect; a provider's `.needsSignIn` means the user signs in again inside Agneta. User spending/task limits stay visible in `Access.limits`, `.appLimit` data and turn usage/limits.

Reconnecting is opt-in: set `ClientOptions.reconnect = ReconnectOptions()`. It uses a remembered token with bounded exponential backoff, never pairs or opens Agneta, and stops if access was removed. Sessions end when their connection ends; load a saved id explicitly to continue. `close()` cancels the flow and suppresses reconnection.

## Development

From the repository root:

```sh
swift test --package-path clients/swift -Xswiftc -warnings-as-errors
# Native Foundation transport against the Node 22+ protocol stand-in:
AGNETA_CLIENT_NATIVE_TESTS=1 swift test --package-path clients/swift
# Real host + Goose + fake model and MCP server, no provider account or paid calls:
scripts/fetch-engines
swift build --product agnetad
swift build --product agneta-fakes
swift build --product agneta-shell
AGNETA_CLIENT_INTEGRATION=1 swift test --package-path clients/swift
```

The standalone unit suite uses an injected transport and needs no running Agneta, network or Keychain changes. Native tests add real WebSocket frames, refused upgrades and redirect refusal. The host integration uses isolated folders and ports 47700–47799, cleans up its processes, and retains logs on failure. CI runs all three on the supported macOS runners. No library, tag or release is published by these commands.
