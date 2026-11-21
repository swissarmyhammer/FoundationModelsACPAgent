---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A session composition that fails after the agent registry load leaves the registry watching
---
Found on 2026-11-21 during ^6yt2dpb.

## Facts

- `RoutedACPAgent.composeSession` (SessionSetup.swift) loads the agent registry (`AgentsComposition.loadedAgentRegistry`, `watch: true`), then calls `resolveSessionAgent`, `ToolCatalog.makeSkillsSource` and `ToolCatalog.sessionSurface`. When `resolveSessionAgent` throws (an unknown `agent` option) or `sessionSurface` throws, nothing calls `stopWatching()` on the loaded registry. The `do`/`catch` that calls `fullSurface.shutdown()` starts only after the surface exists.
- `AgentsComposition.compose` loads a registry when it gets none, then calls `AgentEnvironment.make`, which can throw `ToolModeError.openModeInSandbox`. On that error nothing stops the registry. `ToolModeTests.theSessionSurfaceGivesTheSandboxProbeToTheAgentEnvironment` goes through this path.
- The registry also stops when it is released (`AgentReloadLoop.deinit`), so the watch stays only while something keeps the registry.

## Work

- [ ] Stop the loaded agent registry on each error path of `composeSession` before the surface owns it.
- [ ] Stop the registry that `AgentsComposition.compose` loaded itself when a later step of `compose` throws.

## Tests

- [ ] A test with `ProbingConflictVersionSource` (Tests/FoundationModelsACPAgentTests/Support) shows that each failed composition ends the change stream of its registry. #flaky