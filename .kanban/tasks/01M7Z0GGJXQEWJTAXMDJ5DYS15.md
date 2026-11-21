---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7zhqj3dncv82xpyha5x88zs
  text: |-
    Research (2026-11-21):
    - Dependency diffs between the old and new pins do not touch the MCP stdio launch, the MCP connect, timeouts, the file watcher or concurrency. Multitool 48581fd..d8863fb: Sessions capability only (address aliases, importedFrom, sourceTitle, preferredFolder); Package.swift and the mcp-test-server target do not change. Extras 5660d0d..49c6965: ModelPool download retry, SessionAddress, telemetry; DotfolderWatcher.swift last changed 2026-10-16. Router 95c2141..e221cbd: ProfileDefinition defaults, address resolution, recorded import provenance.
    - The MCP connect of this repo has one attempt with a 10 s limit (MCPComposition.connectBackoffPolicy). The file is not changed since 2026-11-16.
    - Full run 1 at 11:13 (load 20.26 / 49.79 / 42.59 before, 30.29 / 43.81 / 41.02 after; other sessions ran swift-build, xcodebuild and a 5 h `bfs /` at the same time): 2740 tests, 4 issues. The MCP tests passed this time. Time limit (60 s) exceeded in AgentCatalogWatchTests.aClosedSessionLeavesNoRunningWatcher, AgentCatalogWatchTests.aNewAgentAfterTheCloseGivesNoChangeToTheClosedSession and SessionCancelStopsAllWorkTests.aShutdownStopsTheBackgroundChildRunAndCommandAtOnce. All failures are waits for an async event that does not come in time. Next: sample the test process during a hang.
  timestamp: 2026-11-21T17:16:13.293361+00:00
- actor: claude-code
  id: 01m7zk54kcq2pepn8ydrhw7k74
  text: |-
    Evidence and fix (2026-11-21):
    - Run 2 (11:16, load 15.40 before, 17.10 after): 7 issues; the MCP tests (connectFailed) and the two AgentCatalogWatchTests close tests failed again. `sample` of swiftpm-testing-helper at 60 s and 75 s: 18 of 18 cooperative threads in `NSFileCoordinator _blockOnAccessClaim` (callers: SessionAgentToolsTests.definition 16, SessionAgentResolution.workingDirectoryAgent 4). The arbiter queue com.apple.FileCoordination.3 was in `addFilePresenter:`.
    - Run 3 with a temporary probe of `NSFileCoordinator.filePresenters.count`: 177 at 5 s, 1691 at 30 s, 1695 at 40 s, 581 at the end. The probe itself did not run from 5 s to 30 s (its Task.sleep was starved). 32 issues, all time limits or MCP connects.
    - Probe program (scratchpad, not in the repo): 18 threads x 10 coordinated reads. 0 presenters: mean 20.6 ms; 200: 398.7 ms; 1000: 2784.1 ms; 3000: 6275.9 ms.
    - Not a dependency change: AgentConflictVersions.swift (the presenter) is in FoundationModelsAgents since 2026-11-13; the moved pins do not touch it. The full run of 2026-11-20 passed at a lower load.
    - Fix in this repository: `CatalogContext.agentConflictVersions` and `RoutedACPAgent(agentConflictVersions:)` (default `FileVersionConflictSource`, so production does not change); `AgentsComposition.makeAgentRegistry` gives it to `AgentRegistry`. Test support: `InertConflictVersionSource` (no presenter, no version) is the default of `makeStubAgent` and `CatalogRegistryFixture.makeContext`, and the other test contexts give it.
    - Run 4 with the probe after the fix: presenters 50 at 5 s, 4 from 30 s to the end; 2743 tests pass.
    - Still with the live source: the tests through `ComposedAgent.compose` (StubComposition). They give the peak of 50, which does not slow the reads.
  timestamp: 2026-11-21T17:41:06.796158+00:00
- actor: claude-code
  id: 01m7zk5zbh7tva122j2wkhxs4m
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` Build complete!, no warning. RED: AgentConflictVersionSourceTests did not compile (extra argument 'agentConflictVersions'); GREEN: 2 tests pass. Full root `swift test` two times: 2742 tests in 288 suites pass, 1 known issue (HarnessSmokeTests, expected), 66.8 s at load 19.48 to 30.84 and 72.4 s at load 30.84 to 36.34. Files: Sources/FoundationModelsACPAgent/Tools/CatalogContext.swift, Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTestSupport/InertConflictVersionSource.swift (new), Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/AgentConflictVersionSourceTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/CatalogRegistryFixture.swift, and the CatalogContext of AgentsToolTests, CodeContextSharingTests, Integration/SkillsLibraryTests, MCPCompositionTests, MultiRootConfinementTests, ScheduledAgentStoreTests, SettingsFoldersTests, ShellStoreSharingTests, SkillsMarketplaceTests, ToolCatalogTests; a doc reference in SessionSettingsStoreTests.
    - next: /review. New task ^6yt2dpb records the synchronous coordinated read on the cooperative pool and the agent registries that tests do not stop.
  timestamp: 2026-11-21T17:41:34.193189+00:00
position_column: doing
position_ordinal: '8380'
title: 'Full root swift test: MCP stdio connect tests and AgentCatalogWatchTests fail in the full run, pass alone'
---
Found on 2026-11-21 during ^f4z8wj9. The failures are also on the base commit a844424 without the changes of ^f4z8wj9 (same dependencies, Router e221cbd).

## Facts

- In a full root `swift test` (load average 4 to 24 on the Mac), these tests fail: `ToolModeTests.theOpenModeConnectsAStdioServer` (result `connectFailed`), `MCPCompositionTests.theOutcomesListConfigServersFirstThenClientServers`, `MCPCompositionTests.configNounsMountFirstThenClientNounsAndNoPathCarriesAnMCPSegment`, `MCPCompositionTests.aConfigStdioServerThatExitsBeforeItAnswersFailsAndTheNextServerConnects`, and `AgentCatalogWatchTests` (time limit of 60 s exceeded). One run also had `SettingsGraphTests.theEndpointConforms` (a subscription probe gave no response in 10 s).
- Alone (`--filter`), each suite passes; `AgentCatalogWatchTests` passes in 0.8 s.
- On 2026-11-20 a full run passed (2738 tests) before the pins of Extras (49c6965), Multitool (d8863fb) and Router moved.

## Cause (2026-11-21)

- Each agent registry of a session used the default `FileVersionConflictSource` of FoundationModelsAgents. It adds one `NSFileCoordinator` file presenter for each watched root. In the full run, the test process had up to 1695 presenters at one time, and 581 at the end.
- The time of one coordinated read increases linearly with the presenters of the process: 18 threads, 0 presenters 20.6 ms mean; 200 presenters 398.7 ms; 1000 presenters 2784.1 ms; 3000 presenters 6275.9 ms.
- The coordinated read of `AGENT.md` (`AgentRegistry.rootAgent`, `SessionAgentResolution.workingDirectoryAgent`) is synchronous on the cooperative pool. A sample at 75 s showed all 18 cooperative threads blocked in `NSFileCoordinator _blockOnAccessClaim`. Then each timer and each async wait of the other tests stopped (the MCP connect limit of 10 s, the watch events, the 60 s limits).
- The moved pins do not touch this path.

## Work

- [x] Find the cause: the load of the full run (a connect or watcher timeout), or a change in a dependency pin.
- [x] Make the tests deterministic in the full run.

## Tests

- [x] Two full root `swift test` runs pass with zero failures. #flaky