---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d5raa66d45naak3gk2bex7
  text: |-
    Research (implement step). Blocker: FoundationModelsHooks does not have the API that `snapshots list` needs.

    Facts (FoundationModelsHooks at `9a9e20a`, the checkout in `.build/checkouts` and the sibling repository are the same):
    - The public API of `SnapshotStore` is: `open(sessionKey:owner:workingDirectory:)`, `release(sessionKey:owner:)`, `remove(sessionKey:)`, `shadowSessionKeys()`, `take(sessionKey:trigger:)`, `checkpoints(sessionKey:)`, `rollback(sessionKey:to:)`.
    - `checkpoints(sessionKey:)` reads only the in-memory history of an OPEN key. For a key that is not open it throws `SnapshotError.unavailable`. An orphan key is never open in the CLI process.
    - `ShadowRepository`, `TimelineCommit` and `timeline()` are internal. The timeline ref (`refs/snapshots/timeline`), the `Snapshot-Trigger` trailer and the recorded working directory are internal too.
    - The only public way to read a closed timeline is `open(...)`. It is not usable for `list`: (1) it needs the working directory, and for an orphan key the agent does not know it (the recorded binding is private); (2) it WRITES: a baseline commit on an empty timeline, and a `changedWhileClosed` checkpoint when the work tree changed; (3) it can get `timelineConflict` against another process on the same key. A `list` command must not change a timeline.
    - A read of the shadow git repository in this package (libgit2 or `git`) copies the internal timeline format of Hooks. The orders tell not to do that and not to change Hooks.

    The exact API that is missing (proposal for a card on FoundationModelsHooks, to discuss first):

    ```swift
    /// A summary of the timeline of one session key, read from disk.
    public struct SnapshotTimelineSummary: Sendable, Equatable {
        public let sessionKey: String
        /// The number of checkpoints after the baseline.
        public let checkpointCount: Int
        /// The commit time of the last checkpoint, or nil when there is no checkpoint.
        public let lastCheckpointDate: Date?
    }

    extension SnapshotStore {
        /// Reads the timeline of `sessionKey` from its shadow directory. The key can be open or closed.
        /// The call does not open the key, does not need the working directory, and writes nothing.
        /// - Throws: `SnapshotError.invalidSessionKey`, `SnapshotError.unreadableTimeline`, or an error of libgit2.
        public func timelineSummary(sessionKey: String) async throws -> SnapshotTimelineSummary
    }
    ```

    Other parts of the card have APIs that exist (`shadowSessionKeys()`, `remove(sessionKey:)`, `AgentHooks.dataDirectory(name:environment:)`, `AgentHooks.snapshotDirectory(in:)`, `SessionIndex`, the project registry). No file was changed.
  timestamp: 2026-10-20T17:29:11.750833+00:00
- actor: claude-code
  id: 01m5d5rd5wtzxtj4xxhahm8bp8
  text: |-
    ### implement — stuck
    - evidence: no file changed. `SnapshotStore.checkpoints(sessionKey:)` throws `.unavailable` for a key that is not open, and FoundationModelsHooks `9a9e20a` has no public read of a closed timeline. Missing API: `SnapshotStore.timelineSummary(sessionKey:) async throws -> SnapshotTimelineSummary` (checkpoint count and last checkpoint date, read from disk, no open, no write).
    - next: a person decides on a FoundationModelsHooks card for that API. Then run implement again. The task stays in `doing`.
  timestamp: 2026-10-20T17:29:14.684980+00:00
- actor: wballard
  id: 01m5d5s2pd8wnwj4wk7hbq4aad
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 0 files changed. Missing API in FoundationModelsHooks 9a9e20a: a read-only summary of a timeline that is not open (checkpoint count, last checkpoint date), for example SnapshotStore.timelineSummary(sessionKey:). checkpoints(sessionKey:) throws .unavailable for a closed key, and open(...) writes to the timeline.
    - test: not run
    - commit: none
    - review: not run
    - next: the user decides whether to open a card on the Hooks board.
  timestamp: 2026-10-20T17:29:36.717839+00:00
- actor: wballard
  id: 01m5d8ymc3a082ebfe1mmfpcze
  text: 'Blocked outside this board (2026-10-20, the user said to work it out with the peer sessions): FoundationModelsHooks card ^rnqwhs1 adds a read-only `SnapshotStore.timelineSummary(sessionKey:)`. After the push, update the Hooks dependency and run /implement again.'
  timestamp: 2026-10-20T18:25:04.387881+00:00
- actor: wballard
  id: 01m5d95p7p77xzbjenyaft2nsd
  text: 'HOOKS-5 API, agreed with the Hooks session (2026-10-20); the sha follows after the push: `SnapshotStore.timelineSummary(sessionKey:) async throws -> SnapshotTimelineSummary` with `sessionKey`, `workingDirectory: URL?`, `checkpointCount` (no baseline) and `lastCheckpointDate: Date?`. It reads only and works for an open key and a closed key. It throws `.noTimeline`, `.invalidSessionKey` or `.unreadableTimeline`. Show `workingDirectory` only in the local CLI output, never in a log.'
  timestamp: 2026-10-20T18:28:55.670998+00:00
- actor: wballard
  id: 01m5da34m5kjn8mcvevzfjb84w
  text: 'HOOKS-5 is pushed: FoundationModelsHooks main c66f336d6866407154444167a8a0cc4bf450865c. Note from the Hooks session: timelineSummary throws noTimeline also for a directory that is not a git repository or that has no timeline ref, and it does not delete that directory. Wait for the MT-14 push (Multitool card ^ttsj5w6) too: the old take/checkpoints/rollback calls are gone, so Multitool main does not compile against this Hooks sha until MT-14 is pushed. Then update both dependencies together.'
  timestamp: 2026-10-20T18:45:00.677634+00:00
- actor: wballard
  id: 01m5davps32ha42z895tbarbg2
  text: 'MT-14 is pushed: FoundationModelsMultitool main d618aa8f91b79f4cdf1399d2590b079132f9ff4e (fix 66268e4). It builds against Hooks c66f336. The blockers are gone. Run `swift package update FoundationModelsHooks FoundationModelsMultitool` (and the same in IntegrationTests/), then /implement. The notAvailable text is "Snapshots are not available for this session: <cause>. Do not call tools.snapshots again in this session." with the cause workingDirectoryMismatch, timelineConflict or openFailed, and no path.'
  timestamp: 2026-10-20T18:58:25.699456+00:00
position_column: doing
position_ordinal: '8180'
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