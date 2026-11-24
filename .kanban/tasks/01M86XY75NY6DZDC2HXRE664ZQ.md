---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'RedriveInterruptedRunsTests: theReplayOpensTheOriginalCallWhenNoHistoryWasWritten fails when it runs alone'
---
## Problem

`theReplayOpensTheOriginalCallWhenNoHistoryWasWritten` fails each time it runs alone (`swift test --filter`), also at e0c9e50 (before the history change of 42402c1). In the full suite, it passes most of the time, and it failed one time on 2026-11-24.

The failure: `wire.firstOpenCall(on: wire.recording.root)` is nil. The replay of the root gives no call update with the status `in_progress` or `paused`.

Data: the journal of the root is session, promptStarted, mail, toolCallStarted, toolOutput, mail x3, instructions, prompt, toolCalls, response, session, mail. The rebuild gives user message, a delivery record, and `tool:scripted-call-1`.

## Work

Find why the result depends on the other tests (a shared state, or an order of the tasks). Make the test deterministic, with no longer waits and no retries. Fix the code if the defect is in the code.
## Result

The cause is in the rebuild, not in the test. The shutdown of the chain stops at a random point:

- Sometimes Router records the output of the agent call of the root before the stop. That output is the pending envelope of the run.
- Live, the `toolCallStarted` marker joins the token of the run to the call, so the translator keeps the call `in_progress`.
- `RecordedHistoryRebuild` used an empty join table. So the envelope did not match the call, and the call became `completed`. The replay then had no open call.

Fix: the rebuild reads the `correlationID` of each `toolCallStarted` marker and records the join, as the live session does.

New test: `aCallWhoseOutputIsThePendingEnvelopeOfItsRunStaysOpen`. It fails without the fix. The redrive test is not changed.

## Correction (2026-11-24)

c4b9164 did not fix the test: the CI run of 62e768a failed on it again, and it still failed each time it ran alone. The shutdown can also record the SDK output "Agent worker (...) was cancelled." for the call, and the rebuild took it as the end of the call. c4b9164 alone also had a defect: a background run that ended normally stayed `in_progress`.

The second fix reads the run events of the journal:
- The end event of a run (`completed`) gives the final status of its call, as the live settlement does (`.runSettled`).
- A background run (an event of the run holds its pending envelope) with no end event in the journal keeps its call `in_progress`.

Tests: `aBackgroundCallWhoseRunDidNotEndStaysOpen` (the envelope output and the cancel output), `aBackgroundCallWhoseRunEndedGetsTheStatusOfTheEnd` (completed and failed). The redrive test passes alone, and the full suite passed (2862 tests, 1 known issue).
