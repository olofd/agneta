# Releasing

How a release of Agneta is built, signed, published and updated, what it weighs, and which parts are built yet. The pipeline below is the plan agreed on 2026-11-18; each step's status says what exists today.

## How a release works

The maintainer pushes a tag such as `v0.1.0`. GitHub Actions builds Agneta on GitHub's own Macs, once for Apple silicon and once for Intel, signs it with Agneta's Developer ID, notarizes it, tests what a user downloads, and attaches it to a **draft** release. The maintainer checks the draft and publishes it. Publishing is the one switch: the DMGs appear on the release page, Agneta's update feed points at the new version, and the Homebrew tap is bumped.

It follows what open-source Mac apps that release from CI do (Stats, AltTab, CodeEdit, Ollama, UTM): a Developer ID certificate in a temporary keychain on the runner, `notarytool`, and `gh release create`. Ollama, which also ships helper programs inside its app, is the closest model: every bundled program is signed before the app, and both the app and the DMG are notarized and stapled.

## Making a release

1. **Write the notes.** In `CHANGELOG.md`, rename the section at the top to `## <version> (<date>)`, for example `## 0.2.0 (2026-12-01)`, and say what changed for people and for apps. Links are absolute (`https://github.com/olofd/agneta/blob/v<version>/…`), so they work on the release page and in the update window. Commit and push to `main`.
2. **Wait for CI.** A release can only be made from a commit on `main` that CI has passed.
3. **Tag it:**
   ```bash
   git tag -a v0.2.0 -m "Agneta 0.2.0" && git push origin v0.2.0 && git push nuc v0.2.0
   ```
   Only the maintainer can create `v*` tags (the "Release tags" ruleset). A version with a hyphen, such as `0.2.0-rc.1`, becomes a prerelease: it isn't offered as an update or put in the tap.
