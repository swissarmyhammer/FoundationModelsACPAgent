---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: SinkRecorder.updates(until:) ignores cancellation, so a failed wait hangs the test run
---
## Problem

`SinkRecorder.updates(until:)` in `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift` waits in a way that ignores task cancellation. A `.timeLimit` trait cancels the test, but the wait does not stop. Thus a test whose expected update never comes hangs the whole run, and it does not fail. Found in ^zbcrex8: a failing test (a) hung until the process was killed.

## Change

- Make the wait end when its task is cancelled (for example, resume the waiting continuation from a cancellation handler), and make the test fail with a clear message that names the condition that did not come.

## Acceptance

- [ ] A test that waits for an update that never comes fails at its time limit, and the run continues.
- [ ] A test proves this with a condition that never becomes true and a short time limit (in a `withKnownIssue` block, or by a direct check of the cancelled wait).

#tests