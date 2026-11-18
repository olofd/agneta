## Install

| Your Mac | Download |
| --- | --- |
| Apple silicon (M1 or later) | [Agneta-@VERSION@-arm64.dmg](https://github.com/olofd/agneta/releases/download/v@VERSION@/Agneta-@VERSION@-arm64.dmg) |
| Intel | [Agneta-@VERSION@-x86_64.dmg](https://github.com/olofd/agneta/releases/download/v@VERSION@/Agneta-@VERSION@-x86_64.dmg) |

Not sure which you have? Choose Apple menu → About This Mac: **Chip: Apple M…** means Apple silicon, **Processor: … Intel** means Intel.

1. Open the DMG and drag **Agneta** into **Applications**.
2. Open Agneta from Applications. It lives in the menu bar (the linked rings beside the clock), not in the Dock.
3. Click the menu bar icon and connect an account: a ChatGPT plan (needs [Codex](https://github.com/openai/codex) 0.166 or later), a Claude plan (needs Claude Code; the Claude desktop app includes it), or an OpenAI or Anthropic API key.
4. To see what an app does with it, choose **Run a Test Task** from the panel's ⋯ menu.

Or install with [Homebrew](https://brew.sh):

```bash
brew install olofd/tap/agneta
```

Needs macOS 14 or later. Agneta is signed with a Developer ID and notarized by Apple, so it opens without a warning.

## Updates

Agneta asks before it first checks for updates. After that it checks GitHub about once a day, and installs an update only when no task is running. **Check for Updates…** is in the panel's ⋯ menu; Settings → General turns automatic checks or installs off. Homebrew leaves updating to Agneta.

## For app developers

Apps connect at `ws://127.0.0.1:47321/acp` and pair once. Start with the [README's guide](https://github.com/olofd/agneta#for-app-developers), the [Project Chat example](https://github.com/olofd/agneta/tree/v@VERSION@/examples/project-chat) and the [app protocol](https://github.com/olofd/agneta/blob/v@VERSION@/docs/APP_PROTOCOL.md).

## Check a download

`SHA256SUMS.txt` lists every file's SHA-256, and GitHub records how each was built:

```bash
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
gh attestation verify Agneta-@VERSION@-arm64.dmg --repo olofd/agneta
```

The other files are for Agneta itself: the `.zip` files and `appcast-*.xml` for its updater, and `Agneta-codex-runtime-…` (Node and codex-acp), which it downloads the first time a Codex account is used. You don't need them. Problems and questions go to [Issues](https://github.com/olofd/agneta/issues); security reports go privately through the [Security tab](https://github.com/olofd/agneta/security).
