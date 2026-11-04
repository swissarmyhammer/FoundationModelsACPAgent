---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6jqk5phjmykbfmpd1w03pbp
  text: |-
    ### implement — changed
    - evidence: 3 files. Sources/FoundationModelsACPAgent/Agent/SessionResumeReplay.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift and Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift (edits of ^awnkj0k, kept).
    - cause (differs from the card): the live wire is fine. A live run of the chain with a shutdown has the idle state of the child before the cancelled status of the root call (checked on the wire). The fault is in the replay. `announcer.stop()` runs first at shutdown, so the final idle announcement of a child is dropped in some timings. The history of the root then holds the announcement of the child with state `running`. The replay sends no state_update of a child, so the announcement is the only state the validator sees before the final call status. In 2 of 4 runs alone the announcement had `running` (fail); the others had idle(cancelled).
    - fix: `ReplayedSession.announcements` now puts the idle state of the child (last state in the history of the child itself, background removed) into the announcement of a child that the replay covers. No change in SessionLifecycle or ToolCatalog. No sibling package change.
    - TDD: new test `theReplayedAnnouncementCarriesTheIdleStateOfTheChild` (hand-built histories, deterministic). RED with the fix stashed (no idle state in the announcement), GREEN with it. An earlier test through the live wire passed at once, so I removed it.
    - tests: `theWireOfTheResumeFollowsTheRulesOfTheValidator` alone 6 of 6 pass (was failing in most runs). SubagentSessionsReplayTests 13 of 13 pass. 5 runs of SubagentSessionsReplayTests + ResumeNestedSessionsTests: 21 of 21 each time. swift-format lint clean on the two touched files (format applied).
    - full `swift test` (1661 tests): known blocker ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID fails. Not mine. One run also had SubagentSessionsReplayTests.noEventOfAChildComesBeforeItsAnnouncement fail (no update on the stream of the child) under full-suite load only. New task ^ntmvnnz for that flake.
    - boxes: all 3 ticked. Task stays in doing. SessionSetup.swift and ConfigOptions.swift not edited.
    - next: /test and /review.
  timestamp: 2026-11-04T07:32:51.537574+00:00
position_column: doing
position_ordinal: '8580'
title: 'Shutdown cancels the agents call of the root before the child state is idle: replay test of the validator fails alone'
---
## What
The test `SubagentSessionsReplayTests.theWireOfTheResumeFollowsTheRulesOfTheValidator` fails when it runs alone (3 of 3 runs), and it passes only when the whole suite runs in parallel. The validator reports rule `finalToolCallLast`: "final tool call before the final idle state of <child>".

Cause found: the recording ends with `RoutedACPAgent.shutdown()`. The retained history of the root holds the `agents` call with status `cancelled`. The retained history of the child holds the state `running` (the announcement of the child carries it). The validator needs the `idle` state of the child BEFORE the final status of the call that started it. The live wire of the first agent has the same order, so this is a product order problem and not only a test problem. In a run with other timing the child idle comes first and the test passes.

Look at: `tearDownSession` in `SessionLifecycle.swift` (open prompts are cancelled before the runs stop), `stopAgentRuns` in `ToolCatalog.swift`, `AgentCallHolds.swift`, `BackgroundWatch.swift`.

## Acceptance Criteria
- [x] After `shutdown()` of a chain (root, child, grandchild) the child state is idle before the final status of the `agents` call that started it, in the order of the retained history.
- [x] `swift test --filter theWireOfTheResumeFollowsTheRulesOfTheValidator` passes when it runs alone.

## Tests
- [x] Add a test that records the chain, shuts down, and checks the order. Run `swift test --filter SubagentSessionsReplayTests`.

Found while working on ^awnkj0k. #subagents