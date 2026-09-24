---
assignees:
- claude-code
depends_on:
- 01M3A37J8X6VKD5BKYWSJ4HCZD
position_column: todo
position_ordinal: '8280'
title: Prove that session/cancel and session/close end a request that waits for a place in the model queue
---
## Why

Now a request that waits for the turn-long Router gate can get `.noTurnInFlight` from `cancelCurrentTurn()`. The Router task "Stop holding the generation gate for the whole turn" (FoundationModelsRouter card `01M39ZNSNZGBYEY5G8R93KJN94`) changes this: the request id exists before the queue wait, and the cancel reaches the wait (`waitUnlessCancelled`). This agent must show that the new contract gives the ACP terminator `idle(cancelled)` at once.

Callers in this repository:
- `RoutedACPAgent.sessionCancel(_:)` (`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:643-656`).
- `tearDownSession(_:entry:)` (`Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift:204-219`), which waits for the terminator before the close response.

## External dependency

Router card `01M39ZNSNZGBYEY5G8R93KJN94` on Router `main`. Do not start before it lands.

## What

1. `swift package update FoundationModelsRouter`.
2. Add tests with two sessions on one scripted model (one pool entry). Session A holds a pass open (a scripted model that waits on a continuation). Session B sends a prompt, and its request waits for a queue place.
3. Change code only if a test fails. Update the comments in `sessionCancel(_:)` and in plan.md §8.6 (the table row for "the turn in flight": a request that waits for the GPU is in flight, and `.noTurnInFlight` no longer comes for it).

## Acceptance Criteria

- [ ] `session/cancel` for B, while B waits for a queue place, gives `idle` with `stopReason: cancelled` before A releases its pass.
- [ ] `session/close` for B in the same state answers after B's `idle(cancelled)`, and before A releases its pass.
- [ ] After the cancel, A completes its prompt, and a new prompt on B completes (the queue place is not lost).

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/CancellationTests.swift`: `cancelEndsARequestThatWaitsForTheModelQueue`, `closeEndsARequestThatWaitsForTheModelQueue`. Use a timeout so that a regression fails and does not hang.
- [ ] Run `swift test --filter CancellationTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue