# Follow-ups

Changes the maintainer asked for after 0.1.0, collected as they come in and worked through in order. Each item keeps the request in the maintainer's words, then what was done and where it stands. When an item ships, it moves to the changelog and its line here says which version.

| # | Request | Status |
| --- | --- | --- |
| 1 | The menu bar panel is too transparent | Done; checked in the running app (2026-11-18) |
| 2 | Settings: scrolled content runs into the window title | Done; checked in the running app (2026-11-18) |
| 3 | Run a Test Task: the code dialog appears off to the left and shows a spinning cursor | Done; checked in the running app (2026-11-18) |
| 4 | The app is too big: download OpenCode only when it's chosen | Done: OpenCode in 0.2.0 (download 177 → 59 MB), Codex's runtime in 0.3.0 (19 MB) |
| 5 | Which engine a connection runs on: should the user choose it? | Done: providers → engines only, chosen per task (after 0.2.0) |
| 6 | No Check for Updates in the app | Done in 0.2.0 |
| 7 | Quit Agneta from the menu never quits (development and 0.1.0) | Fixed in 0.2.0 |
| 8 | No app icon: a frosty, Swedish icon from the two rings, flat and glassy | Done in 0.2.0; redesigned (Sunset) after 0.3.1 |

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

**OpenCode, done (2026-11-18).** The bundle no longer carries OpenCode, only its pin (`Resources/opencode.lock`).
- `RuntimeInstaller` reads an engine lock as well as `runtimes.lock`, with the archive's size.
- Settings → Accounts → ⋯ → Engine lists "OpenCode (downloads 108 MB)". Choosing it downloads, checks and installs OpenCode, showing progress or the error under the account, then switches the account.
- An account already set to OpenCode (from an older build, or after Reset) gets it the next time Agneta configures the account.
- It runs with its vendor signature from `Runtimes/opencode/<version>/`, which the engine sandbox allows, the same way as Claude Code's adapter.
- An ad hoc release build: 180 MB unpacked instead of 404, a 59 MB zip instead of 177. The smoke test passes, and the SBOM lists OpenCode as downloaded on first use.
- Not yet tried: a real download in the app (113 MB from GitHub) followed by a task on OpenCode. The installer and the engine-lock format are covered by `RuntimeInstallerTests`.

**Node and codex-acp, done in 0.3.0** as Codex's runtime, a download of its own. The plan was: codex-acp is an npm package with 22 dependencies, so it isn't one release file like OpenCode. The likely way is to build one archive per architecture, Node plus the installed codex-acp, and attach it to each Agneta release, pinned by the app. That needs a decision on hosting, and on how development builds get it.

## 5. Choosing the engine

> "When I make a connection to a provider from an external app, how do I, as a user, get to choose which engine it runs on? Is this something we should let the user decide as well?" (2026-11-18, screenshot of the approval dialog for Project Chat)

Today the engine belongs to the **account**, not the app: Settings → Accounts → an account's ⋯ menu → Engine. That menu shows only when the account can run on more than one engine (a Claude plan on Claude Code or Goose; an API key on Goose, OpenCode, and Codex or Claude Code). Every app using that account gets that engine. Nothing on the approval dialog or in the panel says which engine an account runs on, so the choice is effectively hidden.

Proposal: keep the choice per account, since that's where sign-in and credentials live and apps shouldn't need to care, and make it visible and easy to change:

- The approval dialog's account rows and the panel's account rows say what each runs on ("ChatGPT plan · Codex").
- Adding an account asks which engine when there's more than one, with the recommended one preselected and a line on how they differ.
- An account's Settings row gets a plain Engine picker, not one buried in the ⋯ menu.
- Not now: a different engine per app for the same account. It can be added later as a per-grant setting if a real need appears. Apps already see each engine's abilities in `initialize`.

**Where it ended (2026-11-18), after three rounds with the maintainer.** First the engine was per account, then per app and account (0.2.0). Then: "We are pairing providers and engines in an unnecessary way", "the coupling is from Provider ⇒ Engine only", and "it's the task that defines what provider and what engine is used".
- **One relation.** Each kind of provider has the engines that can serve it, and one selected (`ProviderEngines` in AgnetaKit, the only place that knows the table). Settings → Engines selects it, and also shows each engine's source, version and install.
- **Per task.** A task runs on its account's provider's selected engine, unless it asks for another that provider supports (`_meta.agneta.engine`). `initialize` lists each account's engines. A resumed or forked task runs on the engine that saved it, so changing a provider's engine doesn't strand earlier tasks.
- **Nothing else names an engine:**
  - `AccountRecord.engine`, `Router.Grant.engines`, the approval window's "Runs on" picker and Settings → Apps' engine rows are gone.
  - Migration v5 carried each kind's engine to its provider setting and dropped both columns. It was run on a copy of the maintainer's own data: ChatGPT → Codex and Claude → Goose kept, columns gone, no errors.
  - The `engineUnavailable` error of 0.2.0 is gone too.
- **Tested** by `ProviderEngineTests`, `RouterContractTests.aTaskRunsOnAnEngineItsProviderSupports` (asking, defaulting, unsupported, missing) and `aTaskContinuesOnlyOnTheEngineThatSavedIt` (still resumes after the provider's engine changes).

**Then the grant (2026-11-18), the design that stands.** The maintainer: "one list of providers that the user can select and one list of engines that we give it access to. No combination, and then the app can later choose a valid combination", and "my mom should be able to use this": engines under Advanced, all ticked.
- **The grant is two lists:** providers (accounts) and engines (`all`, which includes engines added later, or some). The approval window shows the providers; the engines are behind **Advanced…** (a popover, so the dialog keeps its size). Settings → Apps edits both; narrowing stops sessions that no longer fit.
- **The app picks** each task's provider and engine. `Access` (AgnetaKit) is the one place that combines the grant, `ProviderEngines` and what's on this Mac; `agneta/access` and `agneta/accessChanged` tell the app.
- **What's on this Mac** is one `EngineCatalog` snapshot the app builds and hands to the runtime; the router, supervisor and windows all read it, which removes the drift the cold review found (capabilities after a download, the UI and router naming different engines, Goose shown for a Claude plan without Claude Code).
- **Pre-1.0, no compatibility:** one database schema (no migrations, no JSON import), unversioned extension names, no readers of old key or grant shapes. A database from another build is refused, and the user resets.
- **Tested** by `aTaskRunsOnAnEngineItsProviderSupports`, `theGrantLimitsTheEnginesAnAppMayPick`, `aSessionWaitingOnADownloadSaysSo` (downloadable → wanted, downloading → progress, ready → opens, `accessChanged` in order), `StoreTests.refusesADatabaseFromAnotherSchema`, and Project Chat's smoke test (it reads its access and runs on the default engine).

## 6. Check for Updates is missing

> "I know we implement a check-for-updates flow, but I don't have the button here. I expect to be able to check for updates in the app." (2026-11-18, screenshot of Agneta Dev's ⋯ menu)

The item existed only in builds that update themselves, so in Agneta Dev, built from source, the menu simply lacked it. Now **Check for Updates…** is always in the ⋯ menu. In a build without an updater it says why: a development build points to `scripts/dev/build-app` and offers to open the releases page. Settings → General already says the same. A release (GitHub or Homebrew) has the real update flow.

## 7. Quit Agneta hangs

> "When I use the menu to click 'Quit Agneta', the icon never quits, and the process never goes away." Then: "Same in the production build … the menu doesn't open. The process is still there and needs to be force quit." (2026-11-18)

A sample of the hung 0.1.0 showed the main thread inside `NSApplication.terminate`, called from the menu's Quit, which ran in a Swift task on the main actor. `applicationShouldTerminate` answered "later" and started a second main-actor task to stop the engines and reply. AppKit waits for that reply in a loop nested inside the first task, where neither the main actor nor the main queue can run another job, so the reply never came: a deadlock, with the menu unresponsive. Quitting by AppleScript worked, because an Apple event doesn't arrive in a main-queue job.

Now every quit goes through `applicationShouldTerminate` (`AgnetaApp.swift`). It stops listening at once, stops the engines off the main actor, and answers AppKit with a run-loop block, which a nested loop does run. If stopping hangs, Agneta quits after 10 s anyway. The menu's Quit only asks about running tasks, then calls `terminate`. A standalone app built with both handlers proved it: called from a main-actor task, the old one hung until killed, and the new one quit in a second.

## 8. An app icon

> "The development and the production version didn't have an app icon. We have an icon in the menu bar that's two rings interconnected. Use that and create an app icon … We like a Nordic theme, a frosty kind of theme." (2026-11-18)

The first icon (0.2.0, replaced by the redesign below), after two rounds with the maintainer ("I want a flatter icon", then "and glassy, modern; Sweden, not Norway"):
- **Design:** the menu bar mark's two linked rings, in the mark's own geometry, in lake-ice white on the blue of a Swedish winter sea (`#1F4B66`, a deeper shade of Agneta's accent). Two flat colours. In flat colour a crossing only reads with a gap, so both over-and-under crossings are cut as one, and the rings read as chain links.
- **Glass:** it's a Liquid Glass icon in Icon Composer's format (`packaging/AppIcon.icon`): the blue is the background fill, which macOS turns into a gentle gradient, and the rings are its glass layer, which macOS 26 lights, and darkens or tints with the user's icon style. `build-app` compiles it with Xcode's `actool` into `Assets.car`, plus a rendered `AppIcon.icns` for macOS 14 and 15.
- **How it's made:** the rings are drawn by `scripts/dev/app-icon.swift`, so proportions stay code. `scripts/dev/app-icon` redraws the ring layer and renders the preview through macOS itself. The background colour and glass settings are in `packaging/AppIcon.icon/icon.json`.
- **Checked:** Finder shows the rebuilt Agneta Dev with it.
- **Set aside:** a shaded frosted-ice version with an aurora sky, a pale one, and a flat one without glass. All are in the history of `scripts/dev/app-icon.swift`.

**Redesigned (2026-11-18):** "I think the one we have is too boring and bland." Of three directions (Aurora: warm and cool rings on a night sky; Sunset; Ocean: icy rings on bright blue), the maintainer chose Sunset ("The red purple is best"):
- **Design:** the same linked rings in warm white, now the glass layer over a Swedish summer evening: coral to rose to violet corner to corner, with the low sun's glow behind the rings and a faint sheen from above. The evening is its own image layer (`background.png`) beneath the glass, drawn by `scripts/dev/app-icon.swift`; the rings' translucency is low (0.15) so they stay crisp white on macOS 26.
- **Agneta Dev** has the same icon with a small white hammer in the violet corner (`packaging/AppIconDev.icon`), so the two tell apart side by side.
- **Checked:** the compiled icons as macOS renders them, at 1024 down to 32 points, on light and dark.
- **In the app** ("incorporate those colors subtly in the other panels"): the accent is the icon's rose, deepened to read (#B0365F light, #FF9DB4 as dark-mode text, #B8466E behind white text in dark mode), on the filled button, checkboxes, toggles and links; the rings mark in the panel and dialogs is drawn in the evening's gradient; and the panel and dialogs carry the evening as a faint glow along their top edge (`EveningGlow`). Glass buttons stay neutral, and running green and attention amber keep their meaning. The screenshots' backdrop is a muted dusk after the evening: a vivid one tinted every glass panel peach. Prominent buttons wear the evening as a gradient ("as a gradient preferably … but subtle"): coral-rose to rose to violet, deepened so white text reads at every stop (4.8:1 or more), with a glass sheen (`EveningButtonStyle`).

## Bug sweep before 0.2.0

An independent review of everything since 0.1.0 (2026-11-18) found six real defects, all fixed before the release, each in its own commit:

1. **A sandbox gap (security).** Per-app engines added shared engine keys like `<account>/shared-goose`, which the check keeping built-in tools off shared engines missed. An app could have reloaded an app-only task with workspace tools on the shared, unbrokered engine. Every check now goes through `EngineKeys.isShared`, and a contract test proves the refusal.
2. **Startup waited for a download.** An account on OpenCode without it downloaded it before Agneta listened for apps. Downloads now run in the background, with progress shown.
3. **Apps set to OpenCode** never got it again after a new pin or a failed download. Launch now fetches missing engines that apps use.
4. **Two shared Goose processes on one account home** were possible. Shared keys now always name their engine.
5. **The test client's code dialog** still didn't close by itself: a modal loop inside a main-queue job stops the main actor. It now starts from a run-loop block, proven in a standalone reproduction.
6. **Remove Access racing an engine change** could bring access back. The router re-checks, and the runtime deletes the row again.

The sweep also caught a CI failure: `actool` crashes on GitHub's macOS 15 Apple silicon runner. The compiled icon is now committed instead of built in every build.

## Cold review before 0.2.0

The maintainer brought a second, cold review (2026-11-18) with five findings. All five were checked against the code and are real.

- **Fixed in 0.2.0:**
  - **The symlink race.** Folders are written into sandbox profiles exactly as they were checked (`SessionPolicy.checkedPaths`), never resolved again.
  - **Soft limits.** After a 10 s grace, a limit ends the session.
  - **The `Int(1e300)` crash.** Limits outside the range are refused with -32602.
  - **Signalling a reused process group.** The reaper sees the exit with kqueue, ends the group while the zombie leader still holds its number, and only then reaps it; nothing signals the group after that. A first version used `waitid(WNOWAIT)`, which on macOS reports a stopped child over and over (631,242 calls in 3 s); measured and replaced.
- **The sign-in: fixed after 0.2.0.** Codex now keeps it in the login Keychain (`cli_auth_credentials_store = "keyring"` in the account's config.toml).
  - Researched in Codex's source at `rust-v0.167.0`: the Keychain service is "Codex Auth", and the account is a hash of the canonical CODEX_HOME. Saving deletes `auth.json`, refreshes write back to the Keychain, and `codex app-server` (which codex-acp starts) reads the setting.
  - Checked against the installed Codex 0.167: it accepts the setting and reports "Not logged in" for an empty account. A wrong value is refused, so the setting is really read.
  - The engine reaches the Keychain like the Claude Code engine, and sign-in is checked with `codex login status`. Sign Out and Reset run `codex logout`, which removes the entry.
  - There's no migration, so existing ChatGPT accounts sign in again once.
  - Not yet tried with a real ChatGPT account: a sign-in, a task, and a refresh.
- **Still open: other tasks' Codex sessions.** Codex always writes them under `CODEX_HOME/sessions/` (only its SQLite state can move), and needs them to resume, so they stay readable to a Codex task on the same account. Options to weigh: a deny rule for other sessions' files (Codex names them only once it writes them), or a CODEX_HOME per task (which would need a sign-in per task, since the Keychain entry is keyed by the folder).
- **Before this fix:** a Codex session could read its account's ChatGPT sign-in (`auth.json`) and the account's other Codex sessions, because the whole `CODEX_HOME` is in its sandbox, and Codex reads files with its own tools.
  - Codex 0.167 can keep the sign-in in the Keychain (`cli_auth_credentials_store = "keyring"`), as Claude Code already does. That would end the file exposure, but every ChatGPT account would have to sign in again, and it needs testing with a real account.
  - The other sessions need their own design, since Codex must keep them to resume tasks.


## Cold review after 0.2.0 (2026-11-18)

A review of `v0.2.0..3133e96`, judged here:
1. **ChatGPT sign-in from 0.2.0's file.** Moot: nothing carries over before 1.0, and Reset starts clean. Signing out without a Codex install now logs `codex-sign-out-skipped` instead of returning silently; the "Codex Auth" Keychain entry stays then, since only Codex's own logout knows its key.
2. **`capabilities: null` after a download.** Fixed by design: capabilities come from the catalog, which every download step rebuilds.
3. **UI and router disagreeing after an install appears or goes.** Fixed by design: one catalog snapshot. A Claude plan without Claude Code no longer shows Goose (Goose needs that same Claude Code): the catalog marks Claude Code unavailable and the panel says "Needs Claude Code".
4. **Apps can't start a download; resumed tasks stuck.** Fixed: asking for a downloadable or failed engine starts it (`engineWanted`) and answers `-32015`.
5. **Download state.** Try Again no longer loses what the download was for (selecting a default takes effect at once; tasks wait on `-32015`). A failed card can be put away and Reset clears it. The router's state comes from the same snapshot as the progress, delivered in order with only the newest kept, so a late progress update can't leave it stuck.
6. **Downloads never checked again; runtime version not tracking content.** Fixed: each downloaded engine is checked against its pin (archive hash and installed program hash) at each launch before it runs, and Codex's runtime version ends in a hash of its contents before signing.
7. **v5 dropping per-app engines.** Moot: no migrations before 1.0.
8. **Docs disagreeing with the code.** Rewritten with this change (APP_PROTOCOL, ENGINES, ARCHITECTURE).
9. **Codex reading the login Keychain** (needed for its keyring sign-in): already stated in CONTAINMENT.md ("On a Claude or ChatGPT plan the engine reads `~/Library/Keychains`").
10. **Provider→engine split between app and kit.** Done as `EngineCatalog` plus `Access`, with the host building the snapshot (only it knows the bundle and installs). The duplication left is gone too: each engine is described once (`EngineSource.all`, which the catalog, the Engines pane and downloads loop over), running its own tools is an engine capability, and a test proves `ProviderEngines` and the adapters' own refusals agree both ways.

## Architecture review after the grant (2026-11-18)

Fixed: Allow blocked for a provider whose engine isn't installed; a dismissed failed download restarting at once; a ~1 s main-thread hash at launch; a failed default stalling tasks while another engine was ready; small ones (checkbox flicker, the access log line, engines no provider can run listed to apps). Then the debt: `EngineLibrary` takes engines out of `AppModel` (1,100 → 860 lines); one `EngineSource` per engine; `AccessReport` and `SessionCapabilities` type what apps see; a downloaded runtime's whole tree is checked at launch, not only its program (codex-acp's JavaScript beside Node).

## External review of 0.3.0 (2026-11-18)

Tagged 0.3.0 as it was; the fixes go to 0.3.1. Real and fixed: pairing again left live connections on the old access and let an unverified app inherit another's grant by name; a session opening across an access change was checked only by grant id; Remove Access deleted before revoking; native runners allowed requests with no kind or an unknown one, and "always" passed through where there was no "once"; the limit grace waited on the cancel write; `initialize` had no deadline; history deletion left Claude Code transcripts and Codex rollouts; policy fields of the wrong type fell back to defaults; nothing bounded connections before pairing. By design: 0.2.0's data isn't read (no compatibility before 1.0); the update is now always shown across a minor version.

Left for later:
- **A wedged shared engine.** A limit ends the session and answers the prompt, but a shared engine (Goose without built-in tools) that ignores the cancel keeps running, for every app on that account. Restarting it would stop the others' sessions; decide whether a limit may.
- **Shared engines' conversations.** Done after 0.4.0: Goose 1.59.2 has `session/delete`, so the engine is asked, then its database is rewritten so no file keeps the words, and a session id it was asked to delete is never used again in that process (Goose reuses them broken). Left: that holds only within one process. A conversation still queued when Agneta restarts is asked for by its id, which the new Goose process may meanwhile have given to a new session (it numbers a new one after the highest id left); Agneta would then delete that one instead. See [ENGINES.md](ENGINES.md).
- **From the review's product ideas:** a support matrix (plan × engine × what works), an operator runbook, more end-to-end tests against the real engines. The matrix is now the capability matrix of the example app [Replica Bench](../examples/replica-bench/README.md).
