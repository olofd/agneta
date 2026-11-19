# Containment

How Agneta keeps an engine, and the commands it runs, inside what the user and the app allowed: what it relies on today, how that's checked on every supported macOS, and what replaces it if macOS takes it away. What each part of a task can reach is listed in [ARCHITECTURE.md](ARCHITECTURE.md#sandbox-profiles).

## What Agneta relies on

macOS's Seatbelt sandbox, through `/usr/bin/sandbox-exec`. Each engine process runs under a profile Agneta writes for it (`Policy/SandboxProfile.swift`), and every engine's shell commands run under a stricter one, through Agneta's tool broker. The profiles allow-list what may be read, written and run, and which network connections may be made; they deny Apple Events, LaunchServices, signals and process inspection outside the sandbox. Profiles are passed inline (`sandbox-exec -p`), never as a file. What they allow depends on the app's sandbox mode, contained or developer access ([APP_PROTOCOL.md](APP_PROTOCOL.md#sandbox)).

`sandbox-exec` is marked deprecated in its manual page, and the profile language isn't documented by Apple. It's still in macOS 26, and other agent tools rely on the same mechanism on macOS (Codex's and Claude Code's own sandboxes among them). The risks are that a macOS release:

- removes `sandbox-exec`: engines then don't start, since Agneta always launches them through it (it fails closed);
- changes what a rule means, so a profile allows more or less than before, silently.

The second is the dangerous one, so it is tested rather than assumed.

## How it's checked

`Tests/AgnetaKitTests/ContainmentTests.swift` is the acceptance test. A probe stands in for an engine and is started by the real supervisor, under the exact profile a `workspace` session's engine gets. It tries each of these, and the test fails if any result differs:

| Check | Expected |
| --- | --- |
| Read the workspace, and a folder the policy names as readable | Allowed |
| Write the workspace | Allowed |
| Write the readable folder | Refused |
| Read or write a folder outside the policy | Refused |
| Run a program from a folder it can't read | Refused |
| List `~/.ssh`, `~/Library/Preferences`, `~/Documents` | Refused |
| Signal a process outside the sandbox | Refused |
| Ask LaunchServices about another app | Refused |
| Connect to the app's tool server port on loopback | Allowed |
| Connect to another loopback port | Refused by the sandbox |
| Connect to port 80 on another host | Refused by the sandbox |
| Connect to port 443 on another host | Not refused by the sandbox (the engine's provider) |

`ToolBrokerTests` does the same for the shell commands' profile (no network, the workspace only, no LaunchServices, background jobs living on until their engine ends, none outliving Agneta). `DeveloperAccessTests` checks the developer profile (the home folder readable, secrets and Agneta's data refused, the app's caches writable), that a contained command resolves no names, and that planted links and swapped folders grant nothing. `EngineContractTests` checks which built-in tools each engine is given under each policy.

The test names the macOS version it ran on. It runs in CI on every supported major version ([CI.md](CI.md)), and a release is made only from a commit that passed on all of them.

## Supported macOS versions

| macOS | Intel | Apple silicon |
| --- | --- | --- |
| 26 | Passed (26.6.2, 2026-11-17) | Passed (26.7.2, CI, 2026-11-18) |
| 15 | Passed (15.7.9, CI, 2026-11-18) | Passed (15.8.2, CI, 2026-11-18) |
| 14 | Not yet run | Not yet run |

A version is supported once the acceptance test passes on it. Until then, the README says it's untested.

## The first stable profile

`app-only` sessions are the smallest surface and the first to call stable. Their engine has no built-in tools: it reads its own home and the system, writes only its home, and reaches the provider and the app's tool server. All the work happens in the app's own tools, under the app's own permissions. `read` and `workspace` sessions follow once the acceptance test has passed on every supported version and the native engines (Claude Code, Codex) have been run through it with their real programs.

## If Seatbelt goes away

In the order Agneta would take them:

1. **A lightweight Linux virtual machine per engine** (Virtualization.framework, or Apple's container tooling on macOS 26). The strongest boundary: the engine sees only the folders shared into it and a network Agneta controls, so per-host network rules become possible. It costs start-up time and memory, and the engines must have Linux builds. Goose, OpenCode, Codex and Claude Code all do.
2. **A separate macOS user per engine.** Strong file isolation from the user's own files, through ordinary permissions. It needs an administrator to create the accounts, and it can't confine network access.
3. **App Sandbox for an engine helper.** Supported by Apple, and inherited by the processes the helper starts. It can't express per-session folders without the user granting each one, so it fits only `app-only` sessions.

None of these is built. The acceptance test is written against behaviour, not against Seatbelt, so it carries over to whichever replaces it.

## Known limits

- **Developer access is a terminal's reach.** Commands and the engine's own tools get the internet, the home folder (credentials and Agneta's data excepted) and every loopback port. It's the default for an app with `workspace` tools, unless the user chooses Contained.
- **A contained task's sockets and ports are checked when it opens,** not before each command: the app's own server, or a socket in its granted folders, is what it may reach. If the app's server stops and another program takes its port or socket path during the session, its commands reach that program until the session ends ([APP_PROTOCOL.md](APP_PROTOCOL.md#tool-ports-and-sockets)).
- **A command that detaches** (`setsid`, `set -m`) can outlive its engine and Agneta, in both modes: the sandbox can't refuse it without breaking ordinary tools.
- **Engines reach any host on port 443.** Seatbelt filters connections by port, not host name, and engines need HTTPS for their provider. A per-host allowlist needs a network layer Agneta owns (a proxy, or the virtual machine route above).
- **Claude Code's and Codex's other built-in tools (reading, editing, fetching) run inside the engine's profile,** not the stricter shell profile; their commands go through the broker. Agneta refuses what the policy forbids in their permission requests ([APP_PROTOCOL.md](APP_PROTOCOL.md#permissions)). The acceptance test hasn't yet run with their real programs; it needs signed-in accounts.
- **Other processes' environments are readable** to any process of the user's, sandboxed or not: no Seatbelt rule stops `KERN_PROCARGS2` without stopping every program (measured). Agneta keeps its broker tokens in files; an API-key account's key is still in its engine's environment.
- **On a Claude or ChatGPT plan the engine reads `~/Library/Keychains`,** where Claude Code and Codex keep their sign-ins.
