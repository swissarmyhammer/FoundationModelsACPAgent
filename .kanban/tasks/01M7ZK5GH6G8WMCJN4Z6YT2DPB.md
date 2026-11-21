---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The session open path blocks a cooperative thread on a synchronous NSFileCoordinator read, and test sessions leak agent registries
---
Found on 2026-11-21 during ^j5dys15.

## Facts

- `SessionAgentResolution.workingDirectoryAgent` calls `AgentRegistry.rootAgent(in:id:)` of FoundationModelsAgents from the async `session/new` path. The call does a synchronous coordinated read (`FileCoordination.run`, `NSFileCoordinator.coordinate(readingItemAt:)`) on a thread of the cooperative pool. A slow file coordinator (many file presenters, a sync engine that holds a claim) then holds a pool thread for each open session.
- In the full root `swift test` before ^j5dys15, 581 file presenters stayed at the end of the run: agent registries that a test loaded with `watch: true` and did not stop (for example `SessionAgentTests.makeCatalog` loads a registry and does not call `stopWatching()`). Each such registry also keeps its `DotfolderWatcher` descriptors open.
- ^j5dys15 gives the test agents a conflict source with no file presenter, so these facts do not fail the tests now.

## Work

- [ ] Decide if the coordinated read of the session open path must move off the cooperative pool (in this repository, or as a request to FoundationModelsAgents).
- [ ] Stop each agent registry that a test loads with `watch: true`.

## Tests

- [ ] A test shows the fix of each work item. #flaky