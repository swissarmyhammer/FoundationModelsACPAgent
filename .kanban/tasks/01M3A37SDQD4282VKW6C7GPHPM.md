---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n21ymx4yhmawf18n4e23by
  text: |-
    Research (implement step):

    - The pinned Router (bbad3ce) has `RoutedSession.close()`. Router card R2 (01M3A1QPQMDJD33G9ANCC2TEZN, the per-session cache key and its release on close) is NOT in bbad3ce. This task needs only `close()`, so the work can go on now. When the pin moves to a Router with R2, the same `close()` call releases the cache key, and this project needs no other change.
    - The only callers of `SelectionAgentSession.fork()` are in FoundationModelsRanker: `SelectionTier.search(intent:limit:)` forks the cached root one time for each search, sends one `respond(to:generating:)`, and then drops the child. `SelectionTier.oneOffSession(instructions:)` forks only a `.session` source; the skills tool uses a `.factory` source, so that path does not fork here.
    - `AgentSession` (FoundationModelsRanker) has no close, and the tier does not tell the child that its work ended. The only signal in this package is that the last reference to the child goes away.
    - `ActiveSession.descendants` is not a good fit: the skills tool session closure (`ToolCatalog.makeSkillsTool`) knows the profile, not the ACP session id, and a close at `session/close` keeps each fork alive for the full session life, which is the problem this task removes.

    Choice: `SelectionAgentSession.fork()` returns a new `SelectionAgentFork` (a `final class`). It owns the Router fork, forwards `respond` and `fork` to a `SelectionAgentSession` over that fork, and in `deinit` starts one task that calls `close()` on the fork. `deinit` runs one time, when the tier drops the child, so this is the earliest correct close. The root `SelectionAgentSession` stays a struct with no close, so the parent is never closed. The Router `ModelPool` uses the same pattern (a `deinit` that starts a task for an async release).

    Discovered: the root guided session that `makeSkillsTool` makes (`profile.flash.makeGuidedSession`) is also never closed. That is outside this card; I will write a new task for it.
  timestamp: 2026-09-28T22:27:04.989065+00:00
- actor: claude-code
  id: 01m3n2jb2aa0r887bgnvhcf7sn
  text: |-
    Implementation landed (TDD).

    - RED: `swift test --filter SelectionAgentSessionTests` failed as expected. Both tests timed out ("timed out while waiting until the dropped fork is closed"), because the old `fork()` returned a plain `SelectionAgentSession` that nothing closes.
    - GREEN: `SelectionAgentSession.fork()` now returns `SelectionAgentFork`. It owns the Router fork and closes it one time in `deinit`, through one task, because `deinit` cannot wait for the async `close()`. The parent is a separate `RoutedSession` and is not closed.
    - Test double: `CloseCountingRoutedSession` (test support). It sends each call to a real scripted Router session, counts `close()`, and keeps each fork it makes. It cannot send the four synchronous requirements (`streamResponse`, `streamEvents`, `streamSessionEvents`, `setGenerationStallReportInterval`) to the actor of the real session, so these stop the test with a `preconditionFailure` that names them. The code under test does not call them.
    - Each test also checks that the fork is still open (close count 0) while the child is held.
    - Full run: `swift test` — 589 tests in 65 suites passed; 1 known issue, which is the `withKnownIssue` that already exists in `HarnessSmokeTests`. `swift build --build-tests`: no warning from the sources of this project.
    - No item of step 3 applies: the close is possible in this package, so no card on another board.
    - New task for the root sessions that the selection factory makes: ^ey85a63.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift (changed), Sources/FoundationModelsACPAgent/Tools/SelectionAgentFork.swift (new), Tests/FoundationModelsACPAgentTests/SelectionAgentSessionTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/CloseCountingRoutedSession.swift (new); swift test 589 passed
    - next: /review
  timestamp: 2026-09-28T22:36:01.994535+00:00
position_column: doing
position_ordinal: '80'
title: Close the forks that SelectionAgentSession makes, so they do not keep a prompt cache entry
---
## Why

Router card `01M3A1QPQMDJD33G9ANCC2TEZN` (R2) gives each Router session and each fork its own prompt-cache key, and only `RoutedSession.close()` releases that key. `SelectionAgentSession.fork()` (`Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift:42-43`) makes a Router fork for each call, and no code closes it: `AgentSession` has no close. After R2, each of these forks keeps a cache entry until the byte LRU of the MLX fork removes it, and it can push out the cache of a real session.

## External dependency

Router card `01M3A1QPQMDJD33G9ANCC2TEZN` (R2) on Router `main`.

## What

1. Find each caller of `SelectionAgentSession.fork()` and learn where the child session ends (`rg -n "fork\(\)" Sources`).
2. Close the Router fork when its work ends. Options: a `close()` on `SelectionAgentSession` that the caller calls in a `defer`; or record each fork in `ActiveSession.descendants` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:96`), so `session/close` closes it. Prefer the earliest correct close. Write the choice in a comment on this task.
3. If a close is not possible (the owner of the `AgentSession` is in another package), write a card on that package board with `sah --cwd <repo> tool kanban task add`, and put its id here.

## Acceptance Criteria

- [x] Each Router fork that `SelectionAgentSession.fork()` makes is closed one time when its work ends.
- [x] The close of a fork does not close its parent session.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/SelectionAgentSessionTests.swift` (new or existing): `aForkIsClosedWhenItsWorkEnds` and `closingAForkKeepsTheParentOpen`, with a Router session double that counts `close()` calls.
- [x] Run `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue