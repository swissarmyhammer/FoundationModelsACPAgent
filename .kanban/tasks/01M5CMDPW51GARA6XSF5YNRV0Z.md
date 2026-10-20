---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'acp-agent snapshots: an explicit command that lists and removes snapshot folders'
---
## What
Hooks `9a9e20a` keeps the shadow folder of each snapshot session key after the session ends. The agent must not remove orphan folders with a sweep. From time to time, many sessions work in one folder at the same time, so a sweep at start can remove the snapshots of a session that another process runs. The user runs an explicit command and decides what to remove.

Exception (the user decided this on 2026-10-20 for ACPA-15): `session/delete` removes the timeline of its own session. Another card does that work. This card does not change `session/delete`.

Add the CLI command `acp-agent snapshots` with two subcommands:

- `acp-agent snapshots list`: For each key of `SnapshotStore.shadowSessionKeys()`, write one line: the key, the number of checkpoints, the time of the last checkpoint, and `recorded` or `unrecorded`. `recorded` tells that a project of the project registry has the session in its `sessions.jsonl` (use the same resolution as `candidateTranscriptRoots()` in `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift`). Support `--json` as the `doctor` command does.
- `acp-agent snapshots remove <key>...`: Call `SnapshotStore.remove(sessionKey:)` for each key that the user names. `--unrecorded` removes each `unrecorded` key. With no key and no `--unrecorded`, the command fails with a usage error. Write each removed key to stdout. An error of one key (for example `.invalidSessionKey` or `.sessionKeyOpen`) goes to stderr, the command continues with the next key, and the exit status is not zero.

Files:
- New `Sources/acp-agent/SnapshotsCommand.swift`, in the pattern of `ConfigCommand.swift` and `InstructionsCommand.swift`.
- `Sources/acp-agent/AcpAgentCommand.swift`: add `Snapshots.self` to `subcommands`.
- The library code that finds the store and the recorded state goes in `Sources/FoundationModelsACPAgent/Agent/` (for example `SnapshotInventory.swift`), so that tests can use it without the CLI. Use `AgentHooks.dataDirectory(name:environment:)` and `AgentHooks.snapshotDirectory(in:)`.
- `README.md`: document the command next to the snapshots row.

Do not add a removal to agent start or to `session/close`.

## Acceptance Criteria
- [ ] `acp-agent snapshots list` shows each snapshot key with its checkpoint count, last checkpoint time and recorded state. `--json` gives the same data as JSON.
- [ ] `acp-agent snapshots remove <key>` removes only the named key. `--unrecorded` removes only the keys with no recorded session.
- [ ] With no argument, `remove` fails with a usage error and removes nothing.
- [ ] No sweep at start removes a snapshot folder.
- [ ] The README documents the command.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SnapshotInventoryTests.swift`: a temporary data directory with two keys, one recorded in a temporary `sessions.jsonl` and one not. The inventory reports both with the correct recorded state. A remove of `--unrecorded` removes only the unrecorded key.
- [ ] A test that `remove` with no argument is a usage error (parse `AcpAgentCommand` with `["snapshots", "remove"]`).
- [ ] A test that agent start keeps the snapshot folders.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.