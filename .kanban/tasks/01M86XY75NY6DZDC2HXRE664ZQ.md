---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'RedriveInterruptedRunsTests: theReplayOpensTheOriginalCallWhenNoHistoryWasWritten fails when it runs alone'
---
## Problem

`theReplayOpensTheOriginalCallWhenNoHistoryWasWritten` fails each time it runs alone (`swift test --filter`), also at e0c9e50 (before the history change of 42402c1). In the full suite, it passes most of the time, and it failed one time on 2026-11-24.

The failure: `wire.firstOpenCall(on: wire.recording.root)` is nil. The replay of the root gives no call update with the status `in_progress` or `paused`.

Data: the journal of the root is session, promptStarted, mail, toolCallStarted, toolOutput, mail x3, instructions, prompt, toolCalls, response, session, mail. The rebuild gives user message, a delivery record, and `tool:scripted-call-1`.

## Work

Find why the result depends on the other tests (a shared state, or an order of the tasks). Make the test deterministic, with no longer waits and no retries. Fix the code if the defect is in the code.