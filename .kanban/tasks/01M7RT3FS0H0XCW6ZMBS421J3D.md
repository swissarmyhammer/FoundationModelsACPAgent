---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
title: HotResumeTests.resumeTrace does not cancel its reader task when the resume request throws
---
## Problem

`HotResumeTests.resumeTrace(of:on:)` starts an unstructured reader `Task` and a `timeout` task. Then it calls `resumeSession`. If that call throws, the helper exits and does not cancel the reader. The `timeout` task stops the reader only after `syncWaitSeconds`. This is the same cause as the finding on ^avdk50h (`swift/concurrency`: cancel the reader on every exit path).

## Work

- Replace the reader task and the `timeout` task with the timed read `readResumeTrace(startingWith:settledBy:timeout:whileRunning:)` of `SessionEventSubscription`. That read uses `TimedRead.value(of:timeout:whileRunning:)` (Tests/FoundationModelsACPAgentTestSupport/TimedRead.swift), which cancels the read on each exit path.
- Do not leave out the root session: in this suite the fixture session is the resumed root. #acpa-6