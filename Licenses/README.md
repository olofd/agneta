# Licences of bundled components

The development app bundle carries these in `Contents/Resources/Licenses/`, with Agneta's own `LICENSE` and `NOTICE` and [THIRD_PARTY.md](../THIRD_PARTY.md).

| File | Component | Version | Source |
| --- | --- | --- | --- |
| `goose.txt` | Goose (`goose-acp`) | 1.59.2 | `LICENSE` at tag `v1.59.2` of aaif-goose/goose |
| `opencode.txt` | OpenCode | 2.3.0 | `LICENSE` at tag `v2.3.0` of anomalyco/opencode |
| `node.txt` | Node.js | 24.19.0 | `LICENSE` at tag `v24.19.0` of nodejs/node |
| `GRDB.swift.txt` | GRDB.swift | 7.9.0 | `LICENSE` of the pinned package checkout |
| `Sparkle.txt` | Sparkle | 2.10.1 | `LICENSE` of the pinned package checkout (Sparkle's own MIT licence and those of the code it includes) |

codex-acp and each of its npm dependencies keep their own licence file inside `Contents/Resources/codex-acp/` (the package's `LICENSE`, and each dependency's under `node_modules/`). None of these projects has a NOTICE file at the pinned version.

When a pin changes, replace the matching file with the licence at the new tag.
