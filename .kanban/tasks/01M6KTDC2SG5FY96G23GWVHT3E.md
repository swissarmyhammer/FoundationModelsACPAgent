---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Flake: OrderlyShutdownTests.aShutdownEndsThePromptOfTheRootAsInterrupted gets endTurn under load'
---
## What
`OrderlyShutdownTests.aShutdownEndsThePromptOfTheRootAsInterrupted` (from ^d6vzdkg) failed once in a full unit run of two different agents (the ^C0991F host fix run and the ^23KNDP hot resume run). In one case the prompt ended with `endTurn` and not `_interrupted`. It passed alone and in the next full run. A load race: the prompt ended on its own before the shutdown pause was applied.

## Do
1. Find the race with the code, not with repeat runs: read how the test starts work, how `shutdown()` marks the open prompts interrupted (`SessionShutdownPause.swift`, `PromptState`, `PromptExecution` `PromptStop.interrupted`), and where a prompt can end `endTurn` between the start of the test and the shutdown. Decide: a test that does not wait for its precondition (the prompt must be provably open before the shutdown starts: wait on a condition, never on a sleep), or a product race (a prompt that ends while the shutdown starts must still end as it ended, and the test must say so).
2. Fix the cause. Do not skip or weaken the test. Do not add a retry.
3. Unit tests only. Do not run integration tests.

## Acceptance Criteria
- [ ] The test waits for its precondition (the prompt is open) before the shutdown starts.
- [ ] If the race is in the product, a unit test pins the fix.
- [ ] Root `swift test`: all pass.

## Workflow
- Use `/tdd`. #subagents