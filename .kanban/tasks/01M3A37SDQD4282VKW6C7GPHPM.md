---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
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

- [ ] Each Router fork that `SelectionAgentSession.fork()` makes is closed one time when its work ends.
- [ ] The close of a fork does not close its parent session.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/SelectionAgentSessionTests.swift` (new or existing): `aForkIsClosedWhenItsWorkEnds` and `closingAForkKeepsTheParentOpen`, with a Router session double that counts `close()` calls.
- [ ] Run `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue