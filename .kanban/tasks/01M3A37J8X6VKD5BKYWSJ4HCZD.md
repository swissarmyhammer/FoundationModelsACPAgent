---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n1v0yzse0v0bwpeh222rmq
  text: |-
    Step 4 decision of Router card 01M39ZNAJWMVZ291SCH8CSJ2HW (from its comments): option (a). A container that has no executor seam gets no pass-level gate from the Router. `GenerationQueue` is public. A stub container of the consumer owns its own queue and runs each scripted pass in `queue.runPass { ... }`.

    Blocker: the pinned Router does not have this API. The local `Package.resolved` pins FoundationModelsRouter to bbad3ce (2026-09-23 14:07). `rg GenerationQueue` in `.build/checkouts/FoundationModelsRouter/Sources` finds nothing. The queue came in Router commit 2e97dac (^8csj2hw, 2026-09-25), and `git merge-base --is-ancestor 2e97dac bbad3ce` is false. Later Router commits also changed the queue: 10cae0b (one worker task for each model), 7dc8ee4 (one submission is the queue item), bd786db (removal of the per-pass queue path), 3c0f397 (the queue primitives moved to FoundationModelsExtras), 00cf518 (each model call goes through the work queue of its pool entry). Thus the queue API that this task must use is not stable yet, and the name `runPass` can be gone on the current Router main.

    This task cannot start until the adoption of the newer Router (card ^tz867gz) is done. No file was changed. Do not run `swift package update` to fix this; the current family main branches break the build here (see ^258q0h3).

    ### implement — stuck
    - evidence: GenerationQueue is not in the pinned Router bbad3ce; it came in 2e97dac on 2026-09-25. No file changed.
    - next: finish ^tz867gz (adopt the newer Router), then read the queue API on that Router again before this task starts.
  timestamp: 2026-09-28T22:23:17.983406+00:00
- actor: claude-code
  id: 01m3n1vapq2b2eg3gw0zc61hr7
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. GenerationQueue is not in the pinned Router bbad3ce; it came in Router 2e97dac (2026-09-25).
    - test, commit, review: not run
    - next: this task waits for ^tz867gz (adopt the newer Router). A person must decide the order.
  timestamp: 2026-09-28T22:23:27.959337+00:00
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