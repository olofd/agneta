# Releasing

How a release of Agneta is built, signed, published and updated, what it weighs, and which parts are built yet. The pipeline below is the plan agreed on 2026-11-18; each step's status says what exists today.

## How a release works

The maintainer pushes a tag such as `v0.1.0`. GitHub Actions builds Agneta on GitHub's own Macs, once for Apple silicon and once for Intel, signs it with Agneta's Developer ID, notarizes it, tests what a user downloads, and attaches it to a **draft** release. The maintainer checks the draft and publishes it. Publishing is the one switch: the DMGs appear on the release page, Agneta's update feed points at the new version, and the Homebrew tap is bumped.

It follows what open-source Mac apps that release from CI do (Stats, AltTab, CodeEdit, Ollama, UTM): a Developer ID certificate in a temporary keychain on the runner, `notarytool`, and `gh release create`. Ollama, which also ships helper programs inside its app, is the closest model: every bundled program is signed before the app, and both the app and the DMG are notarized and stapled.

## The parts

### 0. Accounts and secrets (once, by the maintainer)

- A Developer ID Application certificate for Agneta alone, so revoking it never affects another app. Exported as a `.p12` with macOS-compatible encryption (`openssl pkcs12 -export -legacy`, or Keychain Access): newer OpenSSL defaults don't import into a macOS keychain.
- An App Store Connect API key for notarization, Agneta's own.
- A GitHub environment `release`, usable only from `v*` tags and waiting for the maintainer's approval, holding the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY` and `HOMEBREW_TAP_TOKEN` (a fine-grained token that may write only to the tap), and the variables `AGNETA_SIGN_IDENTITY` and `AGNETA_SPARKLE_PUBLIC_KEY` (Sparkle's public key, built into the app). A ruleset lets only the maintainer create `v*` tags. Pull requests never see these secrets.
- Sparkle's EdDSA key, made once with Sparkle's `generate_keys`. The private key is kept offline as well as in the secret: without it, installed copies can't be updated again.
- The repository `olofd/homebrew-tap`.

Status: not done.

### 1. A correct release build (`scripts/dev/build-app --release`, `scripts/dev/release`)

- **Version from the tag.** `CFBundleShortVersionString` is the tag's version; `CFBundleVersion` is the commit count, so it only rises. Sparkle compares it to decide what's newer.
- **Each bundled program is signed with what it needs**, from an explicit list, inside out, with the hardened runtime and a secure timestamp. OpenCode is a Bun-compiled binary and Node compiles JavaScript, so both may make executable memory ([Bun's guide](https://bun.com/docs/guides/runtime/codesign-macos-executable)). The build fails if any Mach-O file is left unsigned.
- **Notarization by App Store Connect API key** (`AGNETA_NOTARY_KEY`, `AGNETA_NOTARY_KEY_ID`, `AGNETA_NOTARY_ISSUER`), or a stored `notarytool` profile on a maintainer's Mac. A rejection prints Apple's log.
- **The DMG**, made with `hdiutil` (no new dependency): the app is signed, notarized and stapled, then put in a DMG with a link to Applications; the DMG is signed, notarized and stapled too, so the first launch works offline.
- **The smoke test runs on what a user gets:** the app is copied out of the mounted DMG and marked as downloaded (quarantined), Gatekeeper must accept it, Agneta must start and serve apps, and every bundled engine must start and answer `initialize` under the hardened runtime.
- **Files per architecture:** `Agneta-<version>-arm64.dmg` and `-x86_64.dmg` for people, the matching `.zip` for Sparkle, plus one `SHA256SUMS.txt`.

Status: built and run without a Developer ID (2026-11-18): the version, the DMG, the zip, the sums and the smoke test of the DMG all pass with ad hoc signing, and Node and OpenCode run under their entitlements. Developer ID signing and notarization have not run yet: they need step 0.

### 2. The release workflow (`.github/workflows/release.yml`)

- Starts on a `v*` tag, or by hand as a dry run that builds and signs but only keeps the files as a workflow artifact.
- `verify`, without secrets: the tag has a section in `CHANGELOG.md`, the commit is on `main`, and CI passed on it.
- `build`, one job per architecture (Apple silicon and Intel runners), in the `release` environment: imports the certificate into a temporary keychain, runs `scripts/dev/release`, and deletes the keychain and keys whatever happens.
- `publish`: writes `SHA256SUMS.txt`, records GitHub's build provenance attestation (`gh attestation verify` checks a download against it), writes each architecture's Sparkle feed with `generate_appcast`, takes the notes from `CHANGELOG.md`, and creates the draft with `gh release create --draft --verify-tag`, uploading the checksums last.
- On publishing, a second workflow bumps the Homebrew tap and checks that the update feed serves the new version.
- Every action is pinned by commit, and each job has only the permissions it needs.

Status: drafted, not yet in the repository: the update feeds need Sparkle's tools, which wait for the maintainer's go-ahead to download.

### 3. Updates in the app (Sparkle 2)

- Sparkle, pinned to an exact version, with a "Check for Updates…" item in the panel's ⋯ menu and, in Settings, "Check for updates automatically" and "Download and install automatically". Sparkle asks before its first check; automatic installation is off until the user turns it on. Reminders are the gentle kind meant for menu bar apps.
- An update installs only when no task is running, or when Agneta quits. Apps reconnect and resume their tasks with `session/load`.
- Each architecture has its own feed, `https://github.com/olofd/agneta/releases/latest/download/appcast-<arch>.xml`. `latest` never points at a draft, so publishing is what offers an update. Updates are verified with the EdDSA key built into the app, as well as by their Developer ID signature.
- Development builds and isolated instances (`AGNETA_HOME`) have no feed and never update themselves.
- [PRIVACY.md](PRIVACY.md) then says exactly what an update check contacts; Sparkle's system profiling stays off.

Status: not done. Today there are no automatic updates: a new release replaces the app, and data and sign-ins carry over.

### 4. Homebrew

- A cask in `olofd/homebrew-tap` (`brew install olofd/tap/agneta`), one per architecture through `arch arm: "arm64", intel: "x86_64"`, marked `auto_updates true` so `brew` leaves updating to Sparkle. The publish workflow bumps its version and checksums; the tap's CI runs `brew audit --cask --strict` and installs it.
- Homebrew's own cask repository needs public interest first (for a project submitted by its author: 225 stars, 90 forks or 90 watchers; [policy](https://docs.brew.sh/Package-Acceptance-Policy)). Once it's there, Homebrew's bots keep it current.

Status: the cask is in `packaging/homebrew/agneta.rb`; the workflow that fills it in and pushes it is drafted with the release workflow.

### 5. The first release

A dry run, installed on an Intel and an Apple silicon Mac: it opens without a Gatekeeper warning and runs tasks on real accounts. Then `v0.1.0` is tagged, approved, checked and published; `brew install olofd/tap/agneta` is tried on a clean Mac; and `v0.1.1` proves the update from 0.1.0.

## Building a release by hand

Until the workflow exists, on each architecture, from a commit tagged `v<version>`:

```bash
AGNETA_SIGN_IDENTITY="Developer ID Application: …" AGNETA_NOTARY_PROFILE=agneta scripts/dev/release --previous <last release's zip>
```

It builds `build/Agneta.app` with the release identity (`com.objectivecoder.agneta`, port 47321) and does part 1 above, leaving the DMG, the zip and `SHA256SUMS-<arch>.txt` in `build/release/`. It refuses an uncommitted checkout. `AGNETA_NOTARY_PROFILE` is a profile stored once with `xcrun notarytool store-credentials`; `AGNETA_NOTARY_KEY`, `AGNETA_NOTARY_KEY_ID` and `AGNETA_NOTARY_ISSUER` use an API key instead. Without `AGNETA_SIGN_IDENTITY` everything is signed ad hoc and nothing is notarized: fine for testing, refused by Gatekeeper on other Macs.

## The smoke test

`scripts/dev/smoke-test <Agneta.app|Agneta.dmg> [--gatekeeper] [--previous <zip>]` installs the app into a temporary folder and checks it as a user gets it: given a DMG, the app is copied out of the mounted image; with `--gatekeeper`, the DMG and the app (marked as downloaded) must pass Gatekeeper and carry stapled tickets; the signature holds; each bundled engine starts as signed (`goose-acp` and `opencode` answer ACP `initialize`, Node runs JavaScript); Agneta starts and listens for apps, writes its database and log without errors, `agneta-diag` reads that data, and it starts again on the same data. With `--previous`, the previous release runs first on the same data folder, so the new build starts on what an older one left: the upgrade path. Every run is an isolated instance (its own data folder, Keychain service and port) and stops what it started. Database migrations are also tested on their own (`StoreTests`).

## What a release weighs

Measured on an Intel Mac with macOS 26.6.2, 2026-11-17:

| | Every engine (`--engines all`) | Goose only (`--engines goose`) |
| --- | --- | --- |
| App bundle | 404 MB | 38 MB |
| Zip (the download) | 177 MB | 16 MB |
| Cold start, launch to listening for apps (median of 5) | 271 ms | 271 ms |

Where the size goes, with every engine: OpenCode 227 MB, Node (for Codex's adapter) 118 MB, codex-acp 21 MB, Goose 19 MB, Agneta and its tools 18 MB. Engines start only when a task needs them, so they don't change the app's start-up. Starting one (launch to its `initialize` answer, median of 5): Goose 17 ms, OpenCode 394 ms.

Releases ship every engine: a ChatGPT plan needs Codex's adapter and Node. Shipping Goose alone and downloading the others when an account needs them, as Claude Code's adapter is, would cut the download tenfold; that is a later step.

## Support

| | |
| --- | --- |
| macOS | 14 and later. The tests pass on 15 and 26 ([CONTAINMENT.md](CONTAINMENT.md#supported-macos-versions) lists each version's status) |
| Architectures | Apple silicon and Intel, one build each: a universal app would carry both architectures' engines and double the download |
| Building | Xcode 26 or later |
