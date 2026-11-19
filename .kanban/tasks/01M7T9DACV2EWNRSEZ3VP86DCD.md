---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tcw174vf5443e7a4m63v65
  text: |-
    Root cause (checked with debug events of the translator, in process, scripted stub + real Router):

    - `session/cancel` sends `cancelAll()` (task ^n8pcmtd). Router `stopRunningAnswer()` sends `answerFailed(cancelled)` for the mail of the answer, and silences each later event of that answer. The settlement of each run that the answer started has the origin of the answer (`ignoreRunMail` makes no run mail), so Router drops it. The `toolStatus(failed)` of `settleAnnouncedToolCalls()` is dropped too. Thus Router gives NO event for the stopped run, inline or background. The only event is `answerFailed(cancelled)` of the root mail. No Router change is necessary: that event is enough.
    - The agent: each background call (Extras `BackgroundToolRunner.start`) posts its pending envelope as progress at its START, while the call still waits inline. `ACPEventTranslator.projectProgress` then puts the run in `detachedRuns`. `SessionProjector.endPrompt` closes each unfinished call of a cancelled prompt EXCEPT the calls in `openDetachedCallIds`. So the `agents` call of an inline run, and of a background run of the stopped answer, never got a final status.
    - The background case of the client trace (call in the root background list, root answer still running at the cancel) has the same cause. A background run of an answer that ENDED before the cancel is not silenced: its settlement comes (status `completed` for an agents call), as before.

    Fix: `ACPEventTranslator.closeCancelledRun(of:)` closes the call of such a run with status `cancelled` and the text "The run was cancelled.", takes the run out of `detachedRuns`, and drops a later settlement of it (`cancelClosedRuns`). `SessionProjector.closeUnfinishedCalls(of:status:answerStopped:)` uses it only when the Router terminal of the prompt said `cancelled` (not when only `cancelRequested` turned a completed answer into `cancelled`: then the settlements still come).

    Status choice: `cancelled`, not `failed`. Every other call that a cancel stops gets `cancelled` (`PromptExecution.closingStatus`), commit 0fbdc27 maps a cancelled settlement to `cancelled`, and the coordinator allowed "failed or cancelled" for the inline run.

    9ee30fe vs 2531740: no change in the cancel path between them (only the search index, LabelArguments test support, shutdown waits for the search index). The pass of the client copy is a timing difference: the root cancel came after the root answer ended, so the settlement of the background run was not dropped. In the failed run the root answer still ran (both agents calls are in one root pass of the client script), so Router dropped the settlement.

    Also: the build gave one warning in Tests/.../ScriptedCompactionStopTests.swift ("switch must be exhaustive", missing `.attachment`). I removed its private `segmentText` copy and used `AgentsToolTests.segmentText`.
  timestamp: 2026-11-19T17:15:04.804824+00:00
- actor: claude-code
  id: 01m7tcy3de0j4b6g73fd9t5g8k
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift (closeCancelledRun(of:), cancelClosedRuns), Sources/FoundationModelsACPAgent/Agent/SessionProjector.swift (closeUnfinishedCalls(of:status:answerStopped:)), README.md (parent cancel bullet), new Tests/FoundationModelsACPAgentTests/RootCancelAgentsCallTests.swift (5 tests: inline status + reason, background of a running answer status + reason, background of an ended answer stays `completed`), Tests/FoundationModelsACPAgentTests/ScriptedCompactionStopTests.swift (warning removed). RED seen first: inline and background-of-running-answer tests timed out waiting for a final status.
    - deviation to decide: the final status is `cancelled`, not `failed` as the card text says (reason in the earlier comment).
    - next: /review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` Build complete!, 0 compiler warnings; `timeout 1800 swift test --skip-build` 2602 tests in 272 suites passed, 1 known issue (HarnessSmokeTests, expected), exit 0.
  timestamp: 2026-11-19T17:16:12.590372+00:00
- actor: claude-code
  id: 01m7td4rxr4vz7sx808yf4svsv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (7ba6a38). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. 4 files reviewed. Not reviewed: 2 .kanban files (ignore rule), README.md (no validator).
    - next: none. The task is in done. The final status of the agents call is cancelled, as the decision on the card records.
  timestamp: 2026-11-19T17:19:51.224959+00:00
position_column: done
position_ordinal: ffffffa180
title: An agents call of an inline run that a root cancel stops gets a final status on the wire
---
Found during ^ptasrrj (2026-11-19), in the investigation of the FoundationModelsACPClient test `aCancelOfOneChildEndsOnlyThatChild`.

## Current behavior

When a `session/cancel` of a root session reaches a child run of the `agents` tool that is still an INLINE run (not yet moved to the background), Router's `performCancelForeground` cancels the inline run by design (`FoundationModelsRouter` `RoutedSessionActorDrain.swift`). The child goes idle, cancelled. But the `agents` tool call in the root transcript (for example `scripted-call-2`) gets NO final status on the wire: no `tool_call_update` with `status: failed` or `completed`. A client that waits for that tool call to close waits forever.

## Change

1. Find where the agent projects the `agents` tool call of the root, and the event that the cancel of an inline run gives.
2. When a root cancel stops an inline run, send one final `tool_call_update` for its `agents` call (status `failed`, with a short reason such as "The run was cancelled."), the same as for any other tool call that a cancel stops.
3. If the cause is in the Router (no event for the stopped inline run), report it to the Router session (foundationmodelsrouter-f1) with evidence.

## Tests

- A root cancel while a child run of the `agents` tool is inline: the root `agents` call gets one final `tool_call_update` with a failed status.
- A child in the background is not changed by this (the background run behavior stays).
- The same with the scripted stub and the real Router in-process. #bug #agents