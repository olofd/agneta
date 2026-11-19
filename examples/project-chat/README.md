# Project Chat

Project Chat is a small Electron app that runs an agent through Agneta, on the official [TypeScript client](../../clients/typescript/README.md), `@agneta/client`. The agent can read the fictional Field Notes project brief and propose a release note. The proposal appears in Project Chat for a person to save or dismiss.

![Project Chat on a ChatGPT plan with Codex: streamed replies, project tool calls, a release note awaiting review, and the provider, engine, model and effort pickers](preview.png)

## Run it

Project Chat helps you get Agneta if it isn't installed yet; a recent [Agneta build](../../README.md#build-and-run) works too. For the tested setup, connect a provider (a plan or an API key) in Agneta. Project Chat offers the engines that provider can run on and picks its default; any of them works. See [which engines work with each provider](../../README.md#providers-and-engines). From the repository root, build the [client library](../../clients/typescript/README.md) Project Chat uses, then run the example with Node.js 24 or newer.

```sh
(cd clients/typescript && npm ci && npm run build)
cd examples/project-chat
npm ci
npm start
```

To open it from Finder or the Dock like any app, run `npm run bundle` once and open `build/Project Chat.app` (keep that in the Dock, not the Electron icon `npm start` shows, which opens bare Electron once Project Chat has quit). Closing its window leaves it running; its Dock icon opens it again.

Project Chat opens its session as soon as it's connected, so the **Model** and **Effort** pickers show the engine's own choices before the first message (found by their ACP categories, `model` and `thought_level`; each shown only where there's a choice). Changing either applies between turns and carries over to the next chat.

**Getting Agneta.** When Agneta isn't installed, a panel above the message box offers **Get Agneta**: it opens [the install page](https://agneta.dahlbom.io/get/) (the right download first, with the steps and Homebrew; the panel shows the Homebrew line too, with **Copy**), waits while you install, and opens Agneta once it's in Applications. When it's only on its disk image, the panel says to drag it into Applications. When it's installed but not running, the panel asks whether to open it (**Open Agneta** or **Open Agneta Dev**), and says so if macOS is asking whether to open it. Then it asks to show Agneta's window for connecting your AI if none is connected, and pairs. Each question is yours to answer, and **Cancel** ends the wait. At launch it asks nothing, except to offer opening Agneta when you've used Project Chat before (its access is kept). For Agneta Dev, **Get Agneta Dev** points to building it from source.

**Which Agneta.** While disconnected, the **Use** menu beside Connect picks the release (**Agneta**, port `47321`) or a development build (**Agneta Dev**, port `47331`). The choice is remembered; on the first launch Project Chat uses the one that's running, the release when both or neither are. Each keeps its own access: the token from Always Allow is stored per port. For an [isolated dev instance](../../README.md#build-and-run), give its port instead, for example `AGNETA_PORT=47341 npm start` (or `AGNETA_PORT=47341 npm run bundle`, which the bundle keeps); the menu is then hidden.

### Try the workflow

1. Click **Connect to Agneta** (or **Connect to Agneta Dev**). If Agneta has no AI connected yet, Project Chat first asks it to show its window for connecting one, and pairs once you have. Compare the pairing codes if they appear, tick a provider in Agneta, and choose **Always Allow** (it reconnects by itself next time) or **Allow Once**. Project Chat requests app-only tools and no folders, so its tasks always run contained and the window offers no mode. Pairing itself makes no model calls.
2. Click **What’s ready to announce?**, then **Send**. A **Read the project brief** tool event should appear. The reply should mention offline search and PDF export, with shared folders still in testing.
3. Click **Draft a release announcement**, then **Send**. Check the **Proposed note** in the sidebar and choose **Save note** or **Dismiss**. The tool can stage text, and only the app’s **Save note** action puts it in **Saved notes**.
4. Open Agneta’s menu and find **Field Notes · Project Chat**. Use **Stop** in Project Chat to cancel a turn, or **Stop** in Agneta to end the session. **New chat** closes the session and clears the transcript and any unreviewed proposal. Saved demo notes stay in the app until it quits.

The model chooses if and when to call a tool. If you get a draft in the conversation only, ask the agent to use `propose_note`. Sending a message can use plan allowance or API credit. The provider receives the prompt and tool results. Project Chat keeps the conversation and notes in memory. Agneta keeps task traces according to [its privacy and retention settings](../../docs/PRIVACY.md). A trace can include a proposal even when you dismiss it.

## Follow the integration

```text
Renderer ── fixed IPC actions ──► Electron main ── ACP WebSocket ──► Agneta ──► engine
                                        ▲                                        │
                                        └───── MCP over loopback with bearer ────┘
```

1. [**Pair, or connect with a kept token**](chat.mjs). Project Chat talks to Agneta through [`@agneta/client`](../../clients/typescript/README.md), which does the protocol's work: `client.connect({ pair: quiet ? 'never' : 'if-needed', setup: true, guide, onProgress, signal })`, with [`electronEnvironment({ app, shell })`](main.mjs) to find and open Agneta. The `guide` puts each question in the window's panel and resolves with the answer; `onProgress` shows each step there ([Getting Agneta](../../clients/typescript/README.md#getting-agneta)). With a token kept from an earlier **Always Allow**, it passes it to `initialize` and connects without asking; at launch Project Chat does this by itself. Otherwise it calls `agneta/catalog` first: with nothing connected, it calls `agneta/setup` and waits for `agneta/catalogChanged`. Then it sends `agneta/pair` with an app-only scope, keeps the token when the answer says `remembered` ([encrypted with Electron's `safeStorage`](main.mjs) by `safeStorageTokenStore`, whose key is in the login Keychain, one file per Agneta), and initializes with it. When Agneta no longer accepts the token (access removed in Settings → Apps), it forgets it and Project Chat says so; **Connect** then asks again. It reads what it may use and its workspace from Agneta's access report. The token never leaves the main process.
2. [**Register app tools**](project-tools.mjs). On the first message, the app starts a stateless MCP server bound to `127.0.0.1` on an OS-assigned port. It registers that endpoint and a fresh bearer in `session/new`, alongside an app-only policy with per-turn limits. The server exposes only `read_project_brief` and `propose_note`. Saving is a UI action, outside the tool interface. The same pattern works for proposed document edits or generated artifacts.
3. [**Prompt and close**](chat.mjs). `session.prompt(text)` sends `session/prompt`; Project Chat renders the reply as it streams (`turn.textStream()`, the `agent_message_chunk` text) and shows usage reported by Agneta. `session.cancel()` sends `session/cancel` to stop a turn and `session.close()` sends `session/close` when starting a new chat. The MCP listener closes with the session.
4. [**Keep the renderer’s access narrow**](main.mjs). Agneta refuses browser WebSocket upgrades, so ACP runs in the Node main process. The [preload bridge](preload.cjs) exposes specific UI actions. Pairing and MCP credentials stay out of it.

See [Agneta’s app protocol](../../docs/APP_PROTOCOL.md) for the complete wire contract. If the example cannot connect, check that Agneta is running and that the **Use** menu names the Agneta that's running. If Agneta asks you to sign in again or resume a paused account, do so there before retrying the message. If it says a limit you set for Project Chat in Agneta is reached, the message says when it resets; you can change the limit in Agneta's Settings → Apps.

## Check it without an account

`npm test` checks tool authentication and the draft contract using only a local server, and the panel's questions and steps with a scripted Mac and a stand-in Agneta. The integration check runs the example client against real Goose and a fake provider. It starts its own headless Agneta and fake provider (`agneta-fakes`), uses temporary storage, and leaves your running Agneta alone. From the repository root:

```sh
scripts/fetch-engines
swift build --product agnetad
swift build --product agneta-fakes
(cd clients/typescript && npm ci && npm run build)
cd examples/project-chat
npm ci
npm run test:integration
```

The integration check covers pairing, brief retrieval, streamed replies, draft save and dismissal, Stop, New chat, and Disconnect.
