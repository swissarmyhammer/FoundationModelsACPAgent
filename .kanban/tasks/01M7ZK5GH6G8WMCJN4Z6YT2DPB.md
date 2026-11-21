---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7zkfnhn66bytzpn4wjnfm6r
  text: |-
    ### Research (implement)

    Decision of the coordinator for work item 1: fix it in this repository. The synchronous coordinated read of `SessionAgentResolution.workingDirectoryAgent` (`AgentRegistry.rootAgent(in:id:)`, NSFileCoordinator) runs on a dispatch queue for blocking file reads, through a checked continuation. Cancellation and errors stay as they are.

    Synchronous AgentRegistry / FileCoordination calls on the async paths of a session in this repository:
    - `SessionAgentResolution.workingDirectoryAgent` -> `AgentRegistry.rootAgent(in:id:)`: the only synchronous call of this repository that reaches `FileCoordination.run`. Reached from `resolve` and `restore`, through `RoutedACPAgent.resolveSessionAgent` in `composeSession` (session/new, load, resume). Fix: the read moves to the dispatch queue.
    - `AgentRegistry.catalog()` and `agentsGraph()`: no I/O (their documentation says so). No change.
    - `AgentRegistry.load()` in `AgentsComposition.loadedAgentRegistry`: the API is async, but its build (`Generation.read` -> `AgentCatalogBuilder.coordinatedRead`) does the coordinated read synchronously inside FoundationModelsAgents, on the thread of the caller task. This repository cannot give that read a queue with a continuation. Fix in this repository: run the `load()` call with a task executor preference over the same dispatch queue, so the synchronous part of the build runs off the cooperative pool.
    - The reloads that a watcher change or a conflict change starts run in tasks of FoundationModelsAgents (`AgentReloadLoop`), and `AgentWriter` writes run inside the `agents` tool. This repository cannot reach them. They need a request to FoundationModelsAgents.
    - No other package of the graph (Skills, Extras, Router, Multitool) uses NSFileCoordinator.

    Work item 2, the places where a test loads a watched agent registry, or composes a surface (which loads one) and does not stop it:
    - `SessionAgentTests.makeCatalog`
    - `SettingsFoldersTests.composedAgentCatalog`
    - `ToolCatalogTests`: four `ToolCatalog.sessionSurface` calls with no `shutdown()` (skills off, embedder, settings tool, kanban mount).
    - `SkillsLibraryTests.makeSurface` (two tests use it, no `shutdown()`).
    - `AgentConflictVersionSourceTests` stops its registry already. `SettingsFoldersTests` "old stack" registry has `watch: false`.

    Discovery (production, not in this card): `composeSession` loads the agent registry, then `resolveSessionAgent` can throw; and `AgentsComposition.compose` loads a registry, then `AgentEnvironment.make` can throw (`openModeInSandbox`). On these error paths nothing stops the loaded registry. A new task records it.
  timestamp: 2026-11-21T17:46:51.829125+00:00
- actor: claude-code
  id: 01m7zm7w24nb1w5szr2zy373bh
  text: |-
    ### Implementation landed

    Decision (coordinator, work item 1): fix it in this repository. `BlockingFileReads` (Sources/FoundationModelsACPAgent/Agent/BlockingFileReads.swift) has one concurrent DispatchQueue for blocking file reads.
    - `SessionAgentResolution.workingDirectoryAgent` reads the root `AGENT.md` with `BlockingFileReads.read(_:)` (checked continuation on the queue). `resolve`, `restore` and `RoutedACPAgent.resolveSessionAgent` are now async. A `readRootAgent` parameter (default `coordinatedRootAgentReader` = `AgentRegistry.rootAgent(in:id:)`) is the seam of the test. Errors stay the same; the read did not see a cancel before and does not see one now.
    - `AgentsComposition.loadedAgentRegistry` runs `registry.load()` in `BlockingFileReads.withReadExecutor(_:)`: a task executor preference over the same queue, so the synchronous build of FoundationModelsAgents (coordinated reads of each agent file) runs off the pool.
    - Not reachable from this repository: the reloads that the watcher or the conflict source start (tasks of `AgentReloadLoop`), and `AgentWriter` writes. They need a request to FoundationModelsAgents.

    Work item 2: `AgentRegistryFixture.loadedCatalog(of:)` (test Support) loads, takes the catalog, and stops the registry, also on a load error. `SessionAgentTests.makeCatalog` and `SettingsFoldersTests.composedAgentCatalog` use it. `ToolCatalogTests` (four tests) and `SkillsLibraryTests` (two tests) now call `surface.shutdown()`.

    Tests (TDD, each seen failing first):
    - `BlockingFileReadsTests`: the probe sees the pool (sanity); the read of a new session and of a resumed session runs off the pool (RED: `[true]`, `[true, true]`); the registry load reads off the pool through `ProbingConflictVersionSource` (RED: `[true]`).
    - `AgentRegistryFixtureTests.theLoadedCatalogOfARegistryStopsTheRegistry`: the change stream of the conflict source ends while the test keeps the registry (RED: time limit after 64 s).

    New task ^22h3kvw: error paths of `composeSession` and `AgentsComposition.compose` leave the loaded registry watching.
  timestamp: 2026-11-21T18:00:04.932926+00:00
