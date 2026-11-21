---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7zn9paqg60581g5ye8ex71c
  text: |-
    Research and RED notes:
    - A plain ProbingConflictVersionSource test does not fail before the fix. When the composition throws, nothing keeps the registry, and `AgentReloadLoop.deinit` halts the watch at the same moment as an explicit stop. The first test run (no fix) passed all 3 tests.
    - To make the test sensitive, I added `ReloadHold` (Tests/FoundationModelsACPAgentTests/Support/ReloadHold.swift) and an optional `reloadHold:` on `ProbingConflictVersionSource`. At the first conflict-version read of the first build, the hold yields a change on the newest change stream. The registry then starts a reload, and the hold keeps that reload inside its read. The running reload keeps the registry, so only a stop ends the stream. Do not yield from inside `changes(under:)`: the first build calls it inside the lock of `currentWatch`, and the reload then blocks on that lock (deadlock).
    - RED (no fix): `swift test --skip-build --filter FailedSessionCompositionTests` gave 3 failures, each "Time limit was exceeded: 60.000 seconds".
    - GREEN (with fix): the same filter gave 3 passes in 0.08 s.
    - Discovery (not in the scope of this card): when `ToolCatalog.sessionSurface` throws inside `composeSession`, the skills source from `makeSkillsSource` (a watching `SkillsRegistry`) and the started marketplaces also get no stop. Also `sessionSurface` itself does not stop the parts it built (MCP pool, leases, the agents mount) when a step after `AgentsComposition.compose` throws.
  timestamp: 2026-11-21T18:18:33.175996+00:00
- actor: claude-code
  id: 01m7znc4a2vjdv5htmfnmjv5md
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift (do/catch stops the agent registry when `resolveSessionAgent` or `sessionSurface` throws), Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift (`compose` stops a registry that it loaded itself; the body moved to the private `mount(registry:...)`), Tests/FoundationModelsACPAgentTests/FailedSessionCompositionTests.swift (new, 3 tests), Tests/FoundationModelsACPAgentTests/Support/ReloadHold.swift (new), Tests/FoundationModelsACPAgentTests/Support/ProbingConflictVersionSource.swift (optional `reloadHold:`). RED: 3 time-limit failures with no fix. GREEN: 3 passes. Full root `swift test --skip-build` after "Build complete!": 2750 tests in 291 suites passed, 0 failures (1 known issue, from an earlier test).
    - next: /review. Follow-up task ^2zm9hbk holds the skills registry, marketplace and surface-part leaks found here.
  timestamp: 2026-11-21T18:19:53.026237+00:00
- actor: claude-code
  id: 01m7zngbwgwxk1t4yzvrg0bcr2
  text: |-
    ### review — findings
    - evidence: `review sha c52cbbc~1..c52cbbc` (HEAD~1..HEAD); 5 files reviewed; 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsACPAgentTests/FailedSessionCompositionTests.swift:111.
    - next: Correct the item in the "Review Findings (2026-11-21 12:20)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-21T18:22:11.856853+00:00
- actor: claude-code
  id: 01m7znnhj92761qkwhptna6t59
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTests/FailedSessionCompositionTests.swift (`liveStreamsAfterFailure` now has `defer { hold.release(); failed.cancel() }` right after it makes the task, so each exit path releases the hold and cancels the composition task; this was the only unstructured task in the file), Tests/FoundationModelsACPAgentTests/Support/ReloadHold.swift (`release()` now opens the hold for good and does nothing on a second call; it also signals `reloadEntered`, so a first build that still waits for the reload continues when a test ends early). `swift test --skip-build --filter FailedSessionCompositionTests` after "Build complete!": 3 passed. Full root `swift test --skip-build`: 2750 tests in 291 suites passed, 0 failures (1 known issue, from an earlier test).
    - next: /review again.
  timestamp: 2026-11-21T18:25:01.513818+00:00
- actor: claude-code
  id: 01m7znqekbew6dfe6rcq5vyw5d
  text: |-
    ### review — clean
    - evidence: `review sha c5d15e7~1..c5d15e7` (HEAD~1..HEAD); 2 files reviewed; 0 findings (0 confirmed, 0 refuted). The item of the 12:20 section is checked.
    - next: none. The task is in done.
  timestamp: 2026-11-21T18:26:04.011583+00:00
position_column: done
position_ordinal: ffffffbd80
title: A session composition that fails after the agent registry load leaves the registry watching
---
Found on 2026-11-21 during ^6yt2dpb.

## Facts

- `RoutedACPAgent.composeSession` (SessionSetup.swift) loads the agent registry (`AgentsComposition.loadedAgentRegistry`, `watch: true`), then calls `resolveSessionAgent`, `ToolCatalog.makeSkillsSource` and `ToolCatalog.sessionSurface`. When `resolveSessionAgent` throws (an unknown `agent` option) or `sessionSurface` throws, nothing calls `stopWatching()` on the loaded registry. The `do`/`catch` that calls `fullSurface.shutdown()` starts only after the surface exists.
- `AgentsComposition.compose` loads a registry when it gets none, then calls `AgentEnvironment.make`, which can throw `ToolModeError.openModeInSandbox`. On that error nothing stops the registry. `ToolModeTests.theSessionSurfaceGivesTheSandboxProbeToTheAgentEnvironment` goes through this path.
- The registry also stops when it is released (`AgentReloadLoop.deinit`), so the watch stays only while something keeps the registry.

## Work

- [x] Stop the loaded agent registry on each error path of `composeSession` before the surface owns it.
- [x] Stop the registry that `AgentsComposition.compose` loaded itself when a later step of `compose` throws.

## Tests

- [x] A test with `ProbingConflictVersionSource` (Tests/FoundationModelsACPAgentTests/Support) shows that each failed composition ends the change stream of its registry. #flaky

## Review Findings (2026-11-21 12:20)

> Scope: `review sha c52cbbc~1..c52cbbc` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/FailedSessionCompositionTests.swift:111` `swift/concurrency` — The unstructured `Task { try await composition() }` is awaited only on the success path. If `hold.isHoldingReload.wait(...)` at line 112 or `source.liveChangeStreams.wait(...)` at line 113 throws (for example on cancellation or the time limit), `failed` is never awaited and `hold.release()` never runs. The task then stays blocked in `gate.wait()` for the rest of the test process. The task handle is not stored and cancelled in teardown. Release the hold and await or cancel the task on every exit path. For example, wrap the waits in `do { ... } catch { hold.release(); failed.cancel(); throw error }`, or add `defer { hold.release() }` before the waits and `defer { failed.cancel() }` after creating the task.