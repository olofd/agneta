# Follow-ups

Changes the maintainer asked for after 0.1.0, collected as they come in and worked through in order. Each item keeps the request in the maintainer's words, then what was done and where it stands. When an item ships, it moves to the changelog and its line here says which version.

| # | Request | Status |
| --- | --- | --- |
| 1 | The menu bar panel is too transparent | Done; checked in the running app (2026-11-18) |
| 2 | Settings: scrolled content runs into the window title | Done; checked in the running app (2026-11-18) |
| 3 | Run a Test Task: the code dialog appears off to the left and shows a spinning cursor | Done; checked in the running app (2026-11-18) |
| 4 | The app is too big: download OpenCode only when it's chosen | In progress |
| 5 | Which engine a connection runs on: should the user choose it? | Proposed, the maintainer's call |

## 1. The panel is too transparent

> "This is a bit too transparent, don't you think?" (2026-11-18, with a screenshot of the panel over a browser)

The panel used Liquid Glass's **clear** style, which macOS meant for media, not text. In the screenshot the browser's tabs and address are readable through the panel, and through the Accounts card they compete with "ChatGPT plan" and "Claude plan".

Now the panel uses the **regular** (frosted) style with a 35 % tint of the window colour, so what's behind it shows only as colour and shape (`GlassBackground.make` in `StatusItem.swift`). For design review, `AGNETA_GLASS=clear` brings back the old look and `AGNETA_PANEL_TINT=<0…1>` tries another strength. Reduce Transparency still makes it opaque.

## 2. Settings: the title runs into scrolled content

> "If I scroll down in the About menu, you can see the header there, where it overlaps. The text overlaps." (2026-11-18, screenshot of Settings → About scrolled down, "About" drawn over "Codex adapter")

Every window, Settings and task details included, was given a transparent title bar, which only the glass dialogs need. With nothing behind the title, content scrolled straight into it. Now only dialogs hide their title bar (`WindowPresenter.show` in `Windows.swift`); standard windows keep theirs, and on macOS 26 content fades under it as in System Settings.

## 3. The test task's code dialog

> "If I run a test task, I get this weird dialog that shows up to the left of the main window … If I hover it with my cursor, it has a spinning ball." (2026-11-18, screenshot)

The dialog is the sandboxed test client's (Run a Test Task), not Agneta's. The client never ran an app event loop: its protocol code ran at the top level, and the dialog was put on screen without one, so nothing answered its events (a spinning cursor, an OK button that did nothing), and it landed at a default position with a generic icon. Now it runs `NSApplication.run()` (`Sources/agneta-testclient/main.swift`). The code dialog is a normal modal alert, centred and with a symbol for its icon, and it closes itself once the user has answered in Agneta's window.

## 4. A smaller download: engines on demand

> "The size of the app is a bit too big … OpenCode is kind of big. Could that be deferred and downloaded on demand if the user chose it?" (2026-11-18)

Where the size goes today (Intel, every engine): OpenCode 227 MB of the 404 MB bundle, Node and codex-acp 139 MB, Goose 19 MB, Agneta 18 MB. The download is 172–177 MB; with Goose alone it would be 16 MB ([RELEASING.md](RELEASING.md#what-a-release-weighs)).

Claude Code's adapter already works this way: pinned in `Engines/runtimes.lock` and downloaded on first use, checked against its SHA-256. The plan is to treat OpenCode, and Node with codex-acp, the same:

- **OpenCode** (a 108–113 MB zip) downloads when the user picks OpenCode for an API-key account. Goose stays the default, so most people never fetch it. OpenCode serves API keys only, never plans.
- **Node and codex-acp** download when the user connects a ChatGPT plan, since that's the only use for them.
- The release then ships Goose only: a download of about 16 MB instead of about 175.
- Each download is pinned and checked, shows progress in the panel and Settings, can be retried, works for isolated instances, and lands in Agneta's data folder. Reset removes it, and an update keeps it if the pin hasn't changed. The SBOM marks these as "downloaded on first use", and PRIVACY.md lists the hosts.
- Hardened runtime: a downloaded OpenCode or Node isn't covered by the app's signature. It keeps its vendor signature, or Agneta signs it ad hoc with the same entitlements, and the sandbox profile still applies. This has to be proven on Apple silicon before it ships.

## 5. Choosing the engine

> "When I make a connection to a provider from an external app, how do I, as a user, get to choose which engine it runs on? Is this something we should let the user decide as well?" (2026-11-18, screenshot of the approval dialog for Project Chat)

Today the engine belongs to the **account**, not the app: Settings → Accounts → an account's ⋯ menu → Engine. That menu shows only when the account can run on more than one engine (a Claude plan on Claude Code or Goose; an API key on Goose, OpenCode, and Codex or Claude Code). Every app using that account gets that engine. Nothing on the approval dialog or in the panel says which engine an account runs on, so the choice is effectively hidden.

Proposal: keep the choice per account, since that's where sign-in and credentials live and apps shouldn't need to care, and make it visible and easy to change:

- The approval dialog's account rows and the panel's account rows say what each runs on ("ChatGPT plan · Codex").
- Adding an account asks which engine when there's more than one, with the recommended one preselected and a line on how they differ.
- An account's Settings row gets a plain Engine picker, not one buried in the ⋯ menu.
- Not now: a different engine per app for the same account. It can be added later as a per-grant setting if a real need appears. Apps already see each engine's abilities in `initialize`.

