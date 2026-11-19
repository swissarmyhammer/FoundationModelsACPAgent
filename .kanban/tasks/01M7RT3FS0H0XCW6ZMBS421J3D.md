---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rtfc78cmg9qsqwtwn5zk2b
  text: |-
    Research and implementation.

    - `resumeTrace(of:on:)` now calls the timed `readResumeTrace(startingWith:leavingOut:settledBy:timeout:whileRunning:)` of `SessionEventSubscription`, with the resume call as the request. That read uses `TimedRead.value(of:timeout:whileRunning:)`, which cancels the reader with `defer` on each exit path. `leavingOut` keeps its default (empty): the fixture session is the resumed root, so the trace keeps its events. `ResumeWire` is not used.
    - The same settle closure ("a `state_update` on the stream of the child") was in three helpers of the file. It is now one `fileprivate func isStateUpdate(of:)` on `WireTraceEvent`, beside `isHistory(of:)`.
    - Other helpers of the file: `resumeAcrossTheWindow`, `resumeOnTheSameConnection` and `resumeOnTheSameConnectionAfterARecord` already use the timed read. `waitForText` starts a `delivered` task and a `limit` task, but it always awaits `delivered.value` before it exits, so no exit path leaves that task running. Not the same cause; no change.
    - Discovered: some tests do not cancel the open `prompt` task of the tree when a step throws. Different cause (the prompt task, not a reader). New card ^ added with tag acpa-6.
    - No new test: `TimedReadTests.aThrowingStepBeforeTheRequestCancelsTheRead` already covers the path (the request throws, and the read gets a cancel at once, not at the timeout).
  timestamp: 2026-11-19T02:34:21.288012+00:00
- actor: claude-code
  id: 01m7rtfjxc5h42qa5gp5bgz0mw
  text: |-
    The new card for the open prompt task is ^6y1ft3n.

    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/HotResumeTests.swift
    - next: review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings; `timeout 1800 swift test --skip-build` ran 2386 tests in 252 suites, all passed (1 known issue: the intended `withKnownIssue` of HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps); 0 warnings.
    - next: review
  timestamp: 2026-11-19T02:34:28.140687+00:00
- actor: claude-code
  id: 01m7rtm3an3gegw5cpzecxv2m4
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (826a115). 0 findings, 0 confirmed, 0 refuted. 7 review tasks attempted, 0 failed, 0 skipped. 1 source file reviewed: HotResumeTests.swift. 4 .kanban files not reviewed (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-11-19T02:36:56.021338+00:00
position_column: done
position_ordinal: ffffff8f80
title: HotResumeTests.resumeTrace does not cancel its reader task when the resume request throws
---
## Problem

`HotResumeTests.resumeTrace(of:on:)` starts an unstructured reader `Task` and a `timeout` task. Then it calls `resumeSession`. If that call throws, the helper exits and does not cancel the reader. The `timeout` task stops the reader only after `syncWaitSeconds`. This is the same cause as the finding on ^avdk50h (`swift/concurrency`: cancel the reader on every exit path).

## Work

- Replace the reader task and the `timeout` task with the timed read `readResumeTrace(startingWith:settledBy:timeout:whileRunning:)` of `SessionEventSubscription`. That read uses `TimedRead.value(of:timeout:whileRunning:)` (Tests/FoundationModelsACPAgentTestSupport/TimedRead.swift), which cancels the read on each exit path.
- Do not leave out the root session: in this suite the fixture session is the resumed root. #acpa-6