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
- actor: claude-code
  id: 01m3pz9f06cnpg0pjmxqma0yrv
  text: |-
    Picked up again on Router main c49e453 (the new Router is now adopted). Research result and decision:

    - The Router design (`generation-queue.md` section 5.3) and the Router source now give a public seam for a stub container. `LoadedLLMContainer.submitting(to:)` is a public protocol requirement. The Router calls it one time for each hold (`ModelHold.generationContainer()`), with the one `GenerationQueue` of the pool entry. `LanguageModelSessionBackend.generationQueue` is a public protocol requirement with a default of `nil`. When a backend names a queue, the session submits each whole SDK call of the backend to that queue as one item (`RoutedSessionActor.ownSubmissionTarget`, `runCancellableModelCall`).
    - A container that keeps the default `submitting(to:)` gets no queue (the case of `ScriptedLLMContainer` now). This is the "decision of ^8csj2hw step 4": the consumer stub opts in.
    - The queue item is one submission (one whole SDK call), not one executor pass. For the scripted backend, one generating call is one play of the script. Thus in this test support one "pass" is one generating call of a scripted backend, and the Router runs it as one item of the pool-entry queue.
    - Decision: do NOT build an executor-level model (the Router test helper `ScriptedToolCallingModel` drives `MLXFoundationModelsSessionBackend`, which is not public to this package). Use the public seam: `ScriptedSessionBackend` names an optional `generationQueue`, and a scripted container that opts in overrides `submitting(to:)` to keep the pool-entry queue. The existing `ScriptedLLMContainer` default stays unqueued, so the 605 existing tests keep their behavior.
    - `GenerationQueue.waitingCount` (public, in FoundationModelsExtras) tells a test that a second submission waits, with no fixed wait.
  timestamp: 2026-09-29T16:17:14.246035+00:00
- actor: claude-code
  id: 01m3pzz6afg7y2dshn0tnnnwxh
  text: |-
    Implementation landed (not committed).

    What was made:
    - `Tests/FoundationModelsACPAgentTestSupport/QueuedScriptedModel.swift` (new): `ScriptedHold` (a hold that ends on `release()` or on cancel; a continuation, no timer), `ScriptedPassCounter` (`startedCount`, `runningCount`, `maximumRunningCount`, and `waitingCount`, which reads `GenerationQueue.waitingCount` of the pool-entry queue), and `StubModelLoader.makeQueuedScriptedLoader(script:passCounter:)`.
    - `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`: new step `ScriptedTurnStep.holdUntilReleased(ScriptedHold)`; `ScriptedSessionBackend` names an optional `generationQueue` and counts each play on an optional pass counter (forks and replaced transcripts keep both, through one `makeSibling` helper); `ScriptedLLMContainer` takes an optional `passCounter` and, only when it has one, overrides `submitting(to:)` to keep the queue of the pool entry. With no counter, the container keeps the old behavior (no queue), so the existing tests do not change.
    - `Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift` (new): one agent, two ACP sessions in one working directory over the queued model.
    - `Tests/FoundationModelsACPAgentTests/QueuedScriptedModelTests.swift` (new): the four tests of the card, each with `.timeLimit(.minutes(1))`. No fixed wait: each wait is `Poll.until` of a fact under a deadline.

    Discovery: the stub profile resolves the `standard` and the `flash` slot as two different pool entries, thus two different queues. The Router calls `submitting(to:)` for the standard hold and then for the flash hold. On the first try the counter kept the last queue (flash), and `waitingCount` read the wrong queue: the two queue tests timed out. The fix: the queued loader gives the pass counter (and thus the queue) only to the container of the `standard` slot, which the ACP sessions prompt. The flash container runs each call directly.

    TDD record: RED 1 = compile failure (no API). RED 2 = with the hold and the counter but no `submitting(to:)` override, `twoSessionsNeverRunTwoPassesAtOnce` failed with `maximumRunningCount == 2`, and `aSecondSessionWaitsForTheHeldPass` timed out. GREEN after the override.

    ### implement — changed
    - evidence: `swift test --filter QueuedScriptedModelTests` 4/4 passed (twoSessionsNeverRunTwoPassesAtOnce, releaseEndsAHeldPass, cancelEndsAHeldPass, aSecondSessionWaitsForTheHeldPass); `swift test` 609 tests in 70 suites passed (605 before + 4), 1 known issue (the old intentional one in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps); `swift build --package-path IntegrationTests --build-tests` complete. Files: Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift, Tests/FoundationModelsACPAgentTestSupport/QueuedScriptedModel.swift, Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift, Tests/FoundationModelsACPAgentTests/QueuedScriptedModelTests.swift.
    - next: /review. The task stays in doing.
  timestamp: 2026-09-29T16:29:06.255751+00:00
- actor: claude-code
  id: 01m3q04zp1dm9pr5gzw4c2hj8b
  text: |-
    ### commit — changed
    - evidence: 87f3ead test: give the test support a scripted model that goes through the Router generation queue
    - next: run /test then /review
  timestamp: 2026-09-29T16:32:16.065386+00:00
- actor: claude-code
  id: 01m3q0dy2bqpf3236q3t9szzy2
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (87f3ead). Zero findings: 0 confirmed, 1 refuted, 7 attempted, 0 failed. The .reviewignore rule excluded 4 .kanban files.
    - next: The task is in done. No work remains.
  timestamp: 2026-09-29T16:37:09.323593+00:00
- actor: claude-code
  id: 01m3q0e5ttfbkh55atezehd117
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files (QueuedScriptedModel.swift, ScriptedModel.swift, QueuedScriptedFixture.swift, QueuedScriptedModelTests.swift)
    - test: green — swift test 609 tests pass, two runs; IntegrationTests build ok
    - commit: 87f3ead
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-29T16:37:17.274198+00:00
position_column: done
position_ordinal: f080
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

- [x] With two sessions on the fixture, the maximum number of passes that run at the same time is 1.
- [x] A held pass ends when the test calls `release()`, and it ends on cancel.
- [x] While session A holds a pass, a prompt on session B starts no pass (the counter shows it).

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/QueuedScriptedModelTests.swift`: `twoSessionsNeverRunTwoPassesAtOnce`, `releaseEndsAHeldPass`, `cancelEndsAHeldPass`, `aSecondSessionWaitsForTheHeldPass`. Each with a timeout.
- [x] Run `swift test --filter QueuedScriptedModelTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue #tests