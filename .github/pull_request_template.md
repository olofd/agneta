<!-- What this changes, and why. For anything beyond a bug fix, link the issue where the problem was agreed. -->

- [ ] A test that fails without the change (for security and correctness fixes, a regression test)
- [ ] Measurements, not guesses, for anything about an engine's behaviour: what you ran, which version, what you saw
- [ ] Docs in step: `docs/APP_PROTOCOL.md`, `docs/DIAGNOSTICS.md` or `docs/ARCHITECTURE.md` if the protocol, traces or security model changed
- [ ] A line under "Unreleased" in `CHANGELOG.md`, if people or apps will notice
- [ ] `swift build && swift test` passes
