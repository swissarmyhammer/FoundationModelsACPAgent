---
comments:
- actor: claude-code
  id: 01m1yhzkf8pkk8250hyygwgber
  text: |-
    Research, and why the order is a proof.

    `SurfaceRefresher.Rebuilding.follow(_:)` in `.build/checkouts/FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/MCP/SurfaceRefresher.swift` reads `server.catalogUpdates` in one `for await` loop and awaits `apply(_:)` for each snapshot. One server has one stream and one child task, so the refresher handles the snapshots of that server in order.

    `MCPServer+Discovery.swift` shows the one emission point: `emitCatalogSnapshot()` yields into that stream. `reconnect()` in `MCPServer+Connection.swift` runs the connect and returns after it, so the snapshot of the unchanged reconnect is in the stream before the case starts the changed reconnect.

    Result: when the stage of the changed reconnect is recorded, a stage of the unchanged reconnect, if there were one, is already recorded too. The count is then the proof, and no clock decides.

    The change in the case:
    - The wait is now a fact the code makes true: `recording.newestPaths.contains(Self.reconnectExtraPath)`.
    - The expectation is `recording.count == 2` — the connect snapshot and the changed reconnect.
    - `Task.sleep(for: noStageSettleDelay)` and `#expect(recording.count == 1)` are gone, and the `noStageSettleDelay` constant with them.
    - A new constant `reconnectExtraPath` renders the path one time, the way `boundaryExtraPath` does for the neighbour case.

    The file holds no other `Task.sleep` that decides an expectation. The one remaining sleep is `pollInterval` inside `pollUntil`, which only spaces two reads.
  timestamp: 2026-09-07T18:27:11.464023+00:00
- actor: claude-code
  id: 01m1yhzvagktkbcm3zktha3k2q
  text: |-
    Falsification — the case still fails when an unchanged reconnect stages.

    Temporary change in the transport factory of the case, so that each connect published a tool of its own and the reconnect the case calls unchanged moved the catalog:

    ```
    await scripted.addEchoTool(named: "serve\(served.withLock { $0.count })")
    ```

    `swift test --filter 'aReconnectStagesARebuildAndAnUnchangedCatalogStagesNothing'` then reported:

    ```
    Test aReconnectStagesARebuildAndAnUnchangedCatalogStagesNothing() recorded an issue at
    MCPCompositionTests.swift:567:9: Expectation failed: recording.count == 2
      recording.count == 2 -> false
        recording.count -> 3
    Test run with 1 test in 1 suite failed after 0.122 seconds with 1 issue.
    ```

    The count of three is the stage of the extra reconnect. The temporary line is removed again, and `git diff` shows only the intended change.
  timestamp: 2026-09-07T18:27:19.504619+00:00
- actor: claude-code
  id: 01m1yja2jsx4h19t3h3c2rtd66
  text: |-
    ### implement — changed

    - evidence: 1 file — `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift` (16 insertions, 9 deletions). No file of a family package is touched; the checkouts were read only.
    - falsification: with the temporary line that made each connect publish a tool of its own, the case failed — `MCPCompositionTests.swift:567:9: Expectation failed: recording.count == 2`, with `recording.count -> 3`. The line was removed again.
    - tests: three `swift test` runs in sequence, each `Test run with 428 tests in 45 suites passed ... with 1 known issue` — the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239` — and no other issue. `swift test --filter 'MCPCompositionTests'` passed with 15 tests in 1 suite. The nested `IntegrationTests` package was not run, as the card says.
    - rule checks: `swiftlint` with `no_magic_numbers`, `missing_docs`, `function_body_length`, `closure_body_length` and the legacy and optional-binding rules gives 0 violations on the file. `swiftformat --lint` with the test and idiom rules says the file needs no format change.
    - next: `/review`.
  timestamp: 2026-09-07T18:32:54.617093+00:00
- actor: claude-code
  id: 01m1yjmxyrfbq1k5fhf2fjar4b
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (59262cf), 7 validators attempted, 0 findings, 0 confirmed, 0 refuted. 1 file reviewed, 4 `.kanban/` files excluded by `.reviewignore`.
    - checked the three questions of the card:
      1. The order argument holds. `MCPServer+Connection.swift` calls `emitCatalogSnapshot()` in `applyConnect(via:generation:)` after `transition(to: .ready)`, and `applyConnectResuming` resumes the caller only after `applyConnect` returns. So `reconnect()` returns after its snapshot is in the stream. `catalogUpdates` is made by `AsyncStream.makeStream()`, which buffers without a limit, so no snapshot is dropped. `SurfaceRefresher.follow(_:)` reads one server with one `for await` loop and awaits `apply(snapshot)` for each snapshot in turn. The two reconnects cannot change places.
      2. The case proves the two halves. The poll ends on `recording.newestPaths.contains(reconnectExtraPath)`, which only the changed reconnect makes true — that is the first half. `RecordingStaging.stage` writes `count` and `newestPaths` under one lock, so when the new path is visible the count holds every earlier stage. `#expect(recording.count == 2)` at `MCPCompositionTests.swift:566` therefore proves the second half: a stage from the unchanged reconnect would make the count 3.
      3. No wall-clock delay decides an expectation in the file. The only `Task.sleep` left is the poll step at `MCPCompositionTests.swift:170` inside `pollUntil`, which paces the poll and records an issue at the deadline. `noStageSettleDelay` is gone from the whole `Tests` tree.
    - next: none. The card moves to done.
  timestamp: 2026-09-07T18:38:50.328075+00:00
