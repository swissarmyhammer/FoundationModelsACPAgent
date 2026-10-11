---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kzvm3g0x9gs38m2ev0k1ab
  text: 'A second full root run on the same tree (no code change) passed: 886 tests in 97 suites, 1 known issue (the harness self-test), exit 0. Thus the hang is intermittent: 1 of 2 full parallel runs on 2026-10-10.'
  timestamp: 2026-10-10T22:45:07.824561+00:00
- actor: claude-code
  id: 01m4mrbzeh696grtfxrty8435b
  text: |-
    Research and cause (2026-10-11).

    Repro: the test alone, 300 repetitions with no load and 200 repetitions with 48 `yes` processes: 0 hangs. A full parallel suite under load, 20 repetitions of each test: 0 hangs of this test. A temporary stress test that runs the close scenario 48 times at the same time in one process (48 `yes` processes also ran) hangs in about 1 of 2 runs of 30 repetitions: about 1 hang in 500 to 1400 closes.

    What the hung run shows: cancel requested = true, state = running, phase = taskTurn, answer open (submissionStarted seen), the hold has 0 waiters and 0 tokens (the pass never reached the hold). A call to the session actor (messageQueueDepth) does not return. The process uses 0% CPU.

    `sample` of the hung process gives the cause. It is an ABBA lock deadlock in the test support code of this repo, not in FoundationModelsAgents and not in the Router:

    - Thread A (the scripted pass, ScriptedModel.swift, `ScriptedSessionBackend.appendPromptEntry` -> `changeTranscript`): holds the `synthesized` Mutex and calls `observer.yield(entries)`. The yield resumes the Router repetition-watch task that waits on `transcriptUpdates()`, thus it must take the status-record lock of that task.
    - Thread B (the Router pump, `runWatchedModelCall` defer, RoutedSessionActorRepetitionWatch.swift): cancels the watch task. `swift_task_cancel` holds the status-record lock of that task and runs the cancellation handler of `AsyncStream.next()`. `AsyncStream._Storage.cancel` calls `onTermination` before it finishes the stream, and the `onTermination` of `transcriptUpdates()` takes the `synthesized` Mutex.

    A waits for B, B waits for A. The pump thread runs on the session actor, thus the actor stops, the run never closes its session, `AgentRunner.stop()` never returns, and `session/close` never answers. The window is the start of a pass (the first transcript change) at the same time as the cancel of the run, thus the hang needs a cancel that comes just when the first submission starts.

    Fix (this repo): `ScriptedSessionBackend` must not yield to an observer while it holds the `synthesized` lock. A test with ordering hooks will prove it.
  timestamp: 2026-10-11T05:53:29.553524+00:00
- actor: claude-code
  id: 01m4mvx17gckzp7bz4hhs2qw8w
  text: |-
    Implementation landed (2026-10-11).

    Correction: `ScriptedSessionBackend.changeTranscript` now takes the changed entries and the open stream continuations under the lock, releases the lock, and then yields. The first yield in `transcriptUpdates()` stays under the lock, because the stream is new: no reader waits on it and no `onTermination` is set yet.

    Seam for the proof: `TranscriptDeliveryHooks` (public, in ScriptedModel.swift), given to `ScriptedSessionBackend.init(... deliveryHooks:)`. `beforeDelivery` runs after a change and before the yields; `beforeObserverRemoval` runs in `onTermination` before the lock. Forks and replaced transcripts keep the hooks. Default hooks do nothing.

    Proof: new test `ScriptedTranscriptDeliveryTests.aReaderCancelDuringATranscriptDeliveryEndsTheReaderAndThePass` (Tests/FoundationModelsACPAgentTests/ScriptedTranscriptDeliveryTests.swift). Ordering only, no sleeps: a reader on its own serial queue waits in the stream; the first delivery of a pass holds in `beforeDelivery`; a plain thread cancels the reader, and `beforeObserverRemoval` signals that the handler runs; then the delivery continues. RED (hook still inside the lock): the same two stacks as the production hang (`sample`), and the test fails at its time limit with "Expectation failed: await Self.resultUnlessCancelled(of: pass)". GREEN: passes in 0.001 s. The waits use `resultUnlessCancelled`, thus a deadlock fails the test and the run continues (a plain `Task.value` wait kept the process alive for 30 minutes in the first RED run).

    Repro rate with the temporary stress test (48 closes at the same time in one process, 48 `yes` processes): before, 7 of 9 runs of 30 repetitions hung (about 1 hang in 500 to 1400 closes). After, 4 runs x 30 repetitions x 48 = 5760 closes, 0 hangs. The stress test, the probes and the `yes` load are removed.

    What did not work: the test alone (300 repetitions, no load and with load) and a full parallel suite with load (20 repetitions of each test) did not reproduce the hang. A probe `Task` that slept 20 s and then called the session actor never printed: the actor was stopped by the deadlock, and the probe was the clue. `sample` of the hung process gave the cause.
  timestamp: 2026-10-11T06:55:14.160206+00:00
