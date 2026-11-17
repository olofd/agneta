# Releasing

How a release of Agneta is built, signed, checked and published, what it weighs, and what isn't done yet.

## Steps

1. CI passes on the commit ([CI.md](CI.md)), and `CHANGELOG.md` has the release's section.
2. On each architecture (a release is per architecture: build on an Apple silicon Mac and on an Intel Mac):

   ```bash
   AGNETA_SIGN_IDENTITY="Developer ID Application: …" AGNETA_NOTARY_PROFILE=agneta scripts/dev/release --previous <last release's zip>
   ```

   `scripts/dev/release` builds `build/Agneta.app` with the release identity (`com.objectivecoder.agneta`, port 47321), signs everything inside it with the identity (secure timestamp, hardened runtime; Node may make executable memory, since it compiles JavaScript), zips it, notarizes and staples it, writes the zip's SHA-256, and runs the smoke test. It refuses an uncommitted checkout.
3. Publish both zips and their `.sha256` files with the release notes from `CHANGELOG.md`.

`AGNETA_NOTARY_PROFILE` is a profile stored once with `xcrun notarytool store-credentials`. Without `AGNETA_SIGN_IDENTITY` the build is signed ad hoc: fine for testing, but Gatekeeper refuses it on other Macs.

## The smoke test

`scripts/dev/smoke-test <Agneta.app> [--previous <zip>]` installs the app into a temporary folder and checks it as a user gets it: the signature holds, it starts and listens for apps, writes its database and log without errors, `agneta-diag` reads that data, and it starts again on the same data. With `--previous`, the previous release runs first on the same data folder, so the new build starts on what an older one left: the upgrade path. Every run is an isolated instance (its own data folder, Keychain service and port) and stops what it started. Database migrations are also tested on their own (`StoreTests`).

## What a release weighs

Measured on an Intel Mac with macOS 26.6.2, 2026-11-17:

| | Every engine (`--engines all`) | Goose only (`--engines goose`) |
| --- | --- | --- |
| App bundle | 404 MB | 38 MB |
| Zip (the download) | 177 MB | 16 MB |
| Cold start, launch to listening for apps (median of 5) | 271 ms | 271 ms |

Where the size goes, with every engine: OpenCode 227 MB, Node (for Codex's adapter) 118 MB, codex-acp 21 MB, Goose 19 MB, Agneta and its tools 18 MB. Engines start only when a task needs them, so they don't change the app's start-up. Starting one (launch to its `initialize` answer, median of 5): Goose 17 ms, OpenCode 394 ms.

Goose only covers OpenAI and Anthropic API keys and Claude plans (Claude Code's adapter downloads on first use, as it does today). A ChatGPT plan needs Codex's adapter and Node, and OpenCode is only another engine for API keys. Shipping Goose alone and downloading the others when an account needs them, as the Claude adapter is, would cut the download tenfold. Which accounts the first release supports is still a product decision; the build supports both.

## Support

| | |
| --- | --- |
| macOS | 14 and later. Tested on 26 ([CONTAINMENT.md](CONTAINMENT.md#supported-macos-versions) lists each version's status) |
| Architectures | Apple silicon and Intel, one build each |
| Building | Xcode 26 or later |
| Updates | None automatic yet: a new release is downloaded and replaces the app; data and sign-ins carry over |

## Not done yet

- **A Developer ID.** Signing and notarization are scripted, but no release has been signed: that needs the maintainer's Apple Developer Program membership.
- **Automatic updates.**
- **A universal build.** Releases are per architecture.
