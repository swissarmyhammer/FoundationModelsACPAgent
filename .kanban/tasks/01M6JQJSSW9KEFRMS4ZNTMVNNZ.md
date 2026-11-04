---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6jspaexjgn81rbd167esmd8
  text: |-
    ### implement — changed
    - cause: a PRODUCT race, not a test gap. `RoutedACPAgent.closeSessions(where:)` (used by `shutdown()`, `closeOpenSessions()`, `closeSessionsWithNoOwner()`) visited `sessions` in dictionary order. When a nested session (child) came before its root, the child closed while its agent run was live. The run ended as cancelled and sent a `completed: Agent worker ... was cancelled` result mail to the root. The root journal then held a result for the `start agent` call of the child. On the next start, `AgentRunner.restoreInterrupted` saw a completed call with no ended marker, marked the child as ended (`finished`), and did NOT restore it. Result: no child in the table, so the replay sent no update on the child stream (`restored: [], failed: []` in the report). The root-first order is safe: the root stops the runs first (`stopAgentRuns`), and then retires the children.
    - hypothesis in the card (retireSession / writeHistory order) was wrong: the history files of all three sessions were on disk in each bad case (child 1255 bytes).
    - how found: a temporary stress test (40 parallel record+resume cycles, 36 busy loops) showed the failure in 7 of 320 cycles; the child index.md held `endedAt` / `endReason: finished` written by the second agent restore, and the root transcript held the cancelled result mail. After the fix: 0 of 480 cycles under the same load. The temporary test is deleted.
    - fix: `RoutedACPAgent.parentsFirst(_:parents:)` in SessionLifecycle.swift orders the sessions by depth (ids break ties), and `closeSessions` uses it. The teardown of a parent retires its nested sessions, which are then skipped as closed.
    - test (TDD, red then green): ClosingOrderTests.swift, 3 tests (chain of 12 given child-first, no-parent-first, cycle guard). Red run: 2 of 3 failed with the stub that kept the input order. Green: 3 of 3 pass.
    - extra fix: removed an unneeded `await` before `child.session.send` in SessionCapabilityTests.swift (compiler warning UnnecessaryEffectMarker, present before this task).
    - full `swift test` runs after the fix, each 1664 tests in 183 suites, each run with exactly 2 issues and no other: (1) known issue HarnessSmokeTests.swift:296:31 orderedSubsequenceAssertionChecksOrderWithGaps `remaining.isEmpty`; (2) blocker ShellSessionOwnerTests.swift:62:5 aCommandAfterAModelSlotSwitchRecordsTheACPSessionID. Runs 1, 2, 3 (run 1 also had the compiler warning above), run 4 after the warning fix: no warning. Before the fix, 11 full runs (1 + 10) did not show the flake: it needs load from parallel cycles.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Tests/FoundationModelsACPAgentTests/ClosingOrderTests.swift (new), Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift. The uncommitted edits for ^awnkj0k and ^xyw6858 are untouched.
    - next: /review
  timestamp: 2026-11-04T08:09:31.869430+00:00
position_column: doing
position_ordinal: '8680'
title: 'Flake under full suite: SubagentSessionsReplayTests.noEventOfAChildComesBeforeItsAnnouncement finds no update on the stream of the child'
---
## What
In one full `swift test` run, `SubagentSessionsReplayTests.noEventOfAChildComesBeforeItsAnnouncement` failed at `wire.updates.firstIndex { $0.sessionId == recording.child }` (no update of the child on the replay wire). In a first full run it did not fail. In 5 runs of `--filter "SubagentSessionsReplayTests|ResumeNestedSessionsTests"` it did not fail. So the failure needs the load of the full suite.

Possible cause (not checked): the retained history of the child is empty or not written at the shutdown of the recording, or the restore of the child lost a race. Check `retireSession` and `writeHistory` order in `SessionLifecycle.swift`.

## Acceptance Criteria
- [ ] The cause is found and fixed in this repository.
- [ ] The test passes in 5 full `swift test` runs.

## Tests
- [ ] A test that fails for the cause, before the fix.

Found while working on ^xyw6858. #subagents