- actor: claude-code
  id: 01m4mvx3hc54y9e4rvz6f6m0qe
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift (changed), Tests/FoundationModelsACPAgentTests/ScriptedTranscriptDeliveryTests.swift (new). Root suite: `swift test --scratch-path .build/alt --force-resolved-versions` -> 902 tests in 99 suites passed, 1 known issue (harness self-test), 0 warnings. IntegrationTests: `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` -> 35 tests in 13 suites passed.
    - next: /review
  timestamp: 2026-10-11T06:55:16.524771+00:00
- actor: claude-code
  id: 01m4mwkwyskyznqt097zzxj27r
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD`: 0 findings, 0 confirmed, 0 refuted (7 validator runs, 0 failed; the 2 `.kanban/` files are out of scope because of `.reviewignore`). Acceptance: `swift test --scratch-path .build/alt --force-resolved-versions --parallel` with an empty `SKILLS_MARKETPLACE_CACHE` gave 902 tests in 99 suites passed. `closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses()` passed after 12.225 seconds. The 1 known issue is the `withKnownIssue` in `HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps`, which was there before.
    - extra check: production `onTermination` sites in `Sources/` (`CommandRegistry.swift` SkillCommandSource.commandUpdates, `BuiltinCommands.swift` actionStream, `acp-agent/InboundEndTransport.swift`, `PacedStubModel.swift` streamResponse) only cancel a task or finish a continuation. None takes a lock. No `withLock` body in `Sources/` yields to a stream. The deadlock shape is not in production code. The Router `LiveModelSessionBackend.transcriptUpdates()` (in `LiveModelLoader.swift`) yields outside of a lock, and its `onTermination` (`removePassWatch`) takes the `installation` lock only for a dictionary removal. `withPassWatches` copies the watches under that lock and releases it before it runs them. The Router does not have the same shape.
    - next: none. The task moves to done.
  timestamp: 2026-10-11T07:07:43.449858+00:00
position_column: done
position_ordinal: ffc180
title: AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses can hang in the full parallel run
---
## Problem

In the full root suite run of 2026-10-10 (task ^b2kb6j1), the test `closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses()` in `Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift` hit its time limit: `Time limit was exceeded: 60.000 seconds`, failed after 64.030 seconds. The other 885 tests passed.

The same test, run alone (`swift test --filter AgentsToolTests`), passes after 0.950 seconds.

The change of ^b2kb6j1 does not change the path of this test: the process has no `XDG_CONFIG_HOME`, no `AGENTS_DEFAULTS_DIR` and no `SKILLS_DEFAULTS_DIR`, thus the `agents` and `skills` stacks of the stub agent have the same layers as before.

## Possible cause (not proved)

The test starts a slow agent run, then closes the session. `session/close` stops the agent runs before the root session closes. Under a high load, the run can be cancelled before its first submission starts. If the runner then waits for a run that never closes its session, the root session never closes, and the event stream of the test never ends.

## Cause (proved, 2026-10-11)

A lock-order deadlock in the test support code of this repo (`ScriptedSessionBackend.changeTranscript` in `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`), not in FoundationModelsAgents. The backend yielded to its `transcriptUpdates()` streams while it held its transcript lock. The Router repetition watch cancels its reader of that stream when a model call ends; the cancel holds the status lock of the reader task and runs `onTermination`, which takes the transcript lock. The yield needs the status lock of the same task. The correction gives the changes to the streams after the lock is released. See the comments for the evidence.

## What to do

- Make the hang reproducible (for example, a load on the machine, or many runs of the test in parallel).
- Find the cause, and correct it in the agent or in FoundationModelsAgents.
- Keep the test without a clock limit as the proof.

## Acceptance

- [x] The cause is recorded, and the test passes in each full parallel run. #tests