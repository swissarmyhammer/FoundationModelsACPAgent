---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6m35axjnm0aatmpj61r3vqh
  text: |-
    Cause (found by reading the code, no repeat runs). A product race. In a resume with a child that does not restore (here: unknown agent), the runner ends the claimed `start agent` call of the child as `lost`. It does this inside `restoreNestedSessions`, through the `claimCompletion` link in AgentRunLinks.swift, which calls `completeClaimedRun` on the Router session of the root. That call only POSTS a `runSettled` event. The projector of the root reads the event in tasks of its own (Router stream, reader task, inbox, consumer) and sends the final `_lost` tool_call_update later. The resume handler did not wait for it. So `syncCurrentState` could send the current `state_update` first. The `_lost` tool_call_update then came after it and before `session_info_update`. The validator reports this as resumeOrder at position 3: "only session_info_update may follow the current state_update". The passing trace (request, tool_call_update, state_update, session_info_update, response) has this same `_lost` tool_call_update at position 1. This is why `replays: false` shows it: with a replay, the work of the replay gives the projector time. I could not see the kind of the extra update in the failed run (no trace was kept); the cause is derived from the code path, and the trace message below names it if it ever shows again.

    Fix. New SettlementWatch.swift: a barrier. The claim completion registers the token, posts, and then waits until the projector has handled the `runSettled` of that token (after the translator sent the status and the ledger took its change). SessionProjector tells the watch after each completed `runSettled`, and closes it when the inbox ends (no hang). AgentRunLinks.claimCompletion uses `completing`. A refused completion (false) waits for nothing.

    Tests. SettlementWatchTests (4, deterministic, no timing): the wait returns only after the projector sent the settlement status (synthetic source); the completion returns only after `settled` (ordering by recorded steps); a refused completion does not wait; close frees a waiter. RED: build failed, SettlementWatch missing. GREEN: 4 of 4 passed. Step 1 done: ResumeChildSyncTests failed-child validator expectation now carries `wire.traceDescription` (position, event, stream for every event) in its failure message.

    Touched suites, one run: ResumeChildSyncTests, ResumeNestedSessionsTests, HotResumeTests, SubagentSessionsReplayTests, RedriveInterruptedRunsTests, SettlementWatchTests, BackgroundListTests, AgentCallHoldsTests: 133 tests in 17 suites passed.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SettlementWatch.swift (new), SessionProjector.swift, AgentRunLinks.swift, Tests/FoundationModelsACPAgentTests/SettlementWatchTests.swift (new), ResumeChildSyncTests.swift
    - next: /review. Note: the flake cannot be proven fixed by a run; the barrier is pinned by the unit tests.
  timestamp: 2026-11-04T20:14:15.474061+00:00
- actor: claude-code
  id: 01m6m3902gra1ex2f69xjmtfyy
  text: |-
    ### review — clean
    - evidence: review sha 8071dc5~1..8071dc5; counts findings 0, confirmed 0, refuted 1, attempted 7, failed 0, skipped 0 (4 skipped files are .kanban files, ignored by .reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-11-04T20:16:15.440901+00:00
position_column: done
position_ordinal: ffffbd80
title: 'Flake: ResumeChildSyncTests failed-child resume wire (replays false) sees an extra update before session_info_update'
---
## What
`ResumeChildSyncTests.theWireOfAResumeWithAFailedChildFollowsTheRulesOfTheValidator(replays: false)` failed once in a full unit run of main (1829 tests, one run), at `ResumeChildSyncTests.swift:703`. The `SubagentWireTraceValidator` reported: `Violation(rule: .resumeOrder, position: 3, message: "only session_info_update may follow the current state_update")`. A passing trace is: request, tool_call_update, state_update, session_info_update, response. In the failing run another update arrived at position 3, after the current `state_update` and before `session_info_update` and the response. It passed in three targeted reruns (single test, the suite twice under CPU load). Cause unknown.

## Do
1. Make the test name the extra update when it fails: put the trace (the update kinds and session ids, in order) in the failure message of the validator expectation. This is a diagnostic aid and stays in the test.
2. Find the source by READING the code: what can send an update after the current `state_update` of the resumed root and before the `session_info_update` of the resume, without a replay (`replays: false`)? Candidates: a root-ledger state change (`PromptState.swift`: a work event, a background list change), the re-drive (`SessionResumeRedrive.swift` runs after the response, but `scheduleChildSync` / `SessionResumeChildSync.swift` / `SessionResumeOpenCalls.swift` may send earlier), the announcer, the failed-child announcement, the hot-resume path (`SessionResumeHot.swift`). The resume handler order is in `SessionResume.swift`.
3. Decide: a test bug (the test does not wait for a precondition) or a product race (an update can be sent between the two sends of the resume): fix the cause. A product race needs a deterministic unit test that pins the order (hand-built state or a gate), not a stress loop. Do not skip or weaken the test; no retry.
4. Unit tests only. Do not run the IntegrationTests package.

## Acceptance Criteria
- [x] The failure message of the test names the update that breaks the order.
- [x] The cause is named on the card and fixed (test or product), with a deterministic test if it was a product race.
- [x] The touched suites pass.

## Workflow
- Use `/tdd`. #subagents