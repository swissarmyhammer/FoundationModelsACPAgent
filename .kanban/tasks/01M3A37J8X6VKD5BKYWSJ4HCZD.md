---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Give the test support a scripted model that goes through the Router generation queue
---
## Why

The queue tests of this plan (cancel of a request that waits for a queue place; a waiting session holds no model) need a model that really uses the Router per-model queue. The current test model cannot do this:

- `ScriptedSessionBackend` (`Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift:162`) is a `LanguageModelSessionBackend`, and `ScriptedLLMContainer` (`:548`) makes it. It has no executor seam.
- Router card `01M39ZNAJWMVZ291SCH8CSJ2HW` step 4 says that a container with no executor seam gets no pass-level queue, and the Router has not yet decided what such a container gets.
- The `.hold` step (`ScriptedModel.swift:54`) releases only on cancel. A test cannot tell a held pass to end.

## External dependency

The decision of Router card `01M39ZNAJWMVZ291SCH8CSJ2HW` step 4 (read its comments). Write that decision in a comment on this task before you start. If the Router gives stub containers the queue for each scripted pass, use that. Else build the model at the executor level, as the Router test helper `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift` does.

## What

1. `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift` (or a new file `QueuedScriptedModel.swift` in the same target): a scripted model whose passes go through the Router generation queue of one pool entry, so two ACP sessions can share one queue.
2. A releasable hold step: a pass that waits until the test calls `release()`, and that also ends on cancel.
3. A pass counter: the number of passes that started, and the maximum number of passes that ran at the same time.
4. A fixture that makes two ACP sessions over the same pool entry (extend `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift`, or add a new support file).

## Acceptance Criteria

- [ ] With two sessions on the fixture, the maximum number of passes that run at the same time is 1.
- [ ] A held pass ends when the test calls `release()`, and it ends on cancel.
- [ ] While session A holds a pass, a prompt on session B starts no pass (the counter shows it).

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/QueuedScriptedModelTests.swift`: `twoSessionsNeverRunTwoPassesAtOnce`, `releaseEndsAHeldPass`, `cancelEndsAHeldPass`, `aSecondSessionWaitsForTheHeldPass`. Each with a timeout.
- [ ] Run `swift test --filter QueuedScriptedModelTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue #tests