4. **Approve.** The Release run waits on the `release` environment twice, once for the builds and once for the draft: on the run's page, **Review deployments** → `release` → **Approve and deploy**. The builds take about 20 minutes.
5. **Check the draft.** On the [releases page](https://github.com/olofd/agneta/releases), the draft holds both DMGs, both update zips, both update feeds and `SHA256SUMS.txt`. Its text is the changelog section followed by [packaging/release-page.md](../packaging/release-page.md) (install steps, updates, app developers, checking a download), filled in with the version. Edit the text there if needed; the files are signed and must not be replaced by hand.
6. **Publish.** Publishing makes the release public. Within minutes installed copies see the update, since the feeds are served from `releases/latest`. It also starts the Homebrew run: approve it once more, and it bumps the tap and checks that both feeds offer the new version. When that run ends, the website is rebuilt with the new version's download links ([site/README.md](../site/README.md)).
7. **Check it as a user.** Download a DMG from the release page and open it. On a Mac with the previous version, use Check for Updates…. Then run `brew upgrade --cask agneta`, or `brew install olofd/tap/agneta` on a clean Mac, and check that [agneta.dahlbom.io](https://agneta.dahlbom.io/#install) names the new version.

Dry run: **Actions → Release → Run workflow**, with a version such as `0.2.0-rc.1`. It builds, signs and notarizes from `main` after approval, and keeps the files as a workflow artifact for 14 days. Nothing is published.

If a build fails, nothing has been published. Fix the cause on `main`, delete the tag (`git push origin :v0.2.0`, and `git tag -d v0.2.0`), and tag the new commit. Once a release is published, never move or reuse its tag: release a new version instead.

## The parts

### 0. Accounts and secrets (once, by the maintainer)

- A Developer ID Application certificate for Agneta alone, so revoking it never affects another app. `release-secrets` writes its `.p12` with the LibreSSL macOS ships, since OpenSSL 3's defaults don't import into a macOS keychain.
- An App Store Connect API key for notarization, Agneta's own.
- A GitHub environment `release`, usable only from `v*` tags and from `main` (for dry runs), and waiting for the maintainer's approval, holding the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY` and `HOMEBREW_TAP_TOKEN` (a fine-grained token that may write only to the tap), and the variables `AGNETA_SIGN_IDENTITY` and `AGNETA_SPARKLE_PUBLIC_KEY` (Sparkle's public key, built into the app). A ruleset lets only the maintainer create `v*` tags. Pull requests never see these secrets.
- Sparkle's EdDSA key, made once with Sparkle's `generate_keys` in the maintainer's login keychain (account `agneta`), and kept in a password manager too. The private key is kept offline as well as in the secret: without it, installed copies can't be updated again.
- The repository `olofd/homebrew-tap`.

[RELEASE_SETUP.md](RELEASE_SETUP.md) walks through all of it; `scripts/dev/release-secrets`, run by the maintainer, puts every key in the environment.

Status: done (2026-11-18).

### 1. A correct release build (`scripts/dev/build-app --release`, `scripts/dev/release`)

- **Version from the tag.** `CFBundleShortVersionString` is the tag's version; `CFBundleVersion` is the commit count, so it only rises. Sparkle compares it to decide what's newer.
- **Each bundled program is signed with what it needs**, from an explicit list, inside out, with the hardened runtime and a secure timestamp. Node compiles JavaScript, so it may make executable memory. OpenCode, a Bun-compiled binary that needs the same ([Bun's guide](https://bun.com/docs/guides/runtime/codesign-macos-executable)), isn't bundled: the app downloads it when a provider defaults to it or a task asks for it, and it runs with its own vendor signature. The build fails if any Mach-O file is left unsigned.
- **Notarization by App Store Connect API key** (`AGNETA_NOTARY_KEY`, `AGNETA_NOTARY_KEY_ID`, `AGNETA_NOTARY_ISSUER`), or a stored `notarytool` profile on a maintainer's Mac. A rejection prints Apple's log.
- **The DMG**, made with `hdiutil` (no new dependency): the app is signed, notarized and stapled, then put in a DMG with a link to Applications; the DMG is signed, notarized and stapled too, so the first launch works offline.
- **The smoke test runs on what a user gets:** the app is copied out of the mounted DMG and marked as downloaded (quarantined), Gatekeeper must accept it, Agneta must start and serve apps, and every bundled engine must start and answer `initialize` under the hardened runtime.
- **Files per architecture:** `Agneta-<version>-arm64.dmg` and `-x86_64.dmg` for people, the matching `.zip` for Sparkle, plus one `SHA256SUMS.txt`.

Status: built and run without a Developer ID (2026-11-18): the version, the DMG, the zip, the sums and the smoke test of the DMG all pass with ad hoc signing, and Node and OpenCode run under their entitlements. The first dry run on GitHub (0.1.0-rc.1, 2026-11-18) signed both architectures with the Developer ID, Apple notarized the app and the DMG, Gatekeeper accepted the DMG and the downloaded app, and the smoke test passed on both: DMGs of 156 MB (Apple silicon) and 180 MB (Intel).

### 2. The release workflow (`.github/workflows/release.yml`)

- Starts on a `v*` tag, or by hand as a dry run that builds and signs but only keeps the files as a workflow artifact.
- `verify`, without secrets: the tag has a section in `CHANGELOG.md`, the commit is on `main`, and CI passed on it.
- `build`, one job per architecture (Apple silicon and Intel runners), in the `release` environment: imports the certificate into a temporary keychain, runs `scripts/dev/release`, and deletes the keychain and keys whatever happens.
- `publish`: writes `SHA256SUMS.txt`, records GitHub's build provenance attestation (`gh attestation verify` checks a download against it), writes each architecture's Sparkle feed with `generate_appcast`, takes the notes from `CHANGELOG.md`, and creates the draft with `gh release create --draft --verify-tag`, uploading the checksums last.
- On publishing, a second workflow bumps the Homebrew tap and checks that the update feed serves the new version.
- Every action is pinned by commit, and each job has only the permissions it needs.

Status: the build half has run: the dry run of 2026-11-18 built, signed, notarized and smoke-tested both architectures in about 20 minutes. The publish half (attestation, feeds, the draft) runs only on a tag, so the first release runs it; the feed script has run with Sparkle's tools on a real build (see [Testing an update](#testing-an-update)).

### 3. Updates in the app (Sparkle 2)

- Sparkle, pinned to an exact version, with a "Check for Updates…" item in the panel's ⋯ menu and, in Settings, "Check for updates automatically" and "Download and install automatically". Sparkle asks before its first check; automatic installation is off until the user turns it on. Reminders are the gentle kind meant for menu bar apps.
- An update installs only when no task is running, or when Agneta quits. Apps reconnect and resume their tasks with `session/load`.
- Each architecture has its own feed, `https://github.com/olofd/agneta/releases/latest/download/appcast-<arch>.xml`. `latest` never points at a draft, so publishing is what offers an update. Updates are verified with the EdDSA key built into the app, as well as by their Developer ID signature.
- Development builds have no feed and never update themselves. Nor do isolated instances (`AGNETA_HOME`), unless whoever starts one gives it a feed with `AGNETA_UPDATE_FEED`, to test the update path; such an instance installs when it quits and isn't relaunched, since macOS would relaunch it without its environment.
- [PRIVACY.md](PRIVACY.md) then says exactly what an update check contacts; Sparkle's system profiling stays off.

Status: built (2026-11-18), with Sparkle 2.10.1 in `Contents/Frameworks` (2.3 MB, without the XPC services only sandboxed apps need), signed inside out by `build-app` and `release`. Tested on an Intel Mac with ad hoc signing and a throwaway key: a 0.0.1 build, started isolated against a local feed, found 0.0.2, downloaded it without asking (automatic installs on), checked its EdDSA signature and replaced itself, and the updated copy passed the smoke test. An update between two Developer ID–signed builds is proven by 0.2.0 → 0.3.0. Not tested yet: Install and Relaunch from Sparkle's window, and the reminder in the panel.

### 4. Homebrew

- A cask in `olofd/homebrew-tap` (`brew install olofd/tap/agneta`), one per architecture through `arch arm: "arm64", intel: "x86_64"`, marked `auto_updates true` so `brew` leaves updating to Sparkle. The publish workflow bumps its version and checksums; the tap's CI runs `brew audit --cask --strict` and installs it.
- Homebrew's own cask repository needs public interest first (for a project submitted by its author: 225 stars, 90 forks or 90 watchers; [policy](https://docs.brew.sh/Package-Acceptance-Policy)). Once it's there, Homebrew's bots keep it current.

Status: the tap exists (2026-11-18), and `homebrew.yml` writes the cask from `packaging/homebrew/agneta.rb` when a release is published. The tap has no CI of its own yet.

### 5. The first release

A dry run, installed on an Intel and an Apple silicon Mac: it opens without a Gatekeeper warning and runs tasks on real accounts. Then `v0.1.0` is tagged, approved, checked and published; `brew install olofd/tap/agneta` is tried on a clean Mac; and `v0.1.1` proves the update from 0.1.0.

Status: done. `v0.1.0` was tagged and published, and every release since, up to `v0.3.1`, came through the same steps. The update path was proven by 0.2.0 → 0.3.0 rather than by a 0.1.1.

## Building a release by hand

Releases come from the workflow. To build one on a maintainer's Mac instead (to test signing, say), on each architecture, from a commit tagged `v<version>`:

```bash
AGNETA_SIGN_IDENTITY="Developer ID Application: …" AGNETA_NOTARY_PROFILE=agneta AGNETA_SPARKLE_PUBLIC_KEY=<public key> scripts/dev/release --previous <last release's zip>
```

It builds `build/Agneta.app` with the release identity (`com.objectivecoder.agneta`, port 47321) and does part 1 above, leaving the DMG, the zip and `SHA256SUMS-<arch>.txt` in `build/release/`. It refuses an uncommitted checkout. `AGNETA_NOTARY_PROFILE` is a profile stored once with `xcrun notarytool store-credentials`; `AGNETA_NOTARY_KEY`, `AGNETA_NOTARY_KEY_ID` and `AGNETA_NOTARY_ISSUER` use an API key instead. Without `AGNETA_SIGN_IDENTITY` everything is signed ad hoc and nothing is notarized: fine for testing, refused by Gatekeeper on other Macs.

## The smoke test

`scripts/dev/smoke-test <Agneta.app|Agneta.dmg> [--gatekeeper] [--previous <zip>]` installs the app into a temporary folder and checks it as a user gets it: given a DMG, the app is copied out of the mounted image; with `--gatekeeper`, the DMG and the app (marked as downloaded) must pass Gatekeeper and carry stapled tickets; the signature holds; each bundled engine starts as signed (`goose-acp` and `opencode` answer ACP `initialize`, Node runs JavaScript); Agneta starts and listens for apps, writes its database and log without errors, `agneta-diag` reads that data, and it starts again on the same data. With `--previous`, the previous release runs first on the same data folder, so the new build starts on what an older one left: the upgrade path. Every run is an isolated instance (its own data folder, Keychain service and port) and stops what it started. Database migrations are also tested on their own (`StoreTests`).

## Testing an update

Without a release, on one Mac, with any key pair (an ed25519 key made with `openssl genpkey -algorithm ed25519`: the last 32 bytes of its DER private key and of its DER public key, each base64-encoded, are Sparkle's private and public key):

1. Build the old version, `AGNETA_SPARKLE_PUBLIC_KEY=<public> AGNETA_VERSION=0.0.1 scripts/dev/build-app --release`, and copy `build/Agneta.app` aside. Commit anything, then build the new version the same way with `AGNETA_VERSION=0.0.2`: Sparkle compares build numbers, which are commit counts.
2. Zip the new app (`ditto -c -k --keepParent`) as `Agneta-0.0.2-<arch>.zip` in a folder, with a copy under the other architecture's name, and run `SPARKLE_ED_PRIVATE_KEY=<private> scripts/dev/appcast 0.0.2 <folder>` from a checkout whose `CHANGELOG.md` has a `## 0.0.2` section.
3. Point the feed's enclosure at a local server (`python3 -m http.server --bind 127.0.0.1`), and start the old copy isolated: `AGNETA_HOME=<folder> AGNETA_PORT=<port> AGNETA_UPDATE_FEED=http://127.0.0.1:<port>/appcast-<arch>.xml <old>/Agneta.app/Contents/MacOS/Agneta`. Sparkle's settings are the release bundle ID's preferences: `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` on and an old `SULastCheckTime` make it check, download and get ready at once; quitting it installs the update.
4. Afterwards, delete what the test left in the release ID's preferences and caches (`defaults delete com.objectivecoder.agneta`, `~/Library/Caches/com.objectivecoder.agneta`, `~/Library/HTTPStorages/com.objectivecoder.agneta`), and Sparkle's `~/Library/Caches/Sparkle_generate_appcast`.

Agneta's log (`<folder>/Logs/agneta.jsonl` for an isolated instance) records `updates-started`, `update-found`, `update-waiting`, `update-installing` and `update-failed`.

## What a release weighs

Measured on an Intel Mac with macOS 26.6.2, 2026-11-18, after OpenCode stopped being bundled (0.1.0, which bundled it, was 404 MB, a 172–177 MB download):

| | A release (`--engines all`: Goose, Node and codex-acp) | Goose only (`--engines goose`) |
| --- | --- | --- |
| App bundle | 180 MB | 38 MB |
| Zip (the download) | 59 MB | 16 MB |
| Cold start, launch to listening for apps (median of 5, 2026-11-17) | 271 ms | 271 ms |

Where the size goes: Goose 19 MB, Agneta and its tools 18 MB, Sparkle 2.3 MB. OpenCode (227 MB unpacked, a 108–113 MB download) comes only when a provider defaults to it or a task asks for it, like Claude Code's adapter, and so, in a release, does Codex's runtime: Node (118 MB) and codex-acp (21 MB), packed as `Agneta-codex-runtime-<version>-<arch>.zip` by `scripts/dev/release`, signed, checked to run, attached to the release and pinned by the app's `codex-runtime.lock`. Engines start only when a task needs them, so they don't change the app's start-up. Starting one (launch to its `initialize` answer, median of 5): Goose 17 ms, OpenCode 394 ms.

Since 0.2.1 a release bundles Goose only: a 19 MB DMG (measured on Intel, 2026-11-18, with Sparkle and the icon). Codex's runtime is 43 MB more, fetched the first time a ChatGPT plan (or an app set to Codex) needs it.

## Support

| | |
| --- | --- |
| macOS | 14 and later. The tests pass on 15 and 26 ([CONTAINMENT.md](CONTAINMENT.md#supported-macos-versions) lists each version's status) |
| Architectures | Apple silicon and Intel, one build each: a universal app would carry both architectures' engines and double the download |
| Building | Xcode 26 or later |
