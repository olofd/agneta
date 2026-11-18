# Agneta for apps: the protocol

How a Mac app runs AI work through Agneta. Agneta speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP, JSON-RPC 2.0) and adds a few namespaced extensions, each listed in `initialize`. An app that ignores them still gets plain ACP.

[Project Chat](../examples/project-chat/README.md) is a runnable Electron example with pairing, streamed replies, and app-owned MCP tools.

Every step on this page is exercised by the test suite: `Tests/AgnetaKitTests/AppScenarioTests.swift` runs it against a real engine, and `RouterContractTests.swift` pins each decision. How Agneta works inside is in [ARCHITECTURE.md](ARCHITECTURE.md); what each engine can do is in [ENGINES.md](ENGINES.md).

## Connecting

- **Address:** `ws://127.0.0.1:47321/acp` for releases, `47331` for development builds. Loopback only, one JSON-RPC message per text frame, frames up to 16 MB.
- **Browsers can't connect:** a WebSocket upgrade with an `Origin` header is refused, so a web page can't drive Agneta.
- **Sandboxed (Mac App Store) apps** need `com.apple.security.network.client` to connect to Agneta, and `com.apple.security.network.server` as well if they serve their own MCP server on loopback.
- **Folders for sandboxed apps.** A folder inside an app container (`~/Library/Containers`, `~/Library/Group Containers`) can't be a session's folder: Agneta keeps apps' private storage out of reach. Ask in the pairing scope for folders the user chose (an open panel or a security-scoped bookmark gives the real path, outside the container), or let tasks work in the workspace Agneta makes for the app and hand results back through the app's MCP tools: the sandbox keeps the app itself out of that workspace.
- **When Agneta isn't running,** the connection is refused. Tell the user to open Agneta; don't start it yourself.

## Pairing, once per app

