---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7zp115km6tmbrm94088yrt2
  text: |-
    Research:
    - `makeSessionsTool` and `makeMCPServersTool` throw only when `OperationTool` refuses its fixed operation set (FoundationModelsMultitool). A test cannot make them throw. A test can make `AgentsComposition.compose` throw after `makeRegistry`: open mode, and a sandbox probe that turns on at the first agent conflict-version read (the load of the agent registry inside `compose` comes just before `AgentEnvironment.make`).
    - A test cannot reach the skills registry and the `SessionMarketplaces` that `composeSession` makes inside the function. The skills registry also stops when it is released (`ReloadCoordinator.deinit`). `SessionMarketplaces` has no deinit, so its follow and forward tasks stay.
    - Plan: one internal type `StartedSessionParts` holds what a composition started (agent runs, agent registry, skills registry, marketplaces, code-context lease, shell store lease, MCP pool) and stops all of it with `stop()`. `composeSession` and `sessionSurface` each fill it with the parts that they own, and call `stop()` on each error path. `SessionSurface.shutdown()` uses the same `stop()`. Unit tests cover `stop()` field by field. A `sessionSurface` test covers the error path with a shell store lease, which stays leased until something releases it. The existing ^22h3kvw tests cover the catch in `composeSession`, because the agent registry is one field of the same `stop()`.
    - A further error path: in `composeSession`, `loadedAgentRegistry` can throw (on cancellation) after `startSkillsMarketplaces`. The new catch covers it too.
  timestamp: 2026-11-21T18:31:17.939498+00:00
- actor: claude-code
  id: 01m7zpddyhzvwg8kc86tc934e3
  text: |-
    ### implement — changed
    - evidence: 8 files.
      - Sources/FoundationModelsACPAgent/Tools/StartedSessionParts.swift (new): the parts that a composition started (agent runs, agent registry, skills registry, marketplaces, code-context lease, shell store lease, MCP pool), and `stop()`.
      - Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift: `composeSession` stops the marketplaces, the agent registry and the skills registry on each error path before the surface owns them. The `loadedAgentRegistry` path is also covered now.
      - Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift: `sessionSurface` puts its body in the private `composeSurface(...)` and stops what it started on each error after `makeRegistry`: the leases and the pool of the build, the agent runs, its own skills source, and the agent registry that `compose` loaded. Parts that the caller gave stay with the caller. `SessionSurface.shutdown()` uses `StartedSessionParts.stop()`.
      - Tests/FoundationModelsACPAgentTests/FailedSessionSurfaceTests.swift (new), StartedSessionPartsTests.swift (new, 6 tests), Support/SandboxSwitch.swift (moved from FailedSessionCompositionTests.swift, with a `probe`), FailedSessionCompositionTests.swift (uses the shared switch).
    - RED: `aFailedSurfaceReleasesTheShellStoreLeaseOfItsBuild` failed with "Expectation failed: next.store !== held.store". StartedSessionPartsTests did not compile ("cannot find 'StartedSessionParts' in scope").
    - GREEN: the 3 suites gave 10 passes. Full root `swift test --skip-build` after "Build complete!": 2757 tests in 293 suites passed, 0 failures (1 known issue, from an earlier test).
    - Limits: a test cannot make `makeSessionsTool` or `makeMCPServersTool` throw (fixed operation sets). The same catch covers them, and the catch is tested through the `compose` failure. A test cannot reach the skills registry and marketplaces inside `composeSession`. The ^22h3kvw tests prove that its catch calls `started.stop()` (the agent registry is a field of it), and the unit tests prove each field of `stop()`.
    - Follow-up: ^0rma59k (a failed `makeRegistry` leaves the connected MCP servers running).
    - next: /review.
  timestamp: 2026-11-21T18:38:04.241349+00:00
- actor: claude-code
  id: 01m7zpjpj126xft3ccza36kpmm
  text: |-
    ### review — clean
    - evidence: `review sha 4e07ab4~1..4e07ab4` (HEAD~1..HEAD); 7 files reviewed; 0 findings (0 confirmed, 1 refuted). The card has no earlier review findings.
    - next: none. The task is in done.
  timestamp: 2026-11-21T18:40:56.897129+00:00
position_column: done
position_ordinal: ffffffbe80
title: A failed session surface leaves the skills registry, the marketplaces and the built surface parts running
---
Found on 2026-11-21 during ^22h3kvw.

## Facts

- `RoutedACPAgent.composeSession` (SessionSetup.swift) makes a watching skills source (`ToolCatalog.makeSkillsSource`, `watch: true`) and starts the skills marketplaces (`ToolCatalog.startSkillsMarketplaces`) before `ToolCatalog.sessionSurface`. When `resolveSessionAgent` or `sessionSurface` throws, ^22h3kvw stops the agent registry, but nothing stops the skills registry or the marketplaces.
- `ToolCatalog.sessionSurface` builds the registry (`makeRegistry`: MCP pool, shell and code-context leases) and the agents mount (`AgentsComposition.compose`). When a later step throws (`makeSessionsTool`, `makeMCPServersTool`), nothing shuts down the parts that it built.

## Work

- [x] Stop the skills registry and the marketplaces on each error path of `composeSession` before the surface owns them.
- [x] Shut down the built parts of `sessionSurface` when a later step of `sessionSurface` throws.

## Tests

- [x] A test shows that each failed composition stops what it started. The `ReloadHold` pattern of ^22h3kvw (Tests/FoundationModelsACPAgentTests/Support) shows how to keep an object alive, so that only a stop ends its watch.