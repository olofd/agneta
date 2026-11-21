# Agneta for apps: the protocol

How a Mac app runs AI work through Agneta. Agneta speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP, JSON-RPC 2.0) and adds a few namespaced extensions, each listed in `initialize`. An app that ignores them still gets plain ACP.

**In TypeScript or JavaScript, use [`@agneta/client`](../clients/typescript/README.md),** the official client: it implements everything on this page (connecting, and getting and opening Agneta, pairing and the token, access, sessions, streaming, permissions, traces and every error, typed) and keeps a raw layer for anything else. Two runnable Electron examples are built on it: [Project Chat](../examples/project-chat/README.md), with pairing, streamed replies, and app-owned MCP tools, and [Replica Bench](../examples/replica-bench/README.md), which runs demanding work on every engine in both sandbox modes.

Every step on this page is exercised by the test suite: `Tests/AgnetaKitTests/AppScenarioTests.swift` runs it against a real engine, and `RouterContractTests.swift` pins each decision. How Agneta works inside is in [ARCHITECTURE.md](ARCHITECTURE.md); what each engine can do is in [ENGINES.md](ENGINES.md).

## Connecting

- **Address:** `ws://127.0.0.1:47321/acp` for releases, `47331` for development builds. Loopback only, one JSON-RPC message per text frame, frames up to 16 MB.
- **Before it has a grant** (until pairing or `initialize` succeeds), a connection is anything on this Mac and gets little: at most 16 such connections at once, messages up to 256 KB, and 10 minutes to pair. Past any of these, Agneta closes it.
- **Browsers can't connect:** a WebSocket upgrade with an `Origin` header is refused, so a web page can't drive Agneta.
- **Sandboxed (Mac App Store) apps** need `com.apple.security.network.client` to connect to Agneta, and `com.apple.security.network.server` as well if they serve their own MCP server on loopback.
- **Folders for sandboxed apps.** A folder inside an app container (`~/Library/Containers`, `~/Library/Group Containers`) can't be a session's folder: Agneta keeps apps' private storage out of reach. Ask in the pairing scope for folders the user chose (an open panel or a security-scoped bookmark gives the real path, outside the container), or let tasks work in the workspace Agneta makes for the app and hand results back through the app's MCP tools: the sandbox keeps the app itself out of that workspace.
- **When Agneta isn't running,** the connection is refused. Find out whether it's installed, and help the user get it or open it: [Getting Agneta](#getting-agneta).

### Getting Agneta

An app can tell whether Agneta is running, installed but not running, or not installed, and take the user from any of them to a working connection without restarting. [`@agneta/client`](../clients/typescript/README.md#getting-agneta) does all of it (`connect({ guide })`); this is the recipe for apps that write their own. Every call named here works in a sandboxed app without an entitlement, except connecting.

1. **Running?** Connect to the port. Refused means not running (or not installed). A sandboxed app without `com.apple.security.network.client` gets `EPERM` ("Operation not permitted") instead: that's the app's missing entitlement, not Agneta, and the app should say so.
2. **Installed?** Ask LaunchServices which app opens `agneta://open` (`agneta-dev://open` for a development build): `NSWorkspace.shared.urlForApplication(toOpen:)`, or in Electron's main process `app.getApplicationInfoForProtocol(url)`. Read that bundle's `Info.plist`: its `CFBundleIdentifier` must be `com.objectivecoder.agneta` (`com.objectivecoder.agneta.dev`), or another app claimed the scheme and Agneta counts as not installed; its `CFBundleShortVersionString` is Agneta's version. LaunchServices doesn't see a copy just put in `~/Applications` until something opens it, so when it finds nothing, also look for `Agneta.app` (`Agneta Dev.app`) in `/Applications` and `~/Applications`, and open such a copy by its path, which registers it.
3. **Where?** In `/Applications` or `~/Applications`, or anywhere else (a developer's build folder): installed. On a disk image (a read-only volume under `/Volumes`: a write check there fails with `EROFS`) or translocated (a path containing `/AppTranslocation/`): not installed yet. LaunchServices may prefer a disk image's copy it has seen over a new one in `~/Applications`, so when it answers with a disk image's copy, look in the Applications folders too. A copy run from its disk image ends when the image is ejected, so say "drag Agneta into Applications first" and wait. (Agneta itself also offers to move there when started from its disk image.)
4. **Not installed:** offer to get it. The install page is **`https://agneta.dahlbom.io/get/`**, an address that stays: it explains what Agneta is, offers both downloads and Homebrew, and has an **Open Agneta** button for afterwards. Add the Mac's architecture as the fragment (`#arm64` or `#x86_64`) to put the right download first, and nothing else: no query string, nothing about the app or the user. The architecture is the Mac's, not the app's: an Intel build of the app on Apple silicon runs under Rosetta, where `sysctl.proc_translated` is 1. Offer Homebrew as the other way, with a Copy button: `brew install olofd/tap/agneta`. For a development build, point to the README's [Build and run](../README.md#build-and-run) instead. Then wait, with no timeout (the user cancels): check the port every second, and the install check every second or two. When Agneta is installed, open it; when the port answers first (the user opened it), go on.
5. **Installed, not running:** ask, then open `agneta://open`. Wait for the port: every 250 ms for the first 5 s, then every second. A first launch may wait for macOS's "downloaded from the Internet" confirmation, so at 15 s say that macOS may be asking whether to open Agneta, and at 60 s offer to keep waiting or cancel (still waiting meanwhile).
6. **Too old:** an app that needs a newer Agneta compares the bundle's version before opening it, and `agneta/catalog`'s `version` once connected. An Agneta that answers `agneta/catalog` with `-32601` is 0.4.0 or earlier (count it as 0.4.0). A development build says `0.0.0`, and the headless host or `swift run`, which have no bundle, say `dev`: both are built from source, so they're never too old. Compare versions by their numbers (`0.5.0-beta` is `0.5.0`). Ask the user to open Agneta and choose **Check for Updates…** in its ⋯ menu; Agneta relaunches after updating, so wait for the connection to close and the port to answer again, then check again.
7. **Running:** go on to [Before pairing](#before-pairing-what-agneta-offers).

**Consent.** One question per step, each answered by the user: getting Agneta, opening it, updating it, and connecting a provider (`agneta/setup`). A yes to getting Agneta covers opening it once it's installed, within that flow; opening it at any other time needs its own yes. Never open Agneta, or the install page, without asking: quitting Agneta is how the user stops all of it. Opening `agneta://open` only launches Agneta; nothing in the URL is acted on. A quiet connect at launch asks nothing, except to offer opening Agneta to someone who has used the app before (a token kept).

**What an app learns** this way is whether Agneta is installed (and whether in Applications), its version, and whether it's running: what any Mac app can find out from LaunchServices. Don't look further (for Homebrew, or other apps), keep the bundle's path to yourself, and send none of it anywhere.

## Before pairing: what Agneta offers

Two calls work on a connection that hasn't paired, so an app can find out whether there's anything to ask for, and help the user set it up when there isn't.

- **`agneta/catalog {}`** returns what this Agneta offers any app:
  - each provider kind (`claude`, `chatgpt`, `anthropic-key`, `openai-key`), with its name, whether one is `connected`, and the engines it runs on, each with the modes it can provide (`sandboxLevels`) and `uncontained` where it can't be contained;
  - the engines on this Mac (`id`, `name`, `state`, `reason`);
  - `connected`: whether any provider is;
  - `version`: Agneta's version, as its bundle says (`0.0.0` for a development build; `dev` with no bundle, as for the headless host), so an app can ask for an update before pairing ([Getting Agneta](#getting-agneta)).

  It never names the user's accounts (labels, addresses, how many): pairing guards those. An unpaired connection also gets `agneta/catalogChanged {"catalog"}` when a provider is connected or removed, or an engine changes.

  ```json
  {"providers": [{"kind": "claude", "name": "Claude plan", "connected": true,
                  "engines": [{"id": "claude-code", "sandboxLevels": ["contained", "developer"]},
                              {"id": "goose", "sandboxLevels": ["developer"], "uncontained": true}]}, …],
   "engines": [{"id": "claude-code", "name": "Claude Code", "state": "ready"}, …],
   "connected": true, "version": "0.5.0"}
  ```
- **`agneta/setup {"name"?, "kind"?}`** asks Agneta to help the user connect a provider. Agneta comes forward with its add-provider window, naming your app, narrowed to `kind` when given. It answers `{"shown": true}` at once; wait for `agneta/catalogChanged`. Ask only when the user asked to connect, as with opening Agneta.

**A smooth first run.** On Connect, call `agneta/catalog`. If no provider of a kind you need is connected, say so and offer to set it up (`agneta/setup`), then pair once one is. Or pair straight away: with nothing connected, the approval window lets the user connect a provider in place, and the request waits for it (within the 5 minutes the window waits). An unpaired connection is closed after 10 minutes, time spent in `agneta/setup` included: connect again if the user took longer.

## Pairing, once per app

1. Send `agneta/pair {"name": "Example App", "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"]}}`. Agneta opens its approval window, which shows what the scope asks for; the user ticks the providers the app may use (one is ticked to start with), then **Allow Once** or **Always Allow**. For an app with `workspace` tools, the user also chooses **Developer access** or **Contained** ([Sandbox](#sandbox)). Every engine is allowed too, unless the user narrows them under **Engines…**: your app picks the provider and engine of each task, among what it may use ([Access](#access)).
   - **`scope`** is what the app will need: `tools`, the most built-in tools its sessions will use (`app-only`, `read` or `workspace`, as in the [policy](#agnetapolicy)), `folders`, the user's folders its sessions will work in (absolute paths, under the policy's folder rules), and optionally the providers, engines and sandbox mode (below). Without a scope the app gets app-only tools and no folders of the user's. Either way it also gets a workspace of its own, made by Agneta. Ask for what the app's features need, and no more: the user sees it all before deciding.
   - **Ask for exactly what you need.** The scope can also name the providers, engines and mode, and the approval window is narrowed to them:
     - `providers`: `"all"` or a list of kinds (`["claude"]`). It shows only providers of those kinds, ticked (all of them for `"all"`, the first of each kind for a list). A kind not connected gets a **Connect** row: the request waits while the user connects it, and it's ticked once connected. Left out, the user picks among all providers, with one ticked to start.
     - `engines`: `"all"` or a list of engine ids (`["claude-code"]`). The window names them. Left out, every engine.
     - `sandbox`: `"contained"`, `"developer"` or `"any"`. With `"contained"`, the window shows it fixed: you asked for no more, so no more is offered. With `"developer"` or `"any"` (the same as leaving it out), the picker starts on Developer access, and the user may choose Contained. The mode applies only with `workspace` tools: with fewer, tasks stay contained whatever `sandbox` says.
     - The user can still give less than you asked. A provider that can't be given as asked (contained, but none of its engines can keep it so) says why, and can't be ticked.

     For example, the smallest grant for a task that needs a Claude plan on Claude Code, contained: `{"tools": "workspace", "providers": ["claude"], "engines": ["claude-code"], "sandbox": "contained"}`. Everything: `{"tools": "workspace", "providers": "all", "engines": "all", "sandbox": "any"}`.
   - Allowed: `{"token": "…", "remembered": true, "access": {…}, "unmet": […]}` ([Access](#access)). Agneta stores only the token's hash. `unmet` lists what of your ask wasn't given, each with a `reason`: `{"provider": "chatgpt", "reason": "not connected in Agneta"}` (or "the user didn't allow it"), `{"engine": "codex", …}`, `{"sandbox": "developer", "reason": "the user chose contained"}` (or "developer access needs workspace tools", for a scope with fewer), or `{"provider": "claude", "sandbox": "contained", …}` when none of its engines can keep it contained. It's empty when you got everything you asked for.
   - **Always Allow** (`remembered: true`): keep the token in the app's Keychain and connect with it next time (`initialize`), without asking again. When `initialize` answers `-32001` (`needsPairing`), the user removed the app's access: forget the token, and pair again when the user asks to connect. Agneta also closes the app's open connections when its access is removed.
   - **Allow Once** (`remembered: false`) grants this connection only: the token stops working when it closes, and Agneta keeps nothing. Pair again next time.
   - **Pairing again** with Always Allow, for an app that has remembered access already, replaces that access instead of adding to it, and the old token stops working. The approval window says so.
     - A **verified** app (the same signing identity) keeps its grant: its workspace and tasks to resume, with what the user just allowed. Its other open connections get the new access at once, as `agneta/accessChanged`; their sessions outside it stop, with `agneta/sessionStopped`.
     - An app Agneta **can't verify** is known only by its name, which another program could give, so its new grant starts afresh: a new workspace, and none of the earlier tasks to resume. The earlier grant is removed, and connections still using it are closed.
   - A scope Agneta can't accept (a folder it protects, an unknown field, kind or engine) is refused with `-32602` before the user is asked; the reason lists what there is.
   - Don't Allow: error `-32002`. Closing the approval window, or leaving it unanswered for 5 minutes, is the same.
   - Several apps asking at once are shown one at a time. An app that disconnects while waiting withdraws its request.
2. Agneta identifies the connecting process by its code signature (see [ARCHITECTURE.md](ARCHITECTURE.md#pairing)). An app signed with an Apple-issued certificate and a team ID is shown as verified, by its signing identifier (for example `com.example.app`).
3. If Agneta can't verify the app (ad hoc or unsigned builds), it first sends `agneta/pairingCode {"code", "name"}` with six digits. Show the code prominently while the request waits. Agneta's approval window shows the same code, and the user allows the app only if the two match.
4. **Every session must fit the grant.** No more built-in tools than granted, no more than the grant's [sandbox](#sandbox), and every folder a session names (`cwd`, `readable`, `writable`, `readOnly`) inside a granted folder or the app's own workspace. Anything else is refused with `-32602`, `data.agneta.unenforceable` naming the field. To need more, pair again with a wider scope.

## Every connection

`initialize`:

```json
{"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"agneta": {"token": "…"}}}
```

- **Result:** standard `agentCapabilities` (`loadSession: true`, images in prompts, HTTP MCP servers, `session/close`), plus:
  - `_meta.agneta.extensions`: the extensions below;
  - `_meta.agneta.access`: what the app may use ([Access](#access)).
- **Error `-32001`** with `data.agneta.needsPairing: true` means the token is unknown, access was removed, an Allow Once grant has ended, or (for a verified app) the connecting program isn't the one that paired. Pair again.

### Access

What the user allows an app is two lists: the **providers** (each an account: a ChatGPT or Claude plan, an API key) and the **engines** (Goose, OpenCode, Claude Code, Codex; all of them unless the user narrowed them). Each task runs on one provider and one engine, which your app picks; the pair must be one the provider supports ([ENGINES.md](ENGINES.md)) and this Mac can run. `agneta/access {}` returns, at any time, what that means now, the same object `initialize` and pairing return:

```json
{
  "providers": [{"id": "a1b2c3d4", "label": "Claude", "kind": "claude", "paused": false, "needsSignIn": false,
                 "engines": ["claude-code", "goose"], "defaultEngine": "claude-code", "uncontained": ["goose"],
                 "sandboxLevels": {"claude-code": ["contained", "developer"], "goose": ["developer"]}}],
  "engines": [{"id": "claude-code", "name": "Claude Code", "state": "ready", "capabilities": {…}},
              {"id": "goose", "name": "Goose", "state": "ready", "capabilities": {…}},
              {"id": "opencode", "name": "OpenCode", "state": "downloadable", "size": 113000000}],
  "allowedEngines": "all",
  "scope": {"tools": "workspace", "folders": ["/Users/me/Documents/Example Project"], "sandbox": "developer"},
  "workspace": "/Users/me/Library/Application Support/com.objectivecoder.agneta Workspaces/<grant>",
  "limits": {"atOnce": {"max": 2, "running": 0}}
}
```

- **`providers`:** each provider the app may use. `engines` are those its tasks there may run on now or after a download, the default first (`defaultEngine`: the provider's default in Agneta's settings when allowed, else the first allowed). A paused provider starts nothing new (**Pause**, under [Turns](#turns)); one that `needsSignIn` waits for the user in Agneta. `uncontained` lists the engines here whose own tools Agneta's policy doesn't confine: Goose on a Claude plan runs Claude Code as its model, with all of Claude Code's own tools and the claude.ai account's connectors, as in a terminal. Agneta still keeps that engine to the session's folders, but not to the policy's tool, network or approval rules, so it provides developer access only: a contained task on it is refused. Offer it as a choice, and say so to your users where they pick an engine. `sandboxLevels` gives, for each engine, the modes it can provide here ([Sandbox](#sandbox)).
- **`engines`:** each engine the app may use, with its `state` on this Mac: `ready` (with its `capabilities`, as in [the session result](#the-result)), `downloading` (`received`, `total`), `downloadable` (`size`: it downloads when first needed), `failed` (`reason`; asking for it tries again) or `unavailable` (`reason`, such as "Install Codex 0.166 or later").
- **`allowedEngines`:** `"all"` (including engines Agneta adds later) or the engine ids the user ticked.
- **`scope`** and **`workspace`:** what the user allowed, and the app's own workspace within it.
- **`limits`:** the limits the user set for the app, and where it stands ([Limits the user sets](#limits-the-user-sets)). Absent when there are none. A provider's `uncounted` lists engines its tasks can't use while a spending limit counts that provider.
- **`agneta/accessChanged {"access"}`** arrives when any of it changes: the user changes the app's providers, engines, sandbox mode or limits in Agneta's settings (sessions that no longer fit stop, with `agneta/sessionStopped`), a provider is paused, resumed, signed out or needs signing in, or an engine arrives, starts downloading or goes away. Download progress doesn't send it: `agneta/access` and `-32015` carry it.

| Extension | What it adds |
| --- | --- |
| `agneta/policy` | The session policy: tools, folders, sandbox, network, approval, command environment and ports, limits |
| `agneta/access` | `agneta/access` and `agneta/accessChanged`: the providers and engines the app may use ([Access](#access)) |
| `agneta/catalog` | `agneta/catalog` and `agneta/catalogChanged`: what Agneta offers, and its version, before pairing too ([Before pairing](#before-pairing-what-agneta-offers)) |
| `agneta/setup` | `agneta/setup`: Agneta's add-provider window, for the user to connect one |
| `agneta/task` | A title and a stop warning shown in Agneta's menu |
| `agneta/instructions` | Instructions at start, and `agneta/instructions/set` between turns |
| `agneta/appTools` | The app's MCP tools in the model's context from the first request, on every engine ([`agneta/appTools`](#agnetaapptools)) |
| `agneta/result` | A value checked against the app's JSON Schema, from a turn ([Structured results](#structured-results)) |
| `agneta/steer` | `agneta/steer` during a turn |
| `agneta/usage` | Each prompt result's usage: model calls, tokens, cost, and what the numbers mean |
| `agneta/limit` | Which limit stopped a turn: the policy's, or one the user set for the app |
| `agneta/queue` | `agneta/queued` when a turn waits for room, and what for |
| `agneta/fork` | `agneta/fork`: a new task that starts with a copy of an earlier one's conversation |
| `agneta/rateLimited` | `agneta/rateLimited` and structured error data when a provider's limit stops a turn |
| `agneta/trace` | The task's full trace, live and afterwards ([DIAGNOSTICS.md](DIAGNOSTICS.md)) |
| `agneta/appLimits` | The limits the user sets for the app: `limits` in the access report, `-32016`, `agneta/limit`'s `setBy`, `agneta/queued`'s `waitingFor`, `agneta/usage`'s `app` ([Limits the user sets](#limits-the-user-sets)) |

### Limits the user sets

The user can limit each app in Settings → Apps. Every limit is optional, and none is set unless the user sets it. They hold whatever the app's policy says; the policy's own limits ([`agneta/policy`](#agnetapolicy)) are separate, and checked first.

| Limit | What it counts | When it's reached |
| --- | --- | --- |
| `spend`: up to so many US dollars a day, a week or a month | What the app's tasks on **API keys** cost, at the engine's prices: each turn's share of its task's known cost, the basis of `agneta/usage`'s `taskCost` and `maxCostUSD`. A Claude or ChatGPT plan isn't charged per call (the plan pays), so its tasks are neither counted nor stopped, and a spending limit isn't offered for an app that uses only plans | The app's running turns on API keys stop, and its prompts, new tasks, forks and loads on API keys are refused with `-32016` until it resets |
| `atOnce`: so many at once | The app's running turns, across all its connections and providers | More wait their turn, as for a busy account: `agneta/queued` with `waitingFor: "app"` |
| `newTasks`: so many an hour or a day | `session/new` and `agneta/fork`. `session/load` continues a task and isn't a new one | `session/new` and `agneta/fork` are refused with `-32016` |

- **Periods.** An hour is rolling: the last 60 minutes. A day, a week and a month are calendar periods in the user's time zone: they reset at midnight, at the start of the week, and on the 1st.
- **The limits stay with the app.** Pairing again, Always Allow or Allow Once, keeps the app's limits and what it has used: a new pairing isn't a fresh budget.
- **Spending, by engine.** How close a turn stays to the limit depends on when its engine reports cost (`counted` in the report below; [ENGINES.md](ENGINES.md)):
  - **Goose and OpenCode** (`live`): from the engine's own records, read every 2 seconds while a turn runs. At the limit every running turn of the app on an API key stops as a policy limit stops one, within half a second: cancelled, and the session ended if the engine hasn't stopped 10 seconds later. Each running turn can pass the limit by what it spends before Agneta reads it (Goose records a model call when it ends, OpenCode a step when it ends, after the tools it called ran) and by what it spends in those 10 seconds. What an engine records after a turn's last read still counts, at the next turn or when the session closes.
  - **A model the engine has no price for** (Goose reports none, OpenCode $0, for a model its price list doesn't have, such as a local one) costs nothing as far as the limit can tell: such a turn isn't counted. It's marked, not hidden: `agneta/usage`'s `app` says `"unpriced": true`, the trace has an `unpriced` record, and Settings says how many of the app's turns today had no price.
  - **Claude Code** (`turn-end`): its cost is known when a turn ends, so the limit is checked before each turn and task, and a turn can go over it: by at most one turn for each of the app's tasks running at the time.
  - **Codex** reports no cost, so the limit can't count it. While a spending limit is set, the app's tasks on an OpenAI API key can't run on Codex: asking for it is refused with `-32602`, "Codex reports no cost, so it can't run under the spending limit you set for this app in Agneta", and `data.agneta.access`; a task that names no engine runs on another; the provider's entry leaves Codex out of `engines` and names it in `uncounted`. A task on Codex with an API key that was open when the user set the limit stops: the app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "limit", "limit": {"limit": "appSpend", "setBy": "user", "value": 5, "period": "day", "reason": "Codex reports no cost, …"}}`, and a running prompt answers `cancelled` with the same `agneta/limit` and `"sessionEnded": true`. On a ChatGPT plan Codex runs as always: plans aren't counted.
- **What your app sees.** `limits` in the [access report](#access), only for the app itself:

  ```json
  "limits": {
    "spend": {"max": 5, "currency": "USD", "period": "day", "whenReached": "stop", "used": 1.23, "resetsAt": "2026-11-20T23:00:00.000000Z",
              "billing": "api-key", "counted": {"claude-code": "turn-end", "goose": "live", "opencode": "live"}, "uncounted": ["codex"]},
    "atOnce": {"max": 2, "running": 1},
    "newTasks": {"max": 10, "period": "hour", "whenReached": "stop", "used": 3, "resetsAt": "2026-11-19T15:12:00.000000Z"}
  }
  ```

  A limit not set is absent. `used` is as it is now, the running turns' cost so far included: read `agneta/access` again for it, since `agneta/accessChanged` arrives when the user changes the limits, not as they're used. `resetsAt` (UTC) is when the period ends; for a rolling hour, when the oldest new task in it leaves it (absent when there's none). `whenReached` is `stop`: the work is refused or stopped (`atOnce` waits).
- **Refused before anything runs:** `-32016`, from `session/new`, `agneta/fork`, `session/prompt` and, for spending, `session/load`:

  ```json
  {"code": -32016, "message": "Example App's limit in Agneta is reached: $5 a day. It resets at midnight.",
   "data": {"agneta": {"appLimit": {"limit": "spend", "max": 5, "used": 5.04, "period": "day",
                                    "resetsAt": "2026-11-20T23:00:00.000000Z", "whenReached": "stop"}}}}
  ```

  `limit` is `spend` or `newTasks`. A prompt that waited in the queue is checked again when its turn comes. Show it as the user's choice, not a failure: what was reached, when it resets, and that they can change it in Agneta. Don't retry before `resetsAt`.
- **Stopped mid-turn by spending:** the prompt's result, as for a policy limit, with `"agneta/limit": {"limit": "appSpend", "setBy": "user", "value": 5, "period": "day", "resetsAt": "…"}` and the stop reason `cancelled`; with `"sessionEnded": true` when the engine didn't stop in time ([Turns](#turns)).
- **Each turn's usage** says where the app stands when a spending limit is set: `agneta/usage` gains `"app": {"spent": 1.23, "max": 5, "period": "day", "resetsAt": "…"}`, with `"unpriced": true` when this turn on an API key called a model its engine had no price for.

## A session

`session/new`:

```json
{
  "cwd": "/Users/me/Documents/Example Project/Workspace",
  "mcpServers": [{"type": "http", "name": "app", "url": "http://127.0.0.1:<port>/mcp",
                  "headers": [{"name": "Authorization", "value": "Bearer <per-session token>"}]}],
  "_meta": {
    "agneta": {"account": "<account id>"},
    "agneta/policy": {"tools": "workspace", "network": "none", "approval": "never-ask",
                        "readable": [], "writable": [], "readOnly": [], "denied": [],
                        "limits": {"maxTurns": 200, "maxSeconds": 1800}},
    "agneta/task": {"title": "Tidying the project notes", "stopWarning": "Example App keeps the work so far"},
    "agneta/instructions": {"text": "You are Example App's assistant…"},
    "agneta/appTools": {"load": "always"},
    "agneta/trace": {"live": true}
  }
}
```

**`cwd`** is the workspace: the folder the agent works in. It must be an absolute path, and the same rules as the policy's folders apply to it.

**`_meta.agneta.account`** chooses the provider, one of `access.providers`. If it's omitted, the first one is used.

**`_meta.agneta.engine`** (optional) chooses the engine, one of that provider's `engines`; without it the session runs on its `defaultEngine`. An engine the provider doesn't support, the app may not use, or this Mac can't run is refused with `-32602` and the current access in `data.agneta.access`. One that downloads first starts downloading, and the session is refused with `-32015` and `data.agneta.engineDownloading {"engine", "received", "total"}` until it's done: show the progress and try again shortly. A loaded or forked session always runs on the engine that saved it. A session that was opening while the app's access changed (in Settings, or by pairing again) is checked against the access as it is then: one that no longer fits is refused with `-32602` and `data.agneta.accessChanged: true`.

**`mcpServers`** are the app's own tools: Streamable HTTP on loopback, with a bearer token.
- Only `type: "http"` with a `127.0.0.1`, `localhost` or `::1` URL is accepted. Anything else is refused with `-32602` and `data.agneta.unenforceable: ["mcpServers"]`: a stdio server would be a command run inside the engine's sandbox, and a remote one a host the policy didn't allow.
- The engine's sandbox may reach exactly those loopback ports (any port under developer access). The exceptions: an app-only session on Goose shares one engine per account, which may reach any loopback port, and OpenCode may reach any loopback port (it runs a private server of its own).
- Your tools run in your app, with your app's own permissions: Agneta's sandbox confines the engine that calls them, not what they do.
- Header values are masked in traces.
- In tool events, the server's `name` comes back as the tool's `extension`, and the tool's own name as `tool`.

### `agneta/policy`

| Field | Values |
| --- | --- |
| `tools` | `app-only`: only the app's MCP tools. `read`: plus the engine's read-only built-ins. `workspace` (the default): plus editing and a shell, confined to the workspace when contained ([Sandbox](#sandbox)) |
| `network` | `none` (the default): shell commands reach nothing but the policy's `toolPorts` and `toolSockets` (not even a name lookup), and the engines' own fetch and web search are refused. It applies to `contained` sessions: under developer access commands reach the internet whatever it says ([Sandbox](#sandbox)). The engine itself can reach any host on port 443, since it needs HTTPS for its provider and macOS's sandbox filters by port, not host name. A list of allowed hosts (`{"allow": [hosts]}`) isn't supported yet and is refused; `{"allow": []}` means `none` |
| `sandbox` | `contained` or `developer` ([Sandbox](#sandbox)): what this session should get, no more than the grant's. Without it, the grant's for `workspace` tools, `contained` for fewer. `developer` needs `workspace` tools. Asking for more than the grant is refused with `-32602`, `unenforceable: ["sandbox"]` and the reason |
| `approval` | `ask-app` (the default): tool permission requests reach the app as `session/request_permission`. `never-ask`: the policy is the permission, and Agneta answers |
| `readable`, `writable`, `readOnly`, `denied` | Absolute paths. `readOnly` stays read-only even inside the workspace; `denied` is neither readable nor writable, even inside allowed folders |
| `toolEnvironment` | Variables for shell commands, which run through Agneta's broker on every engine: your toolchain's `PATH` (each entry an absolute path inside the session's folders, no empty entries; it goes ahead of everything else), `CARGO_HOME`, `PYTHONPATH`, your kit's settings. Your values win over the ones developer access sets. Refused: `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `SHELL`, `BASH_ENV`, `ENV`, `ZDOTDIR`, `PROMPT_COMMAND`, `IFS`, and anything starting `DYLD_`, `LD_`, `AGNETA_`, `CLAUDE_CODE_`, `CODEX_`, `GOOSE_` or `OPENCODE_`. Commands also get the selected Xcode's own tools on `PATH` and `SDKROOT` |
| `toolPorts`, `toolSockets` | Loopback ports and Unix sockets that shell commands may reach (every engine's commands run through Agneta's broker). A socket follows the folder rules: one inside other apps' containers, Agneta's data, `~/.ssh`, LaunchAgents or Keychains is refused. In a `contained` session they are also held to the app ([Tool ports and sockets](#tool-ports-and-sockets)): a socket must be inside a folder the app was granted (its own workspace included) or served by the app itself, and a port served by the app itself, at most 16 beyond its folders. Developer access isn't checked |
| `limits` | `maxTurns`: model calls within one prompt (default 200). `maxSeconds`: a prompt's wall time (default 4 hours). `maxCostUSD`: the task's known cost so far, across resumes (no default) |
| `builtins` | The groups of the engine's own tools the session keeps, the same names on every engine: `read`, `edit`, `execute`, `web`, `subagents`, `skills`, `planning` ([Narrowing the built-in tools](#narrowing-the-built-in-tools)). It only narrows: what `tools`, `sandbox` and `network` don't give stays out whether it's named or not. Without it, everything they give |

- **Nothing is weakened silently.** A policy Agneta can't enforce is refused with `-32602` and `data.agneta.unenforceable: ["<field>"]`. That covers:
  - unknown fields, fields of the wrong type (`"tools": 5`), and malformed or non-positive limits;
  - relative paths, and folders that contain the home folder, other apps' containers, Agneta's own data, `~/Library/LaunchAgents`, `~/Library/Keychains` or `~/.ssh`;
  - a writable folder inside a denied one, or a denied workspace;
  - in a `contained` session, a `toolSockets` entry outside the granted folders, or a `toolPorts` entry, that the app doesn't serve itself ([Tool ports and sockets](#tool-ports-and-sockets));
  - `maxCostUSD` on an engine that doesn't report cost per call (Claude Code, Codex);
  - `builtins` that aren't a list of known groups, or that the session's engine can't honour on its provider ([Narrowing the built-in tools](#narrowing-the-built-in-tools)).
- **Sending no policy** gives `workspace` tools in `cwd`, the grant's sandbox and `ask-app` approval.

#### Narrowing the built-in tools

`tools` and `sandbox` say how far a session reaches; `builtins` says which of the engine's own tools it uses within that. Under developer access an engine brings its whole set (on Claude Code: web fetch and search, subagents, skills, plan mode, and more), which changes what the agent does and how runs compare. An app that wants a fixed set names the groups it keeps:

```json
"agneta/policy": {"tools": "workspace", "sandbox": "developer", "builtins": ["read", "edit", "execute"]}
```

| Group | What it is | Claude Code | Codex | Goose | OpenCode |
| --- | --- | --- | --- | --- | --- |
| `read` | Reading files, listing and searching them (ACP kinds `read`, `search`) | `Read`, `Glob`, `Grep` | Its shell, with `view_image`: needs `execute` | Its shell, with `tree` and `read_image`: needs `execute` | `read`, `glob`, `grep` |
| `edit` | Writing, editing, deleting, moving (`edit`, `delete`, `move`) | `Edit`, `Write`, `NotebookEdit` | `apply_patch` | `write`, `edit` | `edit` (with `write`, `opencode_worktree_remove`) |
| `execute` | Shell commands, and stopping their background jobs (`execute`) | `Bash`, `TaskStop` | Agneta's shell (`mcp__agneta__shell`) | `shell` | `shell` |
| `web` | Fetching pages and searching the web (`fetch`); developer access only | `WebFetch`, `WebSearch` | Web search | None | None |
| `subagents` | Agents the engine starts itself | `Agent`; under developer access also `SendMessage`, `ListAgents`, `Workflow` | Its multi-agent tools | None | None |
| `skills` | Skills and slash commands | `Skill` (developer access) | Its bundled skills | `load_skill`, always (can't be left out) | None (`skill` is listed, with no skill to load) |
| `planning` | Tools that run nothing: to-do lists, plans, goals, questions for the user, waiting | Plan mode and task lists (developer access) | Goals, questions, the clock's sleep | None | None |

- **Only what's named.** With `builtins`, a tool in no group is never offered: on Claude Code under developer access that's its schedules (`CronCreate` and the like, `ScheduleWakeup`), worktrees and `ReportFindings`, and any tool a later version adds. Tool search (`ToolSearch`), which only loads deferred tools, follows [`agneta/appTools`](#agnetaapptools), and Codex's code-mode `exec` and `wait`, which only call the tools above, stay. Without `builtins` nothing changes.
- **Never more.** A group the tools level or sandbox doesn't give stays out: `edit` under `read` tools, `web` in a contained session. `execute` reads whatever its commands can, with or without `read`. `[]` keeps none of the engine's own groups; tool search (Claude Code) stays, and so does what an engine can't turn off, so Goose (skills) and Codex under `workspace` tools (`apply_patch`) refuse it.
- **Refused where it can't be honoured,** with `-32602`, `unenforceable: ["builtins"]` and the reason: Goose on a Claude plan (its model is Claude Code with all its own tools); Goose without `skills` (it always offers `load_skill`); Codex under `workspace` tools without `edit` (no setting turns `apply_patch` off: under `read` tools Codex lists it too, but Agneta refuses each call there, with or without `builtins`, so only `workspace` tools would let it edit); and on Codex and Goose, `read` without `execute` beyond `app-only` tools, since they read files through their shell. A task that names no engine isn't moved to one that can: name the engine (`_meta.agneta.engine`).
- **Kept** with the policy by `session/load` and `agneta/fork`, unless their `_meta` sends another policy.
- **Checked again** on native runners: a permission request for a tool outside the kept groups is refused, under developer access too ([Permissions](#permissions)).
- The result's `_meta.agneta.builtins` lists the groups the session has ([The result](#the-result)), and the trace's `meta` records both.
- An Agneta from before `builtins` refuses it as an unknown field.

### Sandbox

How far an app's tasks reach is the user's choice for that app, its **grant**: they pick it in the approval window and can change it in Settings → Apps. Two modes, the same for every engine:

- **`developer`** (Developer access): full power, as in a terminal, apart from what the table below keeps out: credentials, Agneta's data, and writes outside the session's folders and the app's caches. It's the default for an app with `workspace` tools. Grants made before sandbox modes existed stay contained.
- **`contained`**: the session's folders only, commands with no internet, every command through Agneta's broker.

Three things decide what a task gets, in one place:

1. **The grant's mode is the ceiling.** A session may ask for less (`"sandbox": "contained"` in its policy), never more: an app that asks for `developer` under a `contained` grant is refused, with the reason.
2. **The engine must be able to provide it.** Each engine declares what it can provide on each provider (`sandboxLevels` in the [access report](#access)). Goose on a Claude plan can't contain its tools (its Claude Code uses all its own tools and the claude.ai connectors): it provides `developer` only, and a contained task on it is refused with why. A task that names no engine gets one that can provide its mode, where the app may use one.
3. **Fewer tools stay contained.** Developer access is a terminal's commands, so it applies to `workspace` tools. The approval window offers the choice only to an app that asks for `workspace` tools: an app granted `read` or `app-only` tools stays contained, and an engine that can't contain them is refused. Under a developer grant, a session asking for fewer tools runs contained, except on an engine that can't be.

The reply to `session/new`, `session/load` and `agneta/fork` says what the task really got, in `_meta.agneta.sandbox`. If the user narrows the grant to `contained`, its tasks running with more stop.

Under each mode:

| | `contained` | `developer` |
| --- | --- | --- |
| Commands | Through Agneta's broker: Goose's and OpenCode's shells, Claude Code's Bash (behind its shell prefix), and Codex's through Agneta's MCP shell (`mcp__agneta__shell`, its own shell off) | Through the broker too, with a command sandbox widened like a terminal's (your home as `HOME`, the internet), which keeps the engine's sign-in out |
| Engine's own tools | The policy's tools only, each permission request checked | Claude Code's own tool set (web fetch and search, subagents, skills), apart from those that reach your claude.ai account or devices (artifacts, projects, designs, messages and files sent to the user, notifications, remote triggers) and Monitor and PowerShell, which would run commands outside Agneta's broker; Codex's, with web search. Both still ask before acting, in the `default` and `workspace-write` modes. [`builtins`](#narrowing-the-built-in-tools) narrow it |
| Internet | None for commands | Any host and port. The sites reached aren't listed yet |
| Files read | The workspace and the policy's folders | Also the whole home folder, except credentials and private data (`~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker/config.json`, `~/.netrc`, `~/.git-credentials`, `~/.config/gh`, `~/.npmrc`, `~/.pypirc`, cargo credentials, `~/.claude*`, `~/.codex`, other agents' sign-ins such as Goose's and OpenCode's, shell histories, the Keychains folder, Cookies, Mail, Messages, Safari and other browsers' profiles, other apps' containers and group containers, `~/Library/LaunchAgents`) and all of Agneta's own data: every build's data, caches, logs and preferences, and other apps' workspaces. It's a list: another app's own data that it doesn't name (an unsandboxed app's folder under `~/Library/Application Support`) is readable, as in Terminal |
| Files written | The workspace and `writable` | The same, plus the app's own build caches: one folder per app, kept across its sessions so its builds stay warm. Cargo, pip, uv, npm, yarn, bun, go, gradle, deno, clang, Homebrew and tools that follow `XDG_CACHE_HOME` are pointed there; a tool that keeps its cache in `~/Library/Caches` or `~/.cache` with no variable to move it (SwiftPM, poetry, Playwright and the like) can't write it. Never the user's own caches, where a planted entry would later run as the user, outside any sandbox |
| Toolchains | Only what the policy's folders hold | The user's own: `PATH` has `~/.cargo/bin`, `~/.local/bin`, `~/.volta/bin`, `/opt/homebrew/bin` and the like, with `RUSTUP_HOME` set (your `~/.cargo/config.toml` isn't read: the app's cargo folder is its own). The toolchains are read-only: a project that pins a toolchain you haven't installed can't install it |
| Loopback and sockets | `toolPorts` the app serves itself, and `toolSockets` it serves itself or that are inside its granted folders ([Tool ports and sockets](#tool-ports-and-sockets)) | Any port (every local server, as in a terminal), and commands may listen on loopback; `toolSockets` as listed |
| Still never | | Credentials, opening apps or Apple Events, the user's own Claude Code settings, skills, hooks and MCP servers, writes outside the session's folders and the app's caches |

Something the agent reads could try to get it to send files online, exactly as with an approved command in a terminal: ask for `contained` where your app doesn't need more, and tell your users what developer access means. Every tool call is still in the task's trace.

In both modes, a command's background jobs live on after it returns, as in a terminal, and end with its engine. Nothing outlives Agneta, except as below.

Known limits, each the same as in a terminal:
- **Loopback reaches every local server** under developer access, not only your app's.
- **A command can leave the job list,** in both modes. Agneta ends a command's process group with its engine; one that starts a session or group of its own (`setsid`, `set -m`, a detached child) can outlive it, and Agneta. The sandbox can't refuse it without breaking ordinary tools (measured: a refused `setsid` is still reached through `posix_spawn`).
- **Other processes' environments are readable,** in both modes. macOS lets any process of the user's, sandboxed or not, read the environment of another one that isn't Apple's own (measured: no sandbox rule stops it). So a command can read what the user's own programs were started with, and the provider key of an engine on an API-key account. Plan sign-ins are in the Keychain, and Agneta's broker tokens are in files, so neither is exposed.

**Changing the engine's mode** (`session/set_mode`, or `session/set_config_option` with `configId: "mode"`) is refused where the mode would leave what Agneta set up: on Claude Code and Codex, a mode that stops the engine asking permission, since Agneta checks each tool call from those questions; on OpenCode, any agent but Agneta's, which carries the session's instructions.

#### Tool ports and sockets

A Unix socket or a loopback port reaches whatever serves it: Docker's socket can start a container that mounts the user's home, and a local service's port does what that service does. So in a `contained` session (as the task really runs: `_meta.agneta.sandbox` is `contained`) the policy's `toolSockets` and `toolPorts` are held to what the user granted the app:

- **A socket inside a folder the app was granted** (the folders the approval window showed, and the app's own workspace) is allowed, whoever serves it. Paths are compared as real paths, and the sandbox names the socket as it was checked: a link put in its place later, pointing at another socket, reaches neither (measured, and tested).
- **Any other socket, and every port, must be served by the app itself,** at most 16 of them together (more is refused with `-32602`). Agneta connects to each, as a command would, and asks the kernel whom it reached:
  - a socket: its listener, with the kernel's audit token for the connection;
  - a port, on `127.0.0.1` and on `::1`: the process that accepts Agneta's connection, or, when it doesn't accept within a moment (a busy server, or one that closes at once), the process holding the listening socket of that address's own family for that address or its wildcard. That is the kernel's record of the port, and within one family another user can't bind there beside it. Across families anyone can (beside another user's `0.0.0.0` listener, `[::]` is free), so an IPv6 listener never answers for `127.0.0.1`: a dual-stack server listening only on `[::]` must accept Agneta's IPv4 connection to count, or listen on `127.0.0.1` too.

  That process must be the app, and so must every process Agneta finds bound there:
  - for a verified app, any process with a valid Apple-issued signature from the app's team. Its helpers and XPC services count, and so do **the same developer's other apps**;
  - for an app Agneta can't verify, the process holding its connection to Agneta, or **any process it started** (a child, at any depth).
- **Refused** when nothing accepts the connection, when what answers can't be identified, or when it's another program. Can't be identified means: a server run by root or another user, a datagram socket, a socket path of 104 bytes or more, and a server launchd started on demand (socket activation: the kernel names launchd, not your app). Processes are compared as instances (a pid with its start time, or the audit token), so a pid reused by another program is never taken for the app.
- **Start your server before you open the session.** Agneta's connection sends nothing and closes at once; keep an accepted connection open until the client closes it, as most servers do.

The probes run off Agneta's router, on a fixed set of Agneta's own threads, all of a session's at once, each given 3 s from when it starts (waiting for a thread isn't counted against your server). An app's session opens run one check at a time, so an app opening many sessions at once queues behind itself. The checks before each command and while jobs run share the same threads with every app's, first come first served: an app with many contained sessions naming slow servers can delay other apps' commands (never fail them: the 3 s count only starts when a probe does). Fair queueing between apps is planned.

A session that names one it can't allow is refused when it opens (or is loaded or forked) with `-32602`, `data.agneta.unenforceable: ["toolSockets"]` or `["toolPorts"]`, and a reason naming the socket or port, for example:

```json
{"code": -32602, "message": "Agneta can't enforce toolPorts: loopback port 8125 isn't served by Example's own process or one it started: a contained task reaches only its app's own ports; developer access allows it",
 "data": {"agneta": {"unenforceable": ["toolPorts"], "reason": "loopback port 8125 isn't served by …"}}}
```

**Checked again while the session runs:**
- before each command, and about every second while any of its commands or background jobs (`… &`, which outlive the command that started them) run. Each check takes about 11 ms for one port and one socket, with one connection to each socket and two to each port (`127.0.0.1` and `::1`), so a contained session with something running costs about that every second;
- one that found nothing, or no answer in time, is tried again half a second later, so a server that was only slow isn't taken for gone. One that another program answers fails at once;
- if the app still doesn't serve it, the command is refused, every command and background job of the session is stopped, and the session stops. The app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "reach", "reason"}`, the reason naming the socket or port and what was found: nothing listening, another program, or a server that didn't answer in time.

A narrowed grant stops a session that no longer fits, too. What's left: if your server stops and another program takes its port or socket path, a command or job of the session can reach that program until a check stops the session: about 1.5 s when the program that took its place answers quickly, about 3.5 s when it's slow to answer (the probe waits for it, then tries again), and longer while Agneta is busy with many checks. Keep your server running while its sessions are open. Closing that gap completely needs Agneta to serve the only socket a session may reach and pass connections on to your server once the kernel says it's yours. That's future work.

The app's own MCP servers (`mcpServers`, which the engine calls) aren't affected by any of this.

### `agneta/appTools`

How the engine offers your MCP tools to the model. `{"load": "always"}` puts every one of them, with its description and schema, in the model's context from the first request, on every engine: ask for it when your tools are central to the task and their descriptions carry the instructions for it. `{"load": "engine"}`, or leaving it out, keeps each engine's own behaviour ([ENGINES.md](ENGINES.md)):

| Engine | `engine` (the default) | `always` |
| --- | --- | --- |
| Claude Code | Deferred behind its tool search: the model sees only your tools' names, and loads each with `ToolSearch` before its first call | Up front: tool search is off for the session, and `ToolSearch` isn't offered |
| Goose on a Claude plan (its model is Claude Code) | Deferred, as on Claude Code | Up front: tool search is off for the session's Claude Code |
| Codex | Deferred behind its tool search, on every model it lists: the model sees only your servers' names | Up front: your servers are named as namespaces that bypass deferral |
| OpenCode, Goose on an API key | Up front | Up front (nothing changes) |

- Tools up front take context on every request, about as much as their descriptions and schemas; that's what deferral saves.
- Anything else (another `load`, another field, a value that isn't an object) is refused with `-32602` and `data.agneta.unenforceable: ["agneta/appTools"]`.
- `session/load` and `agneta/fork` keep the original's unless their `_meta` sets it. An explicit `null` (or `{}`) means `engine`, there as on `session/new`.
- The result says what the session got, in `_meta.agneta.appTools` ([The result](#the-result)).

### Instructions

`agneta/instructions.text`, or ACP's `systemPrompt`, sets the session's instructions. Goose, OpenCode and Claude Code use them as the system prompt; Codex appends them to its own instructions, which say how to use its tools ([ENGINES.md](ENGINES.md)).

### The result

- `sessionId`: Agneta's id, never the engine's.
- `_meta.agneta`: `account`, `dedicatedEngine` (whether the session has an engine process of its own), `sandbox` (the mode the task really got, [Sandbox](#sandbox)), `appTools` (`{"load", "upfront"}`: the [`agneta/appTools`](#agnetaapptools) it runs with, and whether your tools are in the model's first request on this engine, `null` if Agneta doesn't know), `builtins` (the groups of the engine's own tools the session has, as its engine is configured, with `builtins` applied: for example `["read", "edit", "execute", "subagents"]` on a contained Claude Code session; `null` where Agneta doesn't know, Goose on a Claude plan), and `capabilities`:

| Field | Meaning |
| --- | --- |
| `engine` | `goose`, `opencode`, `claude-code` or `codex` |
| `steer` | `agneta/steer` works |
| `fork` | `agneta/fork` works |
| `instructionsBetweenTurns` | `agneta/instructions/set` works |
| `reportsCost` | Per-call cost is known while the turn runs, so `maxCostUSD` can be enforced |

- `_meta.agneta.results`, for a session that declared [structured results](#structured-results): `{"declared": [names], "every": name or null, "mechanism": "tool"}`.
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

A session's settings are the engine's own ACP config options, in `session/new`'s result (`configOptions`), each with its choices and current value. Find them by their standard category rather than an engine's own ids, which differ:

| Category | What | Seen |
| --- | --- | --- |
| `model` | The model (every engine also uses the id `model`) | Codex, Claude Code, Goose, OpenCode. Goose on a Claude plan offers one: Claude Code's own, `current` |
| `thought_level` | Reasoning effort (ids differ: `reasoning_effort` on Codex, `effort` on Claude Code, `thinking_effort` on Goose) | Codex, Claude Code, Goose on a Claude plan; Goose and OpenCode with an API key for models that have it |

- Change one with `session/set_config_option {"sessionId", "configId", "value"}`, before the first prompt or between turns. The answer is the options as they are now: another model may offer other efforts, or none.
- To let people choose before they type, open the session first (it starts the engine but calls no model). Choices may come in groups; a current value may be missing from the choices (Goose reports its configured model without always listing it).
- **The user's defaults come first.** Where the user chose a default model or effort for the provider (Settings → Providers → Model and Effort), a new session already has it: `configOptions` in the result shows it as current. A loaded or forked session keeps what it had. The app can still set its own.
- Changing provider or engine means a new session.

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
 "_meta": {"agneta/usage": {"modelCalls": 2, "models": ["gpt-x"], "inputTokens": 84, "outputTokens": 14,
                              "cacheReadTokens": 0, "cacheWriteTokens": 0, "cost": null, "costKind": "estimated",
                              "taskCost": null, "billing": "api-key", "account": "…", "ms": 196.4, "msToFirstToken": 147.1,
                              "basis": "engine-ledger"},
           "agneta/limit": {"limit": "maxSeconds", "value": 1800}}}
```

- **`agneta/usage`** comes from the engine's own records, one entry per model call, summed over the turn. Nothing is counted from stream items.
  - `basis` says where the numbers come from: `engine-ledger` (the per-call records) or `engine-turn-totals` (the engine's own totals for the turn, which Claude Code needs; see [ENGINES.md](ENGINES.md#claude-code)).
  - `costKind` is `estimated` for API keys, and `plan-equivalent` for subscriptions, where the plan pays and nothing is charged per call.
  - `app`: where the app stands against the spending limit the user set for it, when there is one, and `unpriced` when this turn's models had no price ([Limits the user sets](#limits-the-user-sets)).
  - Unknown values are `null`, never guessed.
  - `usage` is the engine's own figure for the turn, passed through.
- **`agneta/limit`** appears only when a limit stopped the turn: one of the policy's (`"setBy": "app"`), or the spending limit the user set for the app (`"limit": "appSpend"`, `"setBy": "user"`, with its `period` and `resetsAt`; [Limits the user sets](#limits-the-user-sets)). A turn past both reports its policy's. `maxTurns` ends with ACP's `max_turn_requests`; time and cost end as `cancelled`, with this field saying why. Limits are checked twice a second. A limit is a hard limit: if the engine hasn't stopped the turn 10 s after Agneta cancels it (stuck in a tool, or ignoring the cancel), Agneta ends the session (which stops its engine), sends `agneta/sessionStopped` with `stoppedBy: "limit"`, and answers the prompt the same way with `"sessionEnded": true` in this field. Load the session again to go on.
- **One turn at a time per session.** A prompt while one runs is refused with `-32011`. To add to a running turn, steer it.

| Method | Effect |
| --- | --- |
| `agneta/steer {"sessionId", "prompt": [blocks]}` | Adds input to the running turn. Returns `{"delivery": "accepted", "runId"}`. Error `-32010` when no turn is running, or it ended before the input arrived. On Claude Code a turn's end can take up to a second after its last answer, while Agneta reads that call's final usage from the session transcript: a steer then gets `-32010`, and the input goes in as the next prompt |
| `agneta/instructions/set {"sessionId", "text", "mode": "replace" \| "append", "key"?}` | `replace` (the default) sets the instructions; `append` adds a named part (`key`, default `app`) that a later append with the same key replaces |
| `session/cancel` (notification) | Ends the running turn with `cancelled` |
| `session/close` | Ends the session and, if it has one of its own, its engine |

**Waiting for room.** At most 8 turns run at once, at most 3 per account, and no more of an app's than the user's `atOnce` limit for it; up to 32 more wait. A turn waits only behind earlier turns that want the same room (on the same account, unless that one waits for its own app's limit; or of the same app, when that one waits for the app's limit), so a busy account, or an app at its own limit, never holds up another. A waiting turn's app gets `agneta/queued {"sessionId", "position", "waitingFor"}`, where `waitingFor` is `app` (its own `atOnce` limit: say "waiting for your limit of tasks at once"), `account` or `agneta`, and the prompt simply returns later. `session/cancel` takes a waiting turn out at once (`cancelled`). A prompt when the queue is full fails with `-32012`.

**Resuming.** `session/load {"sessionId", "cwd", "mcpServers", "_meta"?}` reopens one of the app's earlier tasks after a close or an Agneta restart, within the history retention.
- Pass the tool servers again, since their bearers are per session. The policy, instructions and `agneta/appTools` default to the original ones; `_meta` may set new ones, and ask for live trace delivery.
- The engine returns to the same engine home and replays the conversation as `session/update`s before the result. The next turn sees the whole history, and the trace continues with the next sequence numbers.
- The result's `_meta.agneta.resumed` is true.
- It passes the same checks as `session/new`: the provider (granted, not paused), the engine (still allowed), the policy against the grant, the tool servers and the cost limit.
- Loading a session that's already open, or another app's, fails with `-32602`. A task that ran without built-in tools must be resumed without them.
- A task resumes only on the engine that saved it, whatever the provider's default is now. If the app may no longer use that engine, or it isn't on this Mac any more, loading fails with `-32602` and the current access in `data.agneta.access`; if it stores sessions differently now, with `data.agneta.stateChanged {"engine", "saved", "current"}`. Start a new task instead.
- Its cost goes on from where it was, so `maxCostUSD` counts the whole task, and so do the trace's turn and model-call numbers.
- Instructions appended with `agneta/instructions/set` aren't restored. Set them again after loading.

**Forking.** `agneta/fork {"sessionId", "mcpServers", "cwd"?, "_meta"?}` starts a new task with a copy of one of the app's tasks, open or finished: for example, to ask about a run without changing it.
- The new task has its own id, engine and trace. Its result's `_meta.agneta.forkOf` names the source. Prompts to it never touch the original.
- Its policy is `_meta`'s if given; otherwise it's the original's with `tools: "read"`.
- It keeps the original's instructions unless `_meta["agneta/instructions"]` sets new ones, and its `agneta/appTools` unless `_meta` sets that.
- It passes the same checks as `session/new`, and like a load it needs the engine that saved the original. Its cost starts from zero: it's a task of its own.

**Pause.** The user can pause an account in Agneta's menu. Then nothing new starts on it: `session/new`, `session/load`, `agneta/fork` and `session/prompt` fail with `-32013` and `data.agneta.paused`, and so does a prompt that was waiting in the queue. A turn already running finishes. Open sessions stay open and take turns again once the user resumes the account.

**Provider limits.** The engine first retries a provider's 429 itself. If the limit holds, the turn fails with the engine's error, and Agneta adds `data.agneta.rateLimited {"account", "message", "resetsAt"}`. It also sends `agneta/rateLimited` with the same fields and the `sessionId`, and Agneta's menu marks the account. `resetsAt` (UTC) is read from the provider's own words, such as "try again in 20s" or "resets 3pm", and is null when they give none. Retry after it, or use another account.

**Signed out.** When the engine says the account isn't signed in, the error keeps the engine's code (usually `-32000`, ACP's `auth_required`) and gains `data.agneta.needsSignIn: "<account id>"`. Agneta's menu asks the user to sign in again; tell the user to open Agneta.

**Stopped by the user.** Someone may press Stop in Agneta's menu. The app then gets `agneta/sessionStopped {"sessionId", "stoppedBy": "user"}`, and the running turn ends as cancelled. Show it as stopped by the user, not as an error.

**Stopped for its sockets or ports.** A contained session whose socket or port the app no longer serves stops before its next command runs ([Tool ports and sockets](#tool-ports-and-sockets)): the app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "reach", "reason"}`, and the running turn ends as cancelled. Serve it again and open a new session or load this one.

**Engine stopped.** If the engine process ends on its own (it crashed, or was killed), its sessions end at once: the app gets `agneta/sessionStopped {"sessionId", "stoppedBy": "engine"}` and a running turn fails. Resume the task with `session/load`, which starts a fresh engine.

**Agneta quits.** The connection closes, with no `agneta/sessionStopped`: the app's sessions end with it, and their running turns fail. Connect again once Agneta is back, and resume a task with `session/load`.

## Structured results

A turn can return a value that matches a JSON Schema the app gives, checked by Agneta, the same on every engine: an invoice from a PDF, a form filled in from a conversation, a typed answer. The model returns it by calling a tool Agneta serves; Agneta validates every call and answers the model with what's wrong, so it can correct the value within the turn; the prompt's reply carries the result, or why there is none.

### Declaring results

Schemas are declared when a session opens (`session/new`, `session/load`, `agneta/fork`), because engines take their tools only then:

```json
"_meta": {"agneta/result": {
  "schemas": {
    "invoice": {"type": "object", "properties": {"number": {"type": "string"}, "total": {"type": "number"}},
                "required": ["number", "total"], "additionalProperties": false},
    "contact": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}
  },
  "every": "invoice"
}}
```

- **`schemas`**: each named schema becomes a tool the model calls with the value as its arguments. Names are lowercase letters, digits and single underscores, starting with a letter, at most 32 characters; `any` is reserved.
- **`every`** (optional): the schema every prompt asks for unless it opts out.
- **The shorthand** `{"schema": {…}}` declares one schema named `result`, asked for on every prompt: a one-shot extraction.
- **Limits:** at most 8 schemas, 32 KB together; each at most 16 KB. They're in the model's tool list on every call.
- `session/load` and `agneta/fork` keep the original's declaration unless their `_meta` sets one.
- The reply says what the session can ask for, in `_meta.agneta.results` ([The result](#the-result)).
- Anything that doesn't fit (a bad name, an unknown field, a schema outside the subset below) is refused before an engine starts, with `-32602` and `data.agneta.unenforceable: ["agneta/result"]`, `data.agneta.reason` naming what and where.

### Asking for a result

`session/prompt` takes `_meta["agneta/result"]`:

- `{"name": "contact"}`, with optionally `"attempts"`: how many calls of the result tools the model gets this turn, 1 to 10, default 3. Every call counts, a valid one and one of the wrong result's tool included.
- `false`: no result this turn, in a session with `every`.
- Nothing: the session's `every`, if it has one; otherwise an ordinary turn.

Agneta adds a short note to the prompt saying which tool to call. A schema a session didn't declare can't be asked for in a prompt (`-32602`); declare it when the session opens.

### The reply

The prompt's reply gains `_meta["agneta/result"]`:

```json
{"stopReason": "end_turn",
 "_meta": {"agneta/result": {"status": "valid", "name": "invoice", "mechanism": "tool", "attempts": 1,
                             "value": {"number": "A-1042", "total": 129.5}},
           "agneta/usage": {…}}}
```

| `status` | Meaning |
| --- | --- |
| `valid` | `value` matches the schema. The first valid value is final: a later call can't replace it |
| `invalid` | The model's values didn't match, and the turn ended or its attempts ran out: `value` and `issues` are the last refused value's |
| `missing` | No value: `reason` says why, and when a value was refused before, `value` and `issues` are the last one's |

- **`reason`** (with `missing`): `stopped` (cancelled, Stop, a limit, or the turn was cancelled while queued), `refused` (the model refused), `truncated` (it ran out of output tokens), `not-submitted` (it ended without calling the tool).
- **`issues`**: each `{"path", "keyword", "message", "schemaPath"}`, `path` a JSON Pointer into the value. At most 20.
- **`valueOmitted`**: a refused value nested too deeply to carry back is left out and said so.
- **`attempts`**: the calls of the session's result tools in the turn.
- A missing or invalid result is still a successful reply: the turn ran and has usage. Errors keep their meaning; if the engine fails after a value was accepted, the error's `data["agneta/result"]` carries it.
- While the turn runs, the result tool's calls arrive as ordinary `tool_call` updates, tagged `update._meta.agneta.result: {"name"}`, so an app can show or hide them.
- Agneta answers the result tool's permission requests itself (it runs nothing), whatever `approval` says.

### What a schema may say

JSON Schema 2020-12, in a subset every engine can honour. Anything outside it is refused, naming the keyword and where it is, never quietly ignored, so a value Agneta calls valid is valid against the whole schema.

- **Supported:** `type` (a name or a list, `null` included), `properties`, `required`, `additionalProperties`, `patternProperties`, `propertyNames`, `minProperties`, `maxProperties`, `items`, `prefixItems`, `minItems`, `maxItems`, `uniqueItems`, `enum`, `const`, `allOf`, `anyOf`, `oneOf`, `not`, `$ref` to a schema within this one (`#`, `#/$defs/…`, any JSON Pointer), `$defs`, `definitions`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`.
- **Accepted, not enforced:** `title`, `description`, `default`, `examples`, `format`, `$comment`, `deprecated`, `readOnly`, `writeOnly`, `$schema` (2020-12 or draft-07, read with 2020-12's meaning), `$id` at the root.
- **Refused:** references to other documents, `$dynamicRef`, `$anchor`, `if`/`then`/`else`, `dependentSchemas`, `dependentRequired`, `contains`, `unevaluated*`, content keywords, keywords beside `$ref` (put them in `allOf`), and any keyword Agneta doesn't know.
- **The root** must be `"type": "object"`.
- **Patterns** are ECMA-262: `$` is the end of the value (never before a final newline), and `\d`, `\w` and `\b` are ASCII. Syntax other engines have but ECMA-262 doesn't (inline flags, possessive quantifiers, `\A`, `\z`) is refused.
- **Equality** is JSON's: `1` and `1.0` are equal, strings compare by code point, and `multipleOf` is exact.
- **Bounds:** a value nested more than 64 levels, or one that would take too long to check (a pattern that backtracks without end, a huge value against a schema of many choices), is refused as `limit`. A schema whose `anyOf`, `oneOf`, `allOf`, `not` and `$ref` choices add up to more than 1,000 checks for one value is refused when declared.

### Engines

The value reaches Agneta through an MCP tool on every engine, and Agneta checks it the same way. How an engine handles a call before it reaches Agneta differs, measured on the pinned versions ([ENGINES.md](ENGINES.md)):

- **Goose** passes every call on: the model reads Agneta's issues.
- **OpenCode** checks the arguments against the tool's schema itself and refuses a call that doesn't fit before it reaches Agneta; the model reads OpenCode's message, and if it never sends a valid value the reply is `missing` with `not-submitted`.
- Engines may show the model less of a schema than they're given; Agneta's issues quote the part a value broke.

### What to trust

- **Valid isn't true.** A valid value matches the schema; whether it's right about the source is the model's work. Text in a document the model reads can steer what it submits: treat the value as untrusted input.
- **Schemas go to the provider** with every model call, and providers may cache them: keep user data out of them.
- **A subagent of the engine's** can call the result tool too: it's the session's.

## Permissions

With `approval: "ask-app"`, the engine's `session/request_permission` requests reach the app with Agneta's session id. Agneta applies two rules:
- **"Always" becomes "once".** An engine may keep an "always" answer beyond the session (OpenCode keeps it for the whole project), so Agneta answers with the matching "once" option. Where the engine offers no "once" option, the call is declined.
- **Native runners are checked first.** Claude Code and Codex run their own tools, so Agneta answers each request for a built-in tool by its contract with every engine (`BuiltinTools`), before the app is asked: nothing built in under `app-only`; reading and searching (`read`, `search`) under `read`; also editing (`edit`, `delete`, `move`) under `workspace`; and never `fetch` while the network is `none`, nor `execute` apart from Claude Code's Bash, whose commands run through Agneta's broker. Under developer access the request goes to the app (or the policy answers) whatever its kind, except that a policy with `builtins` refuses first a tool outside the kept groups. A kind that says what the tool does (`read`, `search`, `edit`, `delete`, `move`, `execute`, `fetch`) must be in a kept group, and so must the tool's name where Agneta knows it, so a name never widens a kind; `other`, `think` and `switch_mode` (claude-agent-acp reports Agent as `think`) need a known name in a kept group, or tool search (which claude-agent-acp reports as `other`). Names come only from the fields an adapter vouches for, never a command's title. Kinds that run nothing of their own (`think`, `switch_mode`) pass. `other` passes only for a tool known by name to run nothing (finding deferred tools, a to-do list, a question, plan mode): adapters report every tool without a reporter of their own as `other`, Claude Code's Monitor (which runs commands) among them. A request with no kind, or one ACP doesn't define, is refused, since Agneta can't tell what it would run.
- **Claude Code offers only the tools the policy names.** Agneta passes the exact built-in set (`tools`): none but tool search under `app-only` (and no tool search when [`agneta/appTools`](#agnetaapptools) is `always`); `Read`, `Glob`, `Grep` under `read`; also `Edit`, `Write`, `NotebookEdit` under `workspace`; plus `Bash` (with `TaskStop` and `Agent`) whenever tools go beyond `app-only`, its commands run through Agneta's broker by Claude Code's shell prefix, never inside the engine's sandbox; Claude Code's own set under developer access, without the tools that reach the claude.ai account or devices, and Monitor and PowerShell. With [`builtins`](#narrowing-the-built-in-tools), the kept groups' tools only, contained and under developer access alike. Every session, a resumed one included, is set to the `default` mode, which asks (the adapter starts in `auto`, which doesn't), and gets the same options on resume.
- **The app's own tools are the app's.** A request for a tool of one of the app's MCP servers isn't refused by that contract (Codex asks for those as `execute`). Agneta trusts only what the engine's adapter vouches for: Codex's own MCP approval marker, Claude Code's tool names. A server can't take a name an engine uses for its own tools (Claude Code's `workspace` and `acp`; Codex's `codex_apps` and `agneta`, its shell): `session/new` refuses it with `-32602` and `unenforceable: ["mcpServers"]`.

Every decision is in the trace's `permission` records: who decided (`asked-app`, `allowed-by-policy`, `refused-by-policy`), the answer, and how long it took.

## The trace

Agneta writes a full trace of every task ([DIAGNOSTICS.md](DIAGNOSTICS.md), format `agneta/trace`). An app can read its own tasks, and only those.

- **Live:** with `"agneta/trace": {"live": true}` on `session/new` (or `session/load`), records arrive as `agneta/trace {"sessionId", "records": [...]}` notifications. They come in sequence order, batched every 100 ms in groups of up to 64, from `meta` to `end`. An app that reads too slowly to keep up (10,000 records waiting) gets one last `agneta/trace {"sessionId", "records": [], "overflow": {"after": <seq>}}`, and live delivery for that task stops; read on from `after` with `agneta/trace/read`. `"include": ["acp"]` adds the raw JSON-RPC frames of both connections.
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
| `-32015` | What the engine needs is still downloading (`data.agneta.engineDownloading`: `engine`, `received`, `total` bytes); try again shortly |
| `-32016` | The limit you set for this app in Agneta is reached (`data.agneta.appLimit`: `limit`, `max`, `used`, `period`, `resetsAt`, `whenReached`); show it as the user's choice, with when it resets ([Limits the user sets](#limits-the-user-sets)) |
| `-32601` | Not a method Agneta offers; engines' own methods aren't reachable |
| `-32602` | Invalid parameters. For a policy, server list, mode or `agneta/result`, `data.agneta.unenforceable` names the field. "Unknown session" also uses it: another app's session, or an ended one |
| `-32603` | Agneta couldn't do it: the engine didn't start (no answer within 60 s) or stopped, or the app disconnected meanwhile |