1. Send `agneta/pair {"name": "Example App", "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"]}}`. Agneta opens its approval window, which shows what the scope asks for; the user picks which accounts the app may use (one is chosen to start with), then **Allow Once** or **Always Allow**.
   - **`scope`** is what the app will need: `tools`, the most built-in tools its sessions will use (`app-only`, `read` or `workspace`, as in the [policy](#agnetapolicy1)), and `folders`, the user's folders its sessions will work in (absolute paths, under the policy's folder rules). Without a scope the app gets app-only tools and no folders of the user's. Either way it also gets a workspace of its own, made by Agneta. Ask for what the app's features need, and no more: the user sees it all before deciding.
   - Allowed: `{"token": "…", "accounts": ["<account id>", …], "workspace": "<the app's own workspace>"}`. Keep the token in the app's Keychain. Agneta stores only its hash.
   - **Allow Once** grants this connection only: the token stops working when it closes, and Agneta keeps nothing. Pair again next time.
   - A scope Agneta can't accept (a folder it protects, an unknown field) is refused with `-32602` before the user is asked.
   - Don't Allow: error `-32002`. Closing the approval window, or leaving it unanswered for 5 minutes, is the same.
   - Several apps asking at once are shown one at a time. An app that disconnects while waiting withdraws its request.
2. Agneta identifies the connecting process by its code signature (see [ARCHITECTURE.md](ARCHITECTURE.md#pairing)). An app signed with an Apple-issued certificate and a team ID is shown as verified, by its signing identifier (for example `com.example.app`).
3. If Agneta can't verify the app (ad hoc or unsigned builds), it first sends `agneta/pairingCode {"code", "name"}` with six digits. Show the code prominently while the request waits. Agneta's approval window shows the same code, and the user allows the app only if the two match.
4. **Every session must fit the grant.** No more built-in tools than granted, and every folder a session names (`cwd`, `readable`, `writable`, `readOnly`) inside a granted folder or the app's own workspace. Anything else is refused with `-32602`, `data.agneta.unenforceable` naming the field. To need more, pair again with a wider scope.

## Every connection

`initialize`:

```json
{"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"agneta": {"token": "…"}}}
```

- **Result:** standard `agentCapabilities` (`loadSession: true`, images in prompts, HTTP MCP servers, `session/close`), plus:
  - `_meta.agneta.extensions`: the extensions below;
  - `_meta.agneta.accounts`: `[{"id", "label", "paused", "capabilities"}]`, the accounts this app may use. A paused account starts nothing new (**Pause**, under [Turns](#turns)). `capabilities` describes the engine this app's sessions on the account run on (see [the session result](#the-result)): the account's own, or the one the user chose for this app when allowing it or later in Settings → Apps. If that engine can't run now (OpenCode removed, Codex uninstalled), `session/new` fails with `data.agneta.engineUnavailable` naming it, rather than quietly running another engine.
  - `_meta.agneta.scope` (`{"tools", "folders"}`, what the user allowed) and `_meta.agneta.workspace` (the app's own workspace).
- **Error `-32001`** with `data.agneta.needsPairing: true` means the token is unknown, access was removed, an Allow Once grant has ended, or (for a verified app) the connecting program isn't the one that paired. Pair again.

| Extension | What it adds |
| --- | --- |
| `agneta/policy@1` | The session policy: tools, folders, network, approval, limits |
| `agneta/task@1` | A title and a stop warning shown in Agneta's menu |
| `agneta/instructions`, `agneta/instructions@1` | Instructions at start, and `agneta/instructions/set` between turns |
| `agneta/steer@1` | `agneta/steer` during a turn |
| `agneta/usage@1` | Each prompt result's usage: model calls, tokens, cost, and what the numbers mean |
| `agneta/limit@1` | Which policy limit stopped a turn |
| `agneta/queue@1` | `agneta/queued` when a turn waits for room |
| `agneta/fork@1` | `agneta/fork`: a new task that starts with a copy of an earlier one's conversation |
| `agneta/rateLimited@1` | `agneta/rateLimited` and structured error data when a provider's limit stops a turn |
| `agneta/trace@1` | The task's full trace, live and afterwards ([DIAGNOSTICS.md](DIAGNOSTICS.md)) |

## A session

`session/new`:

```json
{
  "cwd": "/Users/me/Documents/Example Project/Workspace",
  "mcpServers": [{"type": "http", "name": "app", "url": "http://127.0.0.1:<port>/mcp",
                  "headers": [{"name": "Authorization", "value": "Bearer <per-session token>"}]}],
  "_meta": {
    "agneta": {"account": "<account id>"},
    "agneta/policy@1": {"tools": "workspace", "network": "none", "approval": "never-ask",
                        "readable": [], "writable": [], "readOnly": [], "denied": [],
                        "limits": {"maxTurns": 200, "maxSeconds": 1800}},
    "agneta/task@1": {"title": "Tidying the project notes", "stopWarning": "Example App keeps the work so far"},
    "agneta/instructions": {"text": "You are Example App's assistant…"},
    "agneta/trace@1": {"live": true}
  }
}
```

**`cwd`** is the workspace: the folder the agent works in. It must be an absolute path, and the same rules as the policy's folders apply to it.

**`_meta.agneta.account`** chooses the account, one the app's grant allows. If it's omitted, the first allowed account is used.

**`mcpServers`** are the app's own tools: Streamable HTTP on loopback, with a bearer token.
- Only `type: "http"` with a `127.0.0.1`, `localhost` or `::1` URL is accepted. Anything else is refused with `-32602` and `data.agneta.unenforceable: ["mcpServers"]`: a stdio server would be a command run inside the engine's sandbox, and a remote one a host the policy didn't allow.
- The engine's sandbox may reach exactly those loopback ports. The exceptions: an app-only session on Goose shares one engine per account, which may reach any loopback port, and OpenCode may reach any loopback port (it runs a private server of its own).
- Your tools run in your app, with your app's own permissions: Agneta's sandbox confines the engine that calls them, not what they do.
- Header values are masked in traces.
- In tool events, the server's `name` comes back as the tool's `extension`, and the tool's own name as `tool`.

### `agneta/policy@1`

| Field | Values |
| --- | --- |
| `tools` | `app-only`: only the app's MCP tools. `read`: plus the engine's read-only built-ins. `workspace` (the default): plus editing and a shell, confined to the workspace |
| `network` | `none` (the default): shell commands reach nothing but the policy's `toolPorts` and `toolSockets`, and Claude Code's and Codex's commands and fetches are refused. The engine itself can reach any host on port 443, since it needs HTTPS for its provider and macOS's sandbox filters by port, not host name. A list of allowed hosts (`{"allow": [hosts]}`) isn't supported yet and is refused; `{"allow": []}` means `none` |
| `approval` | `ask-app` (the default): tool permission requests reach the app as `session/request_permission`. `never-ask`: the policy is the permission, and Agneta answers |
| `readable`, `writable`, `readOnly`, `denied` | Absolute paths. `readOnly` stays read-only even inside the workspace; `denied` is neither readable nor writable, even inside allowed folders |
| `toolPorts`, `toolSockets` | Loopback ports and Unix sockets that shell commands may reach (on engines whose shell runs through Agneta's broker: Goose and OpenCode) |
| `limits` | `maxTurns`: model calls within one prompt (default 200). `maxSeconds`: a prompt's wall time (default 4 hours). `maxCostUSD`: the task's known cost so far, across resumes (no default) |

- **Nothing is weakened silently.** A policy Agneta can't enforce is refused with `-32602` and `data.agneta.unenforceable: ["<field>"]`. That covers:
  - unknown fields, and malformed or non-positive limits;
  - relative paths, and folders that contain the home folder, other apps' containers, Agneta's own data, `~/Library/LaunchAgents`, `~/Library/Keychains` or `~/.ssh`;
  - a writable folder inside a denied one, or a denied workspace;
  - `maxCostUSD` on an engine that doesn't report cost per call (Claude Code, Codex).
- **Sending no policy** gives `workspace` tools in `cwd`, no network and `ask-app` approval.
- **Changing the engine's mode** (`session/set_mode`, or `session/set_config_option` with `configId: "mode"`) is refused where the mode would leave what Agneta set up: on Claude Code and Codex, a mode that stops the engine asking permission, since Agneta checks each tool call from those questions; on OpenCode, any agent but Agneta's, which carries the session's instructions.

### Instructions

`agneta/instructions.text`, or ACP's `systemPrompt`, sets the session's instructions. Goose, OpenCode and Claude Code use them as the system prompt; Codex appends them to its own instructions, which say how to use its tools ([ENGINES.md](ENGINES.md)).

### The result

- `sessionId`: Agneta's id, never the engine's.
- `_meta.agneta`: `account`, `dedicatedEngine` (whether the session has an engine process of its own), and `capabilities`:

| Field | Meaning |
| --- | --- |
| `engine` | `goose`, `opencode`, `claude-code` or `codex` |
| `steer` | `agneta/steer` works |
| `fork` | `agneta/fork` works |
| `instructionsBetweenTurns` | `agneta/instructions/set` works |
| `reportsCost` | Per-call cost is known while the turn runs, so `maxCostUSD` can be enforced |

- `configOptions` and `modes`: the engine's own, passed through (model, thinking effort, mode, …).

**Only Agneta's methods.** An app calls only the methods on this page. Anything else, including an engine's own methods, is refused with `-32601`, and notifications other than `session/cancel` are dropped: an engine's methods would bypass the checks made when the session started. Engine extras are reached through Agneta's methods (`agneta/steer`, `agneta/instructions/set`), which each engine's adapter maps.

Features differ by engine on purpose. Each engine's extras are offered where it has them, never trimmed to what all engines share. Check `capabilities` before offering a feature; a call the engine can't serve fails with `-32014`.

| | Goose | OpenCode | Claude Code | Codex |
| --- | --- | --- | --- | --- |
| Steering | Yes | Yes | Yes | Yes |
| Instructions between turns | Yes | No | No | No |
| Fork | Yes | No | No | No |
| Resume (`session/load`) | Yes | Yes | Yes | Yes |
| Cost | Per call | Per call | At the turn's end | No |

## Model and thinking

`session/set_config_option {"sessionId", "configId", "value"}` with the engine's own option ids (for example `model` or `thinking_effort`), before the first prompt or between turns. Changing account means a new session.

## Turns

`session/prompt {"sessionId", "prompt": [content blocks]}`. Text and images are supported in prompts and in MCP tool results.

While the turn runs, the engine's `session/update` notifications arrive unchanged, with Agneta's session id:
- `agent_message_chunk` and `agent_thought_chunk`;
- `tool_call` and `tool_call_update` (upserts by `toolCallId`; the first sighting may be a placeholder);
- `usage_update` (cumulative context size and used);
- `plan`;
- `session_info_update`.

The result:

```json
{"stopReason": "end_turn", "usage": {"inputTokens": 42, "outputTokens": 7, "totalTokens": 49},
 "_meta": {"agneta/usage@1": {"modelCalls": 2, "models": ["gpt-x"], "inputTokens": 84, "outputTokens": 14,
                              "cacheReadTokens": 0, "cacheWriteTokens": 0, "cost": null, "costKind": "estimated",
                              "taskCost": null, "billing": "api-key", "account": "…", "ms": 196.4, "msToFirstToken": 147.1,
                              "basis": "engine-ledger"},
           "agneta/limit@1": {"limit": "maxSeconds", "value": 1800}}}
```

- **`agneta/usage@1`** comes from the engine's own records, one entry per model call, summed over the turn. Nothing is counted from stream items.
  - `basis` says where the numbers come from: `engine-ledger` (the per-call records) or `engine-turn-totals` (the engine's own totals for the turn, which Claude Code needs; see [ENGINES.md](ENGINES.md#claude-code)).
  - `costKind` is `estimated` for API keys, and `plan-equivalent` for subscriptions, where the plan pays and nothing is charged per call.
  - Unknown values are `null`, never guessed.
  - `usage` is the engine's own figure for the turn, passed through.
- **`agneta/limit@1`** appears only when a policy limit stopped the turn. `maxTurns` ends with ACP's `max_turn_requests`; time and cost end as `cancelled`, with this field saying why. Limits are checked twice a second. A limit is a hard limit: if the engine hasn't stopped the turn 10 s after Agneta cancels it (stuck in a tool, or ignoring the cancel), Agneta ends the session (which stops its engine), sends `agneta/sessionStopped` with `stoppedBy: "limit"`, and answers the prompt the same way with `"sessionEnded": true` in this field. Load the session again to go on.
- **One turn at a time per session.** A prompt while one runs is refused with `-32011`. To add to a running turn, steer it.

| Method | Effect |
| --- | --- |
| `agneta/steer {"sessionId", "prompt": [blocks]}` | Adds input to the running turn. Returns `{"delivery": "accepted", "runId"}`. Error `-32010` when no turn is running, or it ended before the input arrived |
| `agneta/instructions/set {"sessionId", "text", "mode": "replace" \| "append", "key"?}` | `replace` (the default) sets the instructions; `append` adds a named part (`key`, default `app`) that a later append with the same key replaces |
| `session/cancel` (notification) | Ends the running turn with `cancelled` |
| `session/close` | Ends the session and, if it has one of its own, its engine |

**Waiting for room.** At most 8 turns run at once, and at most 3 per account; up to 32 more wait. A turn waits only behind earlier turns on the same account, so a busy account never holds up another. A waiting turn's app gets `agneta/queued {"sessionId", "position"}`, and the prompt simply returns later. `session/cancel` takes a waiting turn out at once (`cancelled`). A prompt when the queue is full fails with `-32012`.

**Resuming.** `session/load {"sessionId", "cwd", "mcpServers", "_meta"?}` reopens one of the app's earlier tasks after a close or an Agneta restart, within the history retention.
- Pass the tool servers again, since their bearers are per session. The policy and instructions default to the original ones; `_meta` may set new ones, and ask for live trace delivery.
- The engine returns to the same engine home and replays the conversation as `session/update`s before the result. The next turn sees the whole history, and the trace continues with the next sequence numbers.
- The result's `_meta.agneta.resumed` is true.
- It passes the same checks as `session/new`: the account (granted, not paused), the policy against the grant, the tool servers and the cost limit.
- Loading a session that's already open, or another app's, fails with `-32602`. A task that ran without built-in tools must be resumed without them.
- A task resumes only on the engine that saved it. If the account has moved to another engine since, or the engine stores sessions differently now, loading fails with `-32602` and `data.agneta.engineChanged {"saved", "current"}`; start a new task instead.
- Its cost goes on from where it was, so `maxCostUSD` counts the whole task, and so do the trace's turn and model-call numbers.
- Instructions appended with `agneta/instructions/set` aren't restored. Set them again after loading.

**Forking.** `agneta/fork {"sessionId", "mcpServers", "cwd"?, "_meta"?}` starts a new task with a copy of one of the app's tasks, open or finished: for example, to ask about a run without changing it.
- The new task has its own id, engine and trace. Its result's `_meta.agneta.forkOf` names the source. Prompts to it never touch the original.
- Its policy is `_meta`'s if given; otherwise it's the original's with `tools: "read"`.
- It keeps the original's instructions unless `_meta["agneta/instructions"]` sets new ones.
- It passes the same checks as `session/new`, and like a load it needs the engine that saved the original (`data.agneta.engineChanged` otherwise). Its cost starts from zero: it's a task of its own.

**Pause.** The user can pause an account in Agneta's menu. Then nothing new starts on it: `session/new`, `session/load`, `agneta/fork` and `session/prompt` fail with `-32013` and `data.agneta.paused`, and so does a prompt that was waiting in the queue. A turn already running finishes. Open sessions stay open and take turns again once the user resumes the account.

**Provider limits.** The engine first retries a provider's 429 itself. If the limit holds, the turn fails with the engine's error, and Agneta adds `data.agneta.rateLimited {"account", "message", "resetsAt"}`. It also sends `agneta/rateLimited` with the same fields and the `sessionId`, and Agneta's menu marks the account. `resetsAt` (UTC) is read from the provider's own words, such as "try again in 20s" or "resets 3pm", and is null when they give none. Retry after it, or use another account.

**Signed out.** When the engine says the account isn't signed in, the error keeps the engine's code (usually `-32000`, ACP's `auth_required`) and gains `data.agneta.needsSignIn: "<account id>"`. Agneta's menu asks the user to sign in again; tell the user to open Agneta.

**Stopped by the user.** Someone may press Stop in Agneta's menu. The app then gets `agneta/sessionStopped {"sessionId", "stoppedBy": "user"}`, and the running turn ends as cancelled. Show it as stopped by the user, not as an error.

**Engine stopped.** If the engine process ends on its own (it crashed, or was killed), its sessions end at once: the app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "engine"}` and a running turn fails. Resume the task with `session/load`, which starts a fresh engine.

## Permissions

With `approval: "ask-app"`, the engine's `session/request_permission` requests reach the app with Agneta's session id. Agneta applies two rules:
- **"Always" becomes "once".** An engine may keep an "always" answer beyond the session (OpenCode keeps it for the whole project), so Agneta answers with the matching "once" option.
- **Native runners are checked first.** Claude Code and Codex run their own tools, so Agneta answers each request for a built-in tool by its contract with every engine (`BuiltinTools`), before the app is asked: nothing built in under `app-only`; reading and searching (`read`, `search`) under `read`; also editing (`edit`, `delete`, `move`) under `workspace`; and never `execute` or `fetch` while the network is `none`.
- **The app's own tools are the app's.** A request for a tool of one of the app's MCP servers isn't refused by that contract (Codex asks for those as `execute`). Agneta trusts only what the engine's adapter vouches for: Codex's own MCP approval marker, Claude Code's tool names. A server can't take a name an engine uses for its own tools (Claude Code's `workspace` and `acp`, Codex's `codex_apps`): `session/new` refuses it with `-32602` and `unenforceable: ["mcpServers"]`.

Every decision is in the trace's `permission` records: who decided (`asked-app`, `allowed-by-policy`, `refused-by-policy`), the answer, and how long it took.

## The trace

Agneta writes a full trace of every task ([DIAGNOSTICS.md](DIAGNOSTICS.md), format `agneta/trace@1`). An app can read its own tasks, and only those.

- **Live:** with `"agneta/trace@1": {"live": true}` on `session/new` (or `session/load`), records arrive as `agneta/trace {"sessionId", "records": [...]}` notifications. They come in sequence order, batched every 100 ms in groups of up to 64, from `meta` to `end`. An app that reads too slowly to keep up (10,000 records waiting) gets one last `agneta/trace {"sessionId", "records": [], "overflow": {"after": <seq>}}`, and live delivery for that task stops; read on from `after` with `agneta/trace/read`. `"include": ["acp"]` adds the raw JSON-RPC frames of both connections.
- **Afterwards, or after a reconnect:** `agneta/trace/read {"sessionId", "after": <last seq>, "types"?: [...], "limit"?: 500}` returns `{"records", "next", "complete"}`. Page until `complete`. It works for running and finished tasks within the history retention, up to 5,000 records or about 8 MB a page (always at least one record).

Every record has `v`, `seq` (gapless), `t` (UTC with microseconds), `mono` (nanoseconds since the trace was opened or resumed), `task`, `turn` and `type`. Secrets are masked. The record types are listed in [DIAGNOSTICS.md](DIAGNOSTICS.md#record-types).

## Errors

| Code | Meaning |
| --- | --- |
| `-32000` | Usually the engine's "sign in first"; with `data.agneta.needsSignIn`, the account needs signing in again in Agneta |
| `-32001` | Not paired, or access removed (`data.agneta.needsPairing`) |
| `-32002` | The user didn't allow the app |
| `-32010` | `agneta/steer` with no turn running |
| `-32011` | A turn is already running in this session |
| `-32012` | Too many turns waiting; try again shortly |
| `-32013` | The account is paused in Agneta (`data.agneta.paused`); a turn already running finishes |
| `-32014` | This session's engine can't do that (`data.agneta.engine`); check `capabilities` first |
| `-32601` | Not a method Agneta offers; engines' own methods aren't reachable |
| `-32602` | Invalid parameters. For a policy, server list or mode, `data.agneta.unenforceable` names the field. "Unknown session" also uses it: another app's session, or an ended one |
| `-32603` | Agneta couldn't do it: the engine didn't start or stopped, or the app disconnected meanwhile |