- actor: claude-code
  id: 01m1yjnt66w4ykht792x0q31wt
  text: |
    ### finish iteration 1 — clean

    - implement: changed — 1 file, `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift`, 16 insertions and 9 deletions. The 300 ms `Task.sleep`, the `#expect(recording.count == 1)` that followed it, and the `noStageSettleDelay` constant are gone. The case waits for `recording.newestPaths.contains(Self.reconnectExtraPath)`, a fact the code makes true, and then expects `recording.count == 2`. The new constant `reconnectExtraPath` renders the path one time, the same shape as `boundaryExtraPath` in the neighbour case.
    - test: three `swift test` runs in sequence, each 428 tests in 45 suites passed with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`, and no other issue. `swift test --filter 'MCPCompositionTests'` passed, 15 tests in 1 suite.
    - falsification: a temporary line that made each connect publish a tool of its own failed the case with `MCPCompositionTests.swift:567:9: Expectation failed: recording.count == 2`, `recording.count -> 3`. The line was then removed.
    - commit: `59262cf` `test(mcp): decide the no-stage case by order, not by a delay`
    - review: clean — `review sha HEAD~1..HEAD`, 7 validators attempted, 0 findings.

    The review confirmed the ordering argument against the code: `MCPServer+Connection.swift:434` emits the catalog snapshot inside `applyConnect`, so `reconnect()` returns after its snapshot is in the stream and the two reconnects cannot interleave; `MCPServer.swift:331` builds the stream with an unlimited buffer, so no snapshot is dropped; `SurfaceRefresher.swift:293` applies the snapshots of one server in emission order. It also confirmed that no wall-clock delay is left in the file that decides an expectation.
  timestamp: 2026-09-07T18:39:19.238800+00:00
position_column: done
position_ordinal: b680
title: Prove the no-stage negative by order, not by a 300 ms settle delay
---
### What

`aReconnectStagesARebuildAndAnUnchangedCatalogStagesNothing()` lets a clock decide a negative. Change it to decide by the code's own order.

1. `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift:552` waits `noStageSettleDelay`, which is 300 ms at `MCPCompositionTests.swift:81`, and then expects `recording.count == 1`.

2. The expectation is a negative: it says that an unchanged catalog staged nothing. A wait of 300 ms does not prove that. On a slow machine the stage can come after the wait, and the case then gives a pass that the code did not earn.

3. The case already holds a barrier at `MCPCompositionTests.swift:556` to `:558`: a changed reconnect that stages for sure. Wait for that stage, then expect `recording.count == 2`. The refresher's own order then proves that the unchanged reconnect staged nothing, because a stage from the unchanged reconnect would make the count 3.

4. Remove `noStageSettleDelay` and its `Task.sleep` when no case needs them.

5. Card `^04kf7ha` corrected the same class of defect in `aToolListChangeIsStagedAndAppliesOnlyAtTheNextTurnBoundary()`. The review of that card found this one, and left it because a diff-scoped review reports only the lines its commit wrote. Use the same shape: make the change in the case, wait for a fact the code makes true, and let no clock decide.

### Test shape

- The case decides by the order of the events, not by a delay.
- No `Task.sleep` stays in the file unless a card states why it is necessary.
- The case still fails when an unchanged reconnect stages a rebuild. Show that: make the unchanged reconnect stage on purpose, show the case fails, then put the code back.
- `swift test` gives 428 tests in 45 suites with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`, three runs in sequence.

### Acceptance Criteria

- [x] `MCPCompositionTests.swift` holds no `Task.sleep` that decides if an expectation passes.
- [x] The case proves the negative through the refresher's own order.
- [x] The falsification is recorded on this card, with the failure message.
- [x] Three `swift test` runs in sequence each give 1 known issue and no other issue.
- [x] No file of a family package is changed.

### Why

A test that a clock decides gives a pass the code did not earn, and it gives that pass more often on a busy machine. Card `^04kf7ha` showed the cost: the same shape in the neighbour case failed each full run and stopped every card from reporting a green root suite.