- actor: claude-code
  id: 01m7zm7z5ya8f5n8cq6parb7z7
  text: |-
    ### implement — changed
    - evidence: two full root `swift test` runs: 2747 tests in 290 suites passed, 0 failures, 0 warnings each (1 known issue is the deliberate `withKnownIssue` of HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps). Files: Sources/FoundationModelsACPAgent/Agent/BlockingFileReads.swift (new), Agent/SessionAgentResolution.swift, Agent/SessionAgentComposition.swift, Agent/SessionSetup.swift, Tools/AgentsComposition.swift; Tests: BlockingFileReadsTests.swift (new), AgentRegistryFixtureTests.swift (new), Support/CooperativePool.swift (new), Support/ProbingConflictVersionSource.swift (new), Support/AgentRegistryFixture.swift (new), SessionAgentTests.swift, SettingsFoldersTests.swift, ToolCatalogTests.swift, Integration/SkillsLibraryTests.swift.
    - next: /review. Not committed.
  timestamp: 2026-11-21T18:00:08.126632+00:00
- actor: claude-code
  id: 01m7zmdnpy57y33nzbcweqytw8
  text: |-
    ### review — findings
    - evidence: `review sha 5b4b48d~1..5b4b48d` (HEAD~1..HEAD); 14 files reviewed; 1 finding (1 confirmed, 1 refuted): Tests/FoundationModelsACPAgentTests/Support/ProbingConflictVersionSource.swift:39.
    - next: Correct the item in the "Review Findings (2026-11-21 12:01)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-21T18:03:15.038446+00:00
- actor: claude-code
  id: 01m7zmjw8xy36t2q116d1s4nkw
  text: |-
    ### implement — changed
    - Finding `ProbingConflictVersionSource.swift:39` (reuse/reuse) corrected: the new `CooperativePoolReadRecorder` (Tests/FoundationModelsACPAgentTests/Support/CooperativePoolReadRecorder.swift) is the one recorder of pool reads, with `record()` and `reads`. `ProbingConflictVersionSource` and `RootAgentReadProbe` each hold one recorder and call `record()` before they read. No other `Mutex<[Bool]>` pool recorder stays in the test code. The only other use of `CooperativePool.isCurrentThreadInPool` is the probe sanity test, which records nothing.
    - evidence: `swift build --build-tests` gave "Build complete!"; BlockingFileReadsTests + AgentRegistryFixtureTests: 5 tests passed; full root `swift test`: 2747 tests in 290 suites passed, 0 failures, 0 warnings (1 known issue is the deliberate `withKnownIssue` of HarnessSmokeTests). Files: Support/CooperativePoolReadRecorder.swift (new), Support/ProbingConflictVersionSource.swift, BlockingFileReadsTests.swift.
    - next: review again. Not committed.
  timestamp: 2026-11-21T18:06:05.597950+00:00
- actor: claude-code
  id: 01m7zmm14qkv7gx841b7gyz43s
  text: 'Request for FoundationModelsAgents (2026-11-21): the reads that this repository cannot move (the reload tasks of the watcher and the conflict source, and the writes of the agents tool) need a change in FoundationModelsAgents. No FoundationModelsAgents session runs. The `sah --cwd` card write on its board hung for 5 minutes and made no card, so I stopped it. The request is in the brief `/Users/wballard/github/swissarmyhammer/.briefs/foundationmodelsagents-coordinated-reads-off-pool.md` for the next session of that repository.'
  timestamp: 2026-11-21T18:06:43.351664+00:00
- actor: claude-code
  id: 01m7zmmzykz3cyv5dbr47cxgnt
  text: |-
    ### review — clean
    - evidence: `review sha 6b5b7a3~1..6b5b7a3` (HEAD~1..HEAD); 3 files reviewed; 0 findings (0 confirmed, 0 refuted). The item of the 12:01 section is checked.
    - next: none. The task is in done.
  timestamp: 2026-11-21T18:07:14.899439+00:00
position_column: done
position_ordinal: ffffffbc80
title: The session open path blocks a cooperative thread on a synchronous NSFileCoordinator read, and test sessions leak agent registries
---
Found on 2026-11-21 during ^j5dys15.

## Facts

- `SessionAgentResolution.workingDirectoryAgent` calls `AgentRegistry.rootAgent(in:id:)` of FoundationModelsAgents from the async `session/new` path. The call does a synchronous coordinated read (`FileCoordination.run`, `NSFileCoordinator.coordinate(readingItemAt:)`) on a thread of the cooperative pool. A slow file coordinator (many file presenters, a sync engine that holds a claim) then holds a pool thread for each open session.
- In the full root `swift test` before ^j5dys15, 581 file presenters stayed at the end of the run: agent registries that a test loaded with `watch: true` and did not stop (for example `SessionAgentTests.makeCatalog` loads a registry and does not call `stopWatching()`). Each such registry also keeps its `DotfolderWatcher` descriptors open.
- ^j5dys15 gives the test agents a conflict source with no file presenter, so these facts do not fail the tests now.

## Work

- [x] Decide if the coordinated read of the session open path must move off the cooperative pool (in this repository, or as a request to FoundationModelsAgents). Decision: in this repository (`BlockingFileReads`). The reloads inside FoundationModelsAgents need a request to that package.
- [x] Stop each agent registry that a test loads with `watch: true`.

## Tests

- [x] A test shows the fix of each work item. #flaky

## Review Findings (2026-11-21 12:01)

> Scope: `review sha 5b4b48d~1..5b4b48d` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Support/ProbingConflictVersionSource.swift:39` `reuse/reuse` — The new `conflictVersions(of:)` repeats the record-on-pool logic that already exists in `RootAgentReadProbe`. Both keep a `Mutex<[Bool]>` of pool reads, both read `CooperativePool.isCurrentThreadInPool`, and both expose `readsOnCooperativePool`. Two copies of this recorder can drift apart, and a fix to one does not reach the other. Move the recorder into one shared test-support type, for example a `CooperativePoolReadRecorder` with `record()` and `reads`, in Tests/FoundationModelsACPAgentTests/Support/. Let both `ProbingConflictVersionSource` and `RootAgentReadProbe` hold it. Each keeps its own read logic and calls `record()` before it reads.