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
- actor: claude-code
  id: 01m5dex9gcyvffssf9p9e2k3fc
  text: |-
    Research (implement step, run 2). Hooks c66f336 and Multitool d618aa8 are already in Package.resolved and IntegrationTests/Package.resolved, thus no package update is necessary.

    Plan:
    - `candidateTranscriptRoots()` is private on `RoutedACPAgent` and uses `settingsStore.merged(for:)` and `loadSessionContext(workingDirectory:)`. To use the same resolution without a copy, a new internal `RegisteredRecordingRoots.resolve(in: SettingsStore)` in `Agent/` holds the walk of the project registry. `candidateTranscriptRoots()` calls it and keeps its two log records. `LoadedSessionContext` gets a static load over a `SettingsStore`, which `loadSessionContext(workingDirectory:)` and the resolution share. The registry folder (the user layer of a stack over `/`) moves from `SessionList.swift` to the same type, and `registryUserLayerRoot()` calls it.
    - New public `SnapshotInventory` in `Agent/SnapshotInventory.swift`: `list()` reads `shadowSessionKeys()` and `timelineSummary(sessionKey:)` for each key. `.noTimeline` gives an entry with no count and no date. Each other summary error gives the same entry and a warning. A key is `recorded` when a `sessions.jsonl` under a resolved recording root has its session id. `remove(sessionKeys:)` continues after an error and names the error case with `ACPAgentTelemetry.errorCaseName(of:)`.
    - Safety decision: when the registry, the settings of a project or a `sessions.jsonl` cannot be read, the recorded state is not known. Then `remove --unrecorded` removes nothing and exits with status 1, because a recorded key can look unrecorded.
    - `SnapshotStore.remove(sessionKey:)` sees only the keys open in its own process. A CLI remove cannot see a session of a running agent. The help text tells the user this.
    - CLI: `Sources/acp-agent/SnapshotsCommand.swift` with `List` (`--json`) and `Remove` (`<key>...` or `--unrecorded`, not both, not none: a usage error in `validate()`). The JSON encoder of `config show` moves to a shared CLI helper so that `snapshots list --json` does not copy it.
  timestamp: 2026-10-20T20:09:11.948430+00:00
- actor: claude-code
  id: 01m5dfcf0t03dvkk7dw6h78jmt
  text: |-
    Implementation landed (TDD: RED was a compile failure on the missing types, then GREEN).

    What changed:
    - New `Sources/FoundationModelsACPAgent/Agent/RegisteredRecordingRoots.swift`: the registry walk that `candidateTranscriptRoots()` had. `session/delete` and the inventory now use the same resolution. The registry folder moved here from `SessionList.swift` (`registryUserLayerRoot()` calls it).
    - `LoadedSessionContext.load(workingDirectory:from:)` in `SessionSetup.swift`. `loadSessionContext(workingDirectory:)` calls it.
    - New `Sources/FoundationModelsACPAgent/Agent/SnapshotInventory.swift` (public): `SnapshotInventory.list()` and `remove(sessionKeys:)`, with `SnapshotInventoryEntry`, `SnapshotRecordedState`, `SnapshotInventoryWarning`, `SnapshotInventoryListing` and `SnapshotRemovalOutcome`. The error case comes from `ACPAgentTelemetry.errorCaseName(of:)`. No log record holds a path.
    - New `Sources/acp-agent/SnapshotsCommand.swift`, and `Snapshots.self` in `AcpAgentCommand.swift`. `remove` with no selection, or with keys and `--unrecorded`, is a usage error from `validate()` (exit 2).
    - New `Sources/acp-agent/JSONDocument.swift`: the JSON encoder of `config show` moved there (with ISO 8601 dates), so that `snapshots list --json` does not copy it.
    - README: two command rows, and text in the `snapshots` capability row.

    Discovery: `SnapshotTimelineSummary.workingDirectory` holds the `/tmp/...` form of a `/private/tmp/...` work tree. The test compares the two paths after `resolvingSymlinksInPath()`.

    Decision (see the research comment): when the registry, the settings of a project or a `sessions.jsonl` cannot be read, `remove --unrecorded` removes nothing and exits 1.
  timestamp: 2026-10-20T20:17:29.114141+00:00
- actor: claude-code
  id: 01m5dfckdaegzs9cdk1rch48ty
  text: |-
    ### implement — changed
    - evidence: `swift test` 1110 tests in 121 suites passed (1 known issue is the existing `withKnownIssue` in HarnessSmokeTests; the one build warning is the mlx-swift bundle "missing creator for mutated node", not source code). New: SnapshotInventoryTests (6 tests), SnapshotsCommandTests (8 tests). Files: Sources/FoundationModelsACPAgent/Agent/RegisteredRecordingRoots.swift (new), Sources/FoundationModelsACPAgent/Agent/SnapshotInventory.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/Agent/SessionList.swift, Sources/acp-agent/SnapshotsCommand.swift (new), Sources/acp-agent/JSONDocument.swift (new), Sources/acp-agent/AcpAgentCommand.swift, Sources/acp-agent/ConfigCommand.swift, README.md, Tests/FoundationModelsACPAgentTests/SnapshotInventoryTests.swift (new), Tests/FoundationModelsACPAgentTests/SnapshotsCommandTests.swift (new).
    - next: /review. The task stays in `doing`. Nothing is committed.
  timestamp: 2026-10-20T20:17:33.610462+00:00
