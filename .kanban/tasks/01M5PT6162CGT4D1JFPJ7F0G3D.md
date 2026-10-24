---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5pxjjdtw94mc072t3za77k1
  text: 'Fork part done in 8789f3a (not pushed). closingASessionClosesItsDescendants adopts a child agent session (makeSession(agentSpawn:)). The two fork-listing tests make a recorded fork tree on disk with the new RecordedProjectFixture.makeRecordedFork(of:). CloseCountingRoutedSession has no fork or forks. Whole swift test against local Router 0c54184e: 1269 tests in 141 suites passed (1 known issue). Note: adoptDescendant has no production caller. The queue part stays open.'
  timestamp: 2026-10-24T12:18:39.162271+00:00
- actor: claude-code
  id: 01m5q6t7fyknw3fpafhdhs0kh9
  text: |-
    Queue part done (fork part was done in 8789f3a). Against local Router e8012983 + local Extras (swift package edit, then unedit): `swift build --build-tests` clean, `swift test` 1269 tests in 141 suites passed (1 known issue, the deliberate HarnessSmokeTests one).

    - ACPEventTranslator: removed the `submissionQueued` case and `reportQueueWait()`; `modelName` doc now names the stall log line.
    - PromptExecution / RoutedSelectionModel: docs no longer name the Router queue.
    - Test double: `ScriptedLLMContainer.submitting(to:)`, `ScriptedSessionBackend.generationQueue` and `ScriptedPassCounter.adopt(queue:)` removed. The queued scripted model now emulates the MLX FIFO model lock: `ScriptedPassCounter` owns a FIFO, cancel-at-once lock; each pass takes it (`ScriptedModelTurn`), leaves it for each tool body and takes it again after. `Counts.waiting` counts passes that wait for the model.
    - Tests: `watchForQueuedSubmission`/`waitForFirst` replaced by `waitForPassesThatWaitForTheModel()` (counter wait, no clock). Cancellation/QueuedScriptedModel tests renamed from "ModelQueue" to "Model". `queueWaitNeverEndsTheRequestAsStalled` became `aLongTimeInFlightNeverEndsTheRequestAsStalled` without `makeSubmissionQueued`.
    - `rg 'submissionQueued|submitting\(to|generationQueue|\.fork\('` on Sources Tests finds nothing. `promptDidStart` untouched; its tests pass.
  timestamp: 2026-10-24T15:00:07.294133+00:00
position_column: done
position_ordinal: ffff9580
title: Update the ACP agent's tests and translator for a Router with no generation queue and no fork
---
## What

FoundationModelsRouter drops its per-model generation queue and its unused session fork (Router cards "Call the model through Extras PooledGeneration, with no whole-call queue job" and "Delete the unused RoutedSession.fork"). The design is in memory `no-generation-queue`. This repo's tests and one translator line use what goes away. Update them when the Router sessions tell us their sha. Before that, the change breaks this repo's tests on main.

**After the Router queue card:**
- [ ] `Tests/.../QueuedScriptedFixture.swift:116` waits for `submissionQueued`, and `PromptExecutionTests.swift:992` describes it. That event is no longer sent: wait for `submissionStarted`, or for the first output.
- [ ] The test doubles implement the removed seams `submitting(to:)` and `generationQueue`: `ScriptedModel.swift:269-811` and `QueuedScriptedModel.swift:147-192`. Remove those members.
- [ ] `Sources/FoundationModelsACPAgent/.../ACPEventTranslator.swift:370` logs each `submissionQueued`. Remove that case, or log the start in its place.
- [ ] Check `SessionProjector.swift:392` (`promptDidStart`): it must still fire once for each prompt.

**After the Router fork card:**
- [ ] Remove the fork calls in `SessionLifecycleTests.swift:143`, `TranscriptStoreTests.swift:219` and `SessionListTests.swift:283`, and the `fork` member of the test double `CloseCountingRoutedSession.swift:97-99`.

## Acceptance Criteria

- [ ] `rg -n 'submissionQueued|submitting\(to|generationQueue|\.fork\(' Sources Tests` finds nothing.
- [ ] `promptDidStart` fires once for each prompt (the present test of it passes).

## Tests

- [ ] `swift test` in FoundationModelsACPAgent against the new Router: all tests pass, with no new warnings.

## Workflow

- Use `/tdd` where behavior changes. The rest is a follow-up to an API removal, and the present tests are the proof. #no-queue