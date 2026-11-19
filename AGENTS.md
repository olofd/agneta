# Instructions for agents working on Agneta

This repository is public. Everything pushed to GitHub (`origin`) is published, cached and indexed, and stays in its history. So the default workflow is **local first, reviewed, then published**.

## The workflow

1. **Work and commit locally.** Commit on `main` (or a branch) as you go, and back up to the maintainer's private backup remote between changes. Pushing there is not publishing.
2. **Before anything goes to GitHub, have it reviewed by an independent agent.** Give the reviewer the whole range that isn't on GitHub yet (`git log origin/main..main`, `git diff origin/main..main`), not your account of it, and have it check:
   - **Leaks:** personal information (names, email addresses, home folder paths beyond what code needs), names of private projects or products, internal planning documents, secrets and keys, vendor material, anything taken from another project's private code.
   - **Security:** anything that lets a session reach more than its sandbox allows (unbrokered code, the network or DNS when contained, files outside its folders, outliving its session), credentials or Agneta's own data exposed, and files an agent can write that a host or engine later trusts.
   - **Correctness:** bugs, races, docs that contradict the code, tests that don't test what they claim.
3. **Fix what the review finds** (with tests), and run the affected suites.
4. **Push to GitHub only with the maintainer's go**, after the review has passed. If a commit in the range holds something that mustn't be published, rewrite the range before pushing (that also means a force push to the private remote, which needs the maintainer's go too).

## Private material

- **Working plans stay on the maintainer's Mac.** `docs/NEXT_STEP*.md` is git-ignored: never commit it, never link to it from public files, and never name in public files the private projects it discusses.
- **No attribution lines** (Co-Authored-By, "Generated with …") in commits or pull requests. Commits are authored as `Olof Dahlbom <933408+olofd@users.noreply.github.com>`.

## Where to start

- [README.md](README.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how Agneta is built.
- [docs/APP_PROTOCOL.md](docs/APP_PROTOCOL.md) for the contract with apps, including the [sandbox](docs/APP_PROTOCOL.md#sandbox).
- [docs/ENGINES.md](docs/ENGINES.md) for what each engine does and what was measured.
- [docs/RELEASING.md](docs/RELEASING.md) before cutting a release.