- actor: claude-code
  id: 01m5dfjhjdq7ccn9dta45xagx6
  text: |-
    Coordinator change (2026-10-20): the safety rule on `--unrecorded` and the help text on running agents stay. A key with no snapshot folder must not show as removed.

    Done (TDD; RED was a compile failure on the missing `.noSnapshotFolder`):
    - `SnapshotInventory.remove(sessionKeys:)` is now `async throws`. It reads `shadowSessionKeys()` one time. A key that is not in that list gets the new outcome `SnapshotRemovalOutcome.noSnapshotFolder(sessionKey:)`, and the inventory does not call `remove` for it.
    - CLI: such a key writes `<key>: no snapshot folder` to stderr. The command continues with the next key, and the exit status is 1. Help text and README row updated.
    - Tests: the old `..` / `invalidSessionKey` tests are replaced, because `..` now also gives "no snapshot folder". New: `aKeyWithNoSnapshotFolderIsNotRemovedAndTheNextKeyIs` (library) and `aMistypedKeyGoesToStderrAndTheNextKeyIsRemoved` (CLI: not on stdout, on stderr, exit 1). The `.failed` path is now proved with a read-only snapshot folder (0o500): `aRefusedRemoveGivesAFailedOutcomeWithTheErrorCase` and `aRefusedRemoveGoesToStderrWithTheErrorCase`. Each test sets the permissions back.
  timestamp: 2026-10-20T20:20:48.333918+00:00
- actor: claude-code
  id: 01m5dfjmetjac1dz7t4et0e29q
  text: |-
    ### implement — changed
    - evidence: `swift test` 1112 tests in 121 suites passed, 0 failures (1 known issue is the existing `withKnownIssue` in HarnessSmokeTests; the one build warning is the mlx-swift bundle "missing creator for mutated node", not source code). Changed in this pass: Sources/FoundationModelsACPAgent/Agent/SnapshotInventory.swift, Sources/acp-agent/SnapshotsCommand.swift, README.md, Tests/FoundationModelsACPAgentTests/SnapshotInventoryTests.swift (7 tests), Tests/FoundationModelsACPAgentTests/SnapshotsCommandTests.swift (9 tests).
    - next: /review. The task stays in `doing`. Nothing is committed.
  timestamp: 2026-10-20T20:20:51.290196+00:00
- actor: claude-code
  id: 01m5dfp9tpf8b48ff5r4wc4bx3
  text: |-
    ### test — green
    - evidence: swift test — 1112 tests in 121 suites passed, 0 failed, 0 skipped, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests). swift build --build-tests after touching the 11 changed Swift files — complete, 0 compiler warnings. swift build --build-tests --package-path IntegrationTests — complete. The only warning is the accepted SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle.
    - read-only tests: SnapshotInventoryTests and SnapshotsCommandTests set 0o500 on the snapshot directory and restore the owner-only permissions in a defer, so the temporary folders can be removed. They pass as a normal user.
    - next: review
  timestamp: 2026-10-20T20:22:51.478294+00:00
- actor: claude-code
  id: 01m5dfx5whc0m0446hhpj7yb0b
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 6aebc75). 0 findings, 0 confirmed, 3 refuted, 14 attempted, 0 failed. 11 files reviewed. README.md has no validator. Two .kanban files are excluded by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-20T20:26:36.817590+00:00
- actor: wballard
  id: 01m5dfxgjjzbeb0bb9jzbwc3a0
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 12 files (after HOOKS-5; a second pass makes an unknown key an error)
    - test: green — swift test 1112 passed; IntegrationTests builds
    - commit: 6aebc75
    - review: clean — 0 findings; task is done
  timestamp: 2026-10-20T20:26:47.762487+00:00
depends_on:
- 01M5DCV6DGXMS6FGXQ6AEFMPDZ
position_column: done
position_ordinal: fff680
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
- [x] `acp-agent snapshots list` shows each snapshot key with its checkpoint count, last checkpoint time and recorded state. `--json` gives the same data as JSON.
- [x] `acp-agent snapshots remove <key>` removes only the named key. `--unrecorded` removes only the keys with no recorded session.
- [x] With no argument, `remove` fails with a usage error and removes nothing.
- [x] No sweep at start removes a snapshot folder.
- [x] The README documents the command.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SnapshotInventoryTests.swift`: a temporary data directory with two keys, one recorded in a temporary `sessions.jsonl` and one not. The inventory reports both with the correct recorded state. A remove of `--unrecorded` removes only the unrecorded key.
- [x] A test that `remove` with no argument is a usage error (parse `AcpAgentCommand` with `["snapshots", "remove"]`).
- [x] A test that agent start keeps the snapshot folders